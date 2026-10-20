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
            await EnsureInstalledAsync(profile, dataDir, key, dir, version);
    }

    /// The version currently installed in the profile, or null if none.
    public static Version? InstalledVersion(string dataDir, string key)
    {
        var stamp = StampFile(dataDir, key);
        if (!File.Exists(stamp)) return null;
        var parts = File.ReadAllText(stamp).Split('|');
        return parts.Length == 2 && Version.TryParse(parts[1], out var v) ? v : null;
    }

    /// Downloads the latest uBO Lite (Edge build) from its GitHub releases and installs it
    /// right away. Returns a message for the user.
    public static async Task<string> UpdateUBlockAsync(CoreWebView2Profile profile, string dataDir)
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

        await EnsureInstalledAsync(profile, dataDir, UBlockKey, target, latest);
        DeleteOldDownloads(dataDir, UBlockKey, keep: target);
        return $"อัปเดต uBO Lite เป็นรุ่น {latest} แล้ว (เดิม {current?.ToString() ?? "-"})\n" +
               "กด F5 ที่หน้าเว็บที่เปิดอยู่เพื่อให้รุ่นใหม่มีผล";
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
        var found = new List<(string Key, string Dir, Version Version)>();
        if (Directory.Exists(BundledFolder))
            foreach (var dir in Directory.GetDirectories(BundledFolder))
                if (ReadVersion(dir) is { } v) found.Add((Path.GetFileName(dir), dir, v));

        var updates = UpdatesFolder(dataDir);
        if (Directory.Exists(updates))
            foreach (var keyDir in Directory.GetDirectories(updates))
                foreach (var dir in Directory.GetDirectories(keyDir))
                    if (ReadVersion(dir) is { } v) found.Add((Path.GetFileName(keyDir), dir, v));

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
        foreach (var dir in Directory.GetDirectories(Path.Combine(UpdatesFolder(dataDir), key)))
        {
            if (string.Equals(dir, keep, StringComparison.OrdinalIgnoreCase)) continue;
            try { Directory.Delete(dir, true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}
