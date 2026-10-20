import Foundation

/// uBlock Origin Lite's built scriptlet files, which hold its YouTube rules. They need no extension API:
/// each world runs scriptlet-begin + rulesets + scriptlet-end at document start, the way uBO Lite
/// registers them. A copy is a folder with uBO Lite's own layout (manifest.json at the top).
/// Two sources, the newest version wins: the copy bundled with the app, and copies downloaded by
/// UBOLiteUpdater into `storeDirectory` (one folder per version).
public enum UBOLite {
    /// The rulesets that hold uBO's YouTube rules.
    static let rulesets = ["ublock-filters", "ublock-experimental"]
    static let worlds = ["main", "isolated"]

    public struct Copy: Sendable {
        public let folder: URL
        public let version: String
    }

    /// The scripts of one world, in the order they must run.
    static func scriptPaths(world: String) -> [String] {
        (["scriptlet-begin"] + rulesets + ["scriptlet-end"]).map { "rulesets/scripting/scriptlet/\(world)/\($0).js" }
    }

    /// Every file a complete copy has, relative to its folder.
    static var files: [String] { ["manifest.json", "LICENSE.txt"] + worlds.flatMap(scriptPaths(world:)) }

    /// Downloaded copies, one folder per version (Application Support works the same on Mac and iOS).
    public static var storeDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lumen/uBOLite", isDirectory: true)
    }

    /// The copy shipped inside the app; for `swift run` from macos/, the one the Windows build bundles.
    static var bundledFolder: URL? {
        if let bundled = Bundle.main.url(forResource: "uBOLite", withExtension: nil) { return bundled }
        let dev = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("../windows/Extensions/uBOLite").standardized
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }

    /// The newest complete copy, bundled or downloaded.
    public static func newest(store: URL = storeDirectory) -> Copy? {
        var copies = downloaded(in: store)
        if let folder = bundledFolder, let copy = copy(at: folder) { copies.append(copy) }
        return copies.max { isOlder($0.version, than: $1.version) }
    }

    static func downloaded(in store: URL) -> [Copy] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? []
        return folders.filter { !$0.lastPathComponent.hasSuffix(".download") }.compactMap(copy(at:))
    }

    /// A folder counts only when every file is there and its manifest has a version.
    public static func copy(at folder: URL) -> Copy? {
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }),
              let data = try? Data(contentsOf: folder.appendingPathComponent("manifest.json")),
              let version = version(fromManifest: data) else { return nil }
        return Copy(folder: folder, version: version)
    }

    /// The manifest's version, accepted only as digits and dots ("2026.1018.2229"): it becomes a folder name.
    static func version(fromManifest data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              !version.isEmpty, version.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) else { return nil }
        return version
    }

    /// Versions compared number by number.
    public static func isOlder(_ a: String, than b: String) -> Bool {
        let numbers = { (v: String) in v.split(separator: ".").map { Int($0) ?? 0 } }
        return numbers(a).lexicographicallyPrecedes(numbers(b))
    }
}

/// Fetches uBO Lite's newest scriptlet files straight from the uBOL-home repository, which keeps the built
/// Chromium package in `chromium/`: file by file from one commit, so no zip is needed (iOS has no unzip).
public enum UBOLiteUpdater {
    public enum Outcome: Equatable, Sendable {
        /// No newer version than the newest one already on this device.
        case upToDate(String)
        /// A newer version was saved; it is used from the next app start.
        case downloaded(String)
        case failed(String)
    }

    static let latestCommitURL = URL(string: "https://api.github.com/repos/uBlockOrigin/uBOL-home/commits?path=chromium/manifest.json&per_page=1")!
    static func fileURL(commit: String, path: String) -> URL {
        URL(string: "https://raw.githubusercontent.com/uBlockOrigin/uBOL-home/\(commit)/chromium/\(path)")!
    }

    static let lastCheckKey = "uBOLiteLastCheck"
    static let latestVersionKey = "uBOLiteLatestVersion"

    /// What the app's update button shows.
    public enum Status: Equatable, Sendable {
        case current
        /// GitHub has a newer version than any on the device (the button shows a green dot).
        case available(String)
        /// A newer version is downloaded and waits for the next app start.
        case downloaded(String)
    }

