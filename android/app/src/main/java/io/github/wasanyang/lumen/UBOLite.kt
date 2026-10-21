package io.github.wasanyang.lumen

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

/**
 * uBlock Origin Lite's built scriptlet files, which hold its YouTube rules (port of shared/LumenCore/UBOLite.swift).
 * They need no extension API: each world runs scriptlet-begin + rulesets + scriptlet-end at document start.
 * Two sources, the newest version wins: the copy in the APK's assets (from windows/Extensions/uBOLite at
 * build time) and copies UBOLiteUpdater downloaded into storeDir (one folder per version).
 */
object UBOLite {
    /** The rulesets that hold uBO's YouTube rules. */
    val rulesets = listOf("ublock-filters", "ublock-experimental")
    val worlds = listOf("main", "isolated")

    /** The scripts of one world, in the order they must run. */
    fun scriptPaths(world: String) =
        (listOf("scriptlet-begin") + rulesets + "scriptlet-end").map { "rulesets/scripting/scriptlet/$world/$it.js" }

    /** Every file a complete copy has, relative to its folder. */
    val files get() = listOf("manifest.json", "LICENSE.txt") + worlds.flatMap(::scriptPaths)

    class Copy(val version: String, val read: (String) -> ByteArray?)

    fun storeDir(context: Context) = File(context.filesDir, "uBOLite")

    fun bundled(context: Context): Copy? {
        val assets = context.assets
        val exists = { path: String -> runCatching { assets.open("uBOLite/$path").close() }.isSuccess }
        return copy(exists) { path -> runCatching { assets.open("uBOLite/$path").use { it.readBytes() } }.getOrNull() }
    }

    fun copyAt(folder: File): Copy? =
        copy({ File(folder, it).isFile }) { path -> File(folder, path).takeIf { it.isFile }?.readBytes() }

    /** A copy counts only when every file is there and its manifest has a version. */
    private fun copy(exists: (String) -> Boolean, read: (String) -> ByteArray?): Copy? {
        if (!files.all(exists)) return null
        val version = read("manifest.json")?.let(::versionFromManifest) ?: return null
        return Copy(version, read)
    }

    /** The newest complete copy, bundled or downloaded. */
    fun newest(context: Context): Copy? =
        (downloaded(context) + listOfNotNull(bundled(context))).maxWithOrNull { a, b -> compare(a.version, b.version) }

    private fun downloaded(context: Context): List<Copy> =
        storeDir(context).listFiles().orEmpty()
            .filter { it.isDirectory && !it.name.endsWith(".download") }
            .mapNotNull(::copyAt)

    /** The manifest's version, accepted only as digits and dots ("2026.1018.2229"): it becomes a folder name. */
    fun versionFromManifest(data: ByteArray): String? =
        runCatching { JSONObject(String(data, Charsets.UTF_8)).getString("version") }.getOrNull()
            ?.takeIf { v -> v.isNotEmpty() && v.all { it in '0'..'9' || it == '.' } }

    /** Versions compared number by number. */
    fun compare(a: String, b: String): Int {
        val x = a.split('.').map { it.toIntOrNull() ?: 0 }
        val y = b.split('.').map { it.toIntOrNull() ?: 0 }
        for (i in 0 until maxOf(x.size, y.size)) {
            val d = x.getOrElse(i) { -1 }.compareTo(y.getOrElse(i) { -1 })
            if (d != 0) return d
        }
        return 0
    }

    fun isOlder(a: String, than: String) = compare(a, than) < 0
}

/**
 * Fetches uBO Lite's newest scriptlet files straight from the uBOL-home repository, which keeps the built
 * Chromium package in `chromium/`, file by file from one commit (same as Mac/iOS). Blocking calls: run them
 * off the main thread.
 */
object UBOLiteUpdater {
    sealed interface Outcome {
        /** No newer version than the newest one already on this device. */
        data class UpToDate(val version: String) : Outcome
        /** A newer version was saved; it is used from the next app start. */
        data class Downloaded(val version: String) : Outcome
        data class Failed(val message: String) : Outcome
    }

    /** What the ⋯ button and menu show. */
    sealed interface Status {
        data object Current : Status
        /** GitHub has a newer version than any on the device (the ⋯ button shows a green dot). */
        data class Available(val version: String) : Status
        /** A newer version is downloaded and waits for the next app start. */
        data class Downloaded(val version: String) : Status
    }

