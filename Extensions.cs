using System.IO;
using System.IO.Compression;
using System.Net.Http;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace MiniBrowser;

/// <summary>
/// Loads unpacked browser extensions. Two sources, newest version wins per extension:
/// - bundled:    &lt;app&gt;\Extensions\&lt;name&gt;\
/// - downloaded: &lt;profile&gt;\Extensions\&lt;name&gt;\&lt;version&gt;\  (written by the update button)
/// An extension is reinstalled only when its version changes, so its own settings survive restarts.
/// Installs happen only at startup: swapping an extension while pages are open left WebView2's
/// network stuck until restart (tested), so the update button just downloads.
/// </summary>
static class Extensions
{
    public const string UBlockKey = "uBOLite";
    const string UBlockReleaseApi = "https://api.github.com/repos/uBlockOrigin/uBOL-home/releases/latest";

    static string BundledFolder => Path.Combine(AppContext.BaseDirectory, "Extensions");
    static string UpdatesFolder(string dataDir) => Path.Combine(dataDir, "Extensions");
    static string StampFile(string dataDir, string key) => Path.Combine(dataDir, $"extension-{key}.txt");

    public static async Task InstallAsync(CoreWebView2Profile profile, string dataDir)
    {
        foreach (var (key, dir, version) in FindNewest(dataDir))
        {
            await EnsureInstalledAsync(profile, dataDir, key, dir, version);
            DeleteOldDownloads(dataDir, key, keep: dir);
        }
    }

    /// The newest downloaded version waiting to be installed at the next start, or null.
    public static Version? PendingVersion(string dataDir, string key)
    {
        var downloaded = FindNewest(dataDir).FirstOrDefault(f => f.Key == key);
        var installed = InstalledVersion(dataDir, key);
        return downloaded.Dir is not null && (installed is null || downloaded.Version > installed)
            ? downloaded.Version : null;
    }

    /// The version currently installed in the profile, or null if none.
    public static Version? InstalledVersion(string dataDir, string key)
    {
        var stamp = StampFile(dataDir, key);
        if (!File.Exists(stamp)) return null;
        var parts = File.ReadAllText(stamp).Split('|');
        return parts.Length == 2 && Version.TryParse(parts[1], out var v) ? v : null;
    }

    /// Downloads the latest uBO Lite (Edge build) from its GitHub releases; it is installed at
    /// the next start. Returns a message for the user.
    public static async Task<string> DownloadUBlockUpdateAsync(string dataDir)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(2) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("MiniBrowser");

        using var release = JsonDocument.Parse(await http.GetStringAsync(UBlockReleaseApi));
        var root = release.RootElement;
        if (!Version.TryParse(root.GetProperty("tag_name").GetString(), out var latest))
            return "อ่านเลขรุ่นล่าสุดจาก GitHub ไม่ได้";
        var asset = root.GetProperty("assets").EnumerateArray()
            .FirstOrDefault(a => a.GetProperty("name").GetString()?.EndsWith(".edge.zip") == true);
        if (asset.ValueKind == JsonValueKind.Undefined)
            return $"รุ่น {latest} ไม่มีไฟล์สำหรับ Edge";

        var current = InstalledVersion(dataDir, UBlockKey);
        if (current is not null && latest <= current)
            return $"uBO Lite เป็นรุ่นล่าสุดแล้ว ({current})";
        if (PendingVersion(dataDir, UBlockKey) is { } pending && latest <= pending)
            return $"ดาวน์โหลดรุ่น {pending} ไว้แล้ว ปิดแล้วเปิด MiniBrowser ใหม่เพื่อเริ่มใช้";

        // Extract next to the final folder first, so a failed download never leaves a half folder.
        var target = Path.Combine(UpdatesFolder(dataDir), UBlockKey, latest.ToString());
        var temp = target + ".download";
        if (Directory.Exists(temp)) Directory.Delete(temp, true);
        var zip = await http.GetByteArrayAsync(asset.GetProperty("browser_download_url").GetString());
        ZipFile.ExtractToDirectory(new MemoryStream(zip), temp);
        if (ReadVersion(temp) != latest)
        {
            Directory.Delete(temp, true);
            return "ไฟล์ที่ดาวน์โหลดมาไม่ตรงกับรุ่นที่ประกาศ จึงไม่ได้ติดตั้ง";
        }
        if (Directory.Exists(target)) Directory.Delete(target, true);
        Directory.Move(temp, target);
        return $"ดาวน์โหลด uBO Lite รุ่น {latest} แล้ว (ตอนนี้ใช้ {current?.ToString() ?? "-"})\n" +
               "ปิดแล้วเปิด MiniBrowser ใหม่เพื่อเริ่มใช้รุ่นใหม่";
    }

    static async Task EnsureInstalledAsync(CoreWebView2Profile profile, string dataDir, string key, string dir, Version version)
    {
        var stamp = StampFile(dataDir, key);
        var parts = File.Exists(stamp) ? File.ReadAllText(stamp).Split('|') : ["", ""];
        var installed = await profile.GetBrowserExtensionsAsync();
        var existing = installed.FirstOrDefault(e => e.Id == parts[0]);
        if (existing is not null && parts.Length == 2 && parts[1] == version.ToString())
        {
            if (!existing.IsEnabled) await existing.EnableAsync(true);
            return;
        }
        if (existing is not null) await existing.RemoveAsync();
        var added = await profile.AddBrowserExtensionAsync(dir);
        File.WriteAllText(stamp, $"{added.Id}|{version}");
    }

    static IEnumerable<(string Key, string Dir, Version Version)> FindNewest(string dataDir)
    {
        // Downloads are listed first so they win a version tie (MaxBy keeps the first maximum);
        // otherwise startup cleanup could delete the folder the installed extension runs from.
        var found = new List<(string Key, string Dir, Version Version)>();
        var updates = UpdatesFolder(dataDir);
        if (Directory.Exists(updates))
            foreach (var keyDir in Directory.GetDirectories(updates))
                foreach (var dir in Directory.GetDirectories(keyDir))
                    if (ReadVersion(dir) is { } v) found.Add((Path.GetFileName(keyDir), dir, v));

        if (Directory.Exists(BundledFolder))
            foreach (var dir in Directory.GetDirectories(BundledFolder))
                if (ReadVersion(dir) is { } v) found.Add((Path.GetFileName(dir), dir, v));

        return found.GroupBy(f => f.Key, StringComparer.OrdinalIgnoreCase)
            .Select(g => g.MaxBy(f => f.Version));
    }

    static Version? ReadVersion(string dir)
    {
        var manifest = Path.Combine(dir, "manifest.json");
        if (!File.Exists(manifest)) return null;
        using var doc = JsonDocument.Parse(File.ReadAllText(manifest));
        return doc.RootElement.TryGetProperty("version", out var v) && Version.TryParse(v.GetString(), out var version)
            ? version : null;
    }

    static void DeleteOldDownloads(string dataDir, string key, string keep)
    {
        var folder = Path.Combine(UpdatesFolder(dataDir), key);
        if (!Directory.Exists(folder)) return;
        foreach (var dir in Directory.GetDirectories(folder))
        {
            if (string.Equals(dir, keep, StringComparison.OrdinalIgnoreCase)) continue;
            try { Directory.Delete(dir, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