    /// From the copies on the device and the last check's result, so it needs no network.
    public static func status(running: String? = AdBlock.uBOCopy?.version, defaults: UserDefaults = .standard) -> Status {
        let onDisk = UBOLite.newest()?.version
        if let latest = defaults.string(forKey: latestVersionKey), let have = onDisk ?? running,
           UBOLite.isOlder(have, than: latest) { return .available(latest) }
        if let onDisk, let running, UBOLite.isOlder(running, than: onDisk) { return .downloaded(onDisk) }
        return .current
    }

    /// Asks GitHub for the newest version at most once per `interval` and remembers it; downloads nothing.
    /// True when it checked. A failed check is not remembered, so it is retried the next time.
    @discardableResult
    public static func checkIfDue(interval: TimeInterval = 24 * 60 * 60, defaults: UserDefaults = .standard,
                                  session: URLSession = .shared) async -> Bool {
        if let last = defaults.object(forKey: lastCheckKey) as? Date, Date().timeIntervalSince(last) < interval { return false }
        guard let (version, _, _) = try? await latest(session) else { return false }
        remember(version, defaults)
        return true
    }

    /// Downloads the newest version into `store` when it is newer than `have` (by default the newest copy
    /// already on the device), then removes older downloads. The copy in use stays loaded until the app restarts.
    public static func update(store: URL = UBOLite.storeDirectory, have: String? = UBOLite.newest()?.version,
                              defaults: UserDefaults = .standard, session: URLSession = .shared) async -> Outcome {
        do {
            let (latest, commit, manifest) = try await latest(session)
            remember(latest, defaults)
            if let have, !UBOLite.isOlder(have, than: latest) { return .upToDate(have) }

            // Fill a temporary folder first, so a failed download never leaves a half copy behind.
            let fm = FileManager.default
            let target = store.appendingPathComponent(latest, isDirectory: true)
            let temp = store.appendingPathComponent(latest + ".download", isDirectory: true)
            try? fm.removeItem(at: temp)
            for path in UBOLite.files {
                let data = path == "manifest.json" ? manifest : try await fetch(fileURL(commit: commit, path: path), session)
                guard !data.isEmpty else { throw UpdateError("ไฟล์ว่าง: \(path)") }
                let file = temp.appendingPathComponent(path)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file)
            }
            guard UBOLite.copy(at: temp)?.version == latest else { throw UpdateError("ไฟล์ที่ดาวน์โหลดไม่ครบ") }
            try? fm.removeItem(at: target)
            try fm.moveItem(at: temp, to: target)
            for old in (try? fm.contentsOfDirectory(at: store, includingPropertiesForKeys: nil)) ?? [] where old.lastPathComponent != latest {
                try? fm.removeItem(at: old)
            }
            return .downloaded(latest)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// The newest version on GitHub, the commit it was built in, and its manifest.
    static func latest(_ session: URLSession) async throws -> (version: String, commit: String, manifest: Data) {
        let commits = try JSONSerialization.jsonObject(with: try await fetch(latestCommitURL, session)) as? [[String: Any]]
        guard let commit = commits?.first?["sha"] as? String, commit.count == 40, commit.allSatisfy(\.isHexDigit) else {
            throw UpdateError("อ่านรุ่นล่าสุดจาก GitHub ไม่ได้")
        }
        let manifest = try await fetch(fileURL(commit: commit, path: "manifest.json"), session)
        guard let version = UBOLite.version(fromManifest: manifest) else { throw UpdateError("อ่านเลขรุ่นจาก manifest ไม่ได้") }
        return (version, commit, manifest)
    }

    static func remember(_ latest: String, _ defaults: UserDefaults) {
        defaults.set(Date(), forKey: lastCheckKey)
        defaults.set(latest, forKey: latestVersionKey)
    }

    static func fetch(_ url: URL, _ session: URLSession) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("Lumen", forHTTPHeaderField: "User-Agent") // GitHub's API refuses requests without one
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("GitHub ตอบ \((response as? HTTPURLResponse)?.statusCode ?? 0) สำหรับ \(url.lastPathComponent)")
        }
        return data
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