    private const val LATEST_COMMIT =
        "https://api.github.com/repos/uBlockOrigin/uBOL-home/commits?path=chromium/manifest.json&per_page=1"
    private fun fileUrl(commit: String, path: String) =
        "https://raw.githubusercontent.com/uBlockOrigin/uBOL-home/$commit/chromium/$path"

    private const val LAST_CHECK = "lastCheck"
    private const val LATEST_VERSION = "latestVersion"
    private fun prefs(context: Context) = context.getSharedPreferences("uBOLite", Context.MODE_PRIVATE)

    /** From the copies on the device and the last check's result, so it needs no network. */
    fun status(context: Context, running: String?): Status {
        val onDisk = UBOLite.newest(context)?.version
        val latest = prefs(context).getString(LATEST_VERSION, null)
        val have = onDisk ?: running
        if (latest != null && have != null && UBOLite.isOlder(have, latest)) return Status.Available(latest)
        if (onDisk != null && running != null && UBOLite.isOlder(running, onDisk)) return Status.Downloaded(onDisk)
        return Status.Current
    }

    /** Asks GitHub for the newest version at most once per interval and remembers it; downloads nothing.
     *  True when it checked. A failed check is not remembered, so it is retried the next time. */
    fun checkIfDue(context: Context, intervalMs: Long = 24 * 60 * 60 * 1000L): Boolean {
        if (System.currentTimeMillis() - prefs(context).getLong(LAST_CHECK, 0) < intervalMs) return false
        val (version, _, _) = runCatching { latest() }.getOrNull() ?: return false
        remember(context, version)
        return true
    }

    /** Downloads the newest version when it is newer than every copy on the device, then removes older
     *  downloads. The copy in use stays loaded until the app restarts. */
    fun update(context: Context): Outcome = try {
        val have = UBOLite.newest(context)?.version
        val (latest, commit, manifest) = latest()
        remember(context, latest)
        if (have != null && !UBOLite.isOlder(have, latest)) {
            Outcome.UpToDate(have)
        } else {
            // Fill a temporary folder first, so a failed download never leaves a half copy behind.
            val store = UBOLite.storeDir(context)
            val target = File(store, latest)
            val temp = File(store, "$latest.download")
            temp.deleteRecursively()
            for (path in UBOLite.files) {
                val data = if (path == "manifest.json") manifest else fetch(fileUrl(commit, path))
                if (data.isEmpty()) error("ไฟล์ว่าง: $path")
                File(temp, path).apply { parentFile?.mkdirs() }.writeBytes(data)
            }
            if (UBOLite.copyAt(temp)?.version != latest) error("ไฟล์ที่ดาวน์โหลดไม่ครบ")
            target.deleteRecursively()
            if (!temp.renameTo(target)) error("ย้ายไฟล์ไม่ได้")
            store.listFiles().orEmpty().filter { it.name != latest }.forEach { it.deleteRecursively() }
            Outcome.Downloaded(latest)
        }
    } catch (e: Exception) {
        Outcome.Failed(e.message ?: e.toString())
    }

    /** The newest version on GitHub, the commit it was built in, and its manifest. */
    private fun latest(): Triple<String, String, ByteArray> {
        val commits = JSONArray(String(fetch(LATEST_COMMIT), Charsets.UTF_8))
        val commit = commits.optJSONObject(0)?.optString("sha").orEmpty()
        if (commit.length != 40 || !commit.all { it in '0'..'9' || it in 'a'..'f' }) error("อ่านรุ่นล่าสุดจาก GitHub ไม่ได้")
        val manifest = fetch(fileUrl(commit, "manifest.json"))
        val version = UBOLite.versionFromManifest(manifest) ?: error("อ่านเลขรุ่นจาก manifest ไม่ได้")
        return Triple(version, commit, manifest)
    }

    private fun remember(context: Context, latest: String) {
        prefs(context).edit().putLong(LAST_CHECK, System.currentTimeMillis()).putString(LATEST_VERSION, latest).apply()
    }

    private fun fetch(url: String): ByteArray {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 30_000
            connection.readTimeout = 30_000
            connection.setRequestProperty("User-Agent", "Lumen") // GitHub's API refuses requests without one
            if (connection.responseCode != 200) error("GitHub ตอบ ${connection.responseCode} สำหรับ ${url.substringAfterLast('/')}")
            return connection.inputStream.use { it.readBytes() }
        } finally {
            connection.disconnect()
        }
    }
}
