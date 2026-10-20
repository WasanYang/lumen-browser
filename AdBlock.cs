using System.IO;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace MiniBrowser;

/// <summary>
/// Three layers:
/// 1. Network: URL patterns from blocklist.txt are registered as WebView2 filters, so only
///    matching requests ever reach C# (everything else costs nothing) and they get a 403.
/// 2. Cosmetic: CSS that hides ad slots which still render.
/// 3. YouTube: auto-skips video ads (mute + 16x speed + real click on skip). Optionally also strips
///    ad data from the player response (PruneYouTubeAds).
/// </summary>
sealed class AdBlock(List<string> patterns)
{
    /// Stripping ad data hides YouTube ads completely, but YouTube notices and delays video
    /// start by roughly 3–13 s (measured), so it is off by default and auto-skip is used instead.
    public static bool PruneYouTubeAds = false;

    /// Older GPUs without VP9/AV1 hardware decoding play YouTube much more smoothly with H.264.
    public static bool ForceH264 = false;

    public static AdBlock Load(string path)
    {
        var patterns = new List<string>();
        if (!File.Exists(path)) return new AdBlock(patterns);
        foreach (var raw in File.ReadLines(path))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (line.Contains('*') || line.Contains('/'))
            {
                patterns.Add(line);
            }
            else
            {
                patterns.Add($"*://{line}/*");
                patterns.Add($"*://*.{line}/*");
            }
        }
        return new AdBlock(patterns);
    }

    public async Task AttachAsync(CoreWebView2 core, CoreWebView2Environment env)
    {
        foreach (var pattern in patterns)
            core.AddWebResourceRequestedFilter(pattern, CoreWebView2WebResourceContext.All,
                CoreWebView2WebResourceRequestSourceKinds.All);
        core.WebResourceRequested += (_, e) =>
            e.Response = env.CreateWebResourceResponse(null, 403, "Blocked", "");

        core.WebMessageReceived += (_, e) => SkipAdClick(core, e);

        await core.AddScriptToExecuteOnDocumentCreatedAsync(PageScript
            .Replace("__PRUNE__", PruneYouTubeAds ? "true" : "false")
            .Replace("__FORCE_H264__", ForceH264 ? "true" : "false"));
    }

    /// Clicks YouTube's skip button as a real (trusted) mouse click at the position the page reported.
    static async void SkipAdClick(CoreWebView2 core, CoreWebView2WebMessageReceivedEventArgs e)
    {
        if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var source) ||
            !(source.Host == "youtube.com" || source.Host.EndsWith(".youtube.com"))) return;
        try
        {
            using var doc = JsonDocument.Parse(e.WebMessageAsJson);
            var msg = doc.RootElement;
            if (!msg.TryGetProperty("type", out var type) || type.GetString() != "skip-ad") return;
            var x = msg.GetProperty("x").GetDouble();
            var y = msg.GetProperty("y").GetDouble();
            foreach (var kind in new[] { "mousePressed", "mouseReleased" })
                await core.CallDevToolsProtocolMethodAsync("Input.dispatchMouseEvent",
                    JsonSerializer.Serialize(new { type = kind, x, y, button = "left", clickCount = 1 }));
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException) { }
    }

    const string PageScript = """
        (() => {
          // ---- Layer 2: hide ad slots ----
          const css = `
            ins.adsbygoogle, [id^="google_ads_iframe"], [id^="div-gpt-ad"], .adsbox,
            ytd-ad-slot-renderer, ytd-in-feed-ad-layout-renderer, ytd-display-ad-renderer,
            ytd-promoted-sparkles-web-renderer, ytd-promoted-video-renderer,
            ytd-banner-promo-renderer, ytd-action-companion-ad-renderer,
            ytd-companion-slot-renderer, ytd-player-legacy-desktop-watch-ads-renderer,
            ytd-rich-item-renderer:has(> #content > ytd-ad-slot-renderer),
            ytd-rich-section-renderer:has(ytd-statement-banner-renderer),
            #masthead-ad, #player-ads, .ytp-ad-overlay-container, .ytp-ad-image-overlay,
            ytm-promoted-sparkles-web-renderer, ad-slot-renderer
            { display: none !important; }`;
          const addCss = () => {
            if (!document.documentElement) return false;
            const style = document.createElement('style');
            style.textContent = css;
            document.documentElement.appendChild(style);
            return true;
          };
          if (!addCss()) {
            const mo = new MutationObserver(() => { if (addCss()) mo.disconnect(); });
            mo.observe(document, { childList: true });
          }

          if (!/(^|\.)youtube\.com$/.test(location.hostname)) return;

          // ---- Layer 3 (optional): remove ads from the player response ----
          if (__PRUNE__) {
            const AD_KEYS = ['adPlacements', 'adSlots', 'playerAds'];
            const prune = (o) => {
              if (o && typeof o === 'object') {
                for (const k of AD_KEYS) if (k in o) delete o[k];
                if (o.playerResponse) prune(o.playerResponse);
              }
              return o;
            };
            const parse = JSON.parse;
            JSON.parse = function (...args) { return prune(parse.apply(this, args)); };
            const json = Response.prototype.json;
            Response.prototype.json = async function () { return prune(await json.call(this)); };
            let initial;
            Object.defineProperty(window, 'ytInitialPlayerResponse', {
              configurable: true,
              get: () => initial,
              set: (v) => { initial = prune(v); },
            });
          }

          // ---- Layer 3: if an ad plays, mute it, run it at 16x and press skip ----
          // Seeking to the end stalls while that segment loads, and YouTube ignores script
          // clicks on the skip button, so the app clicks it for real (see SkipAdClick).
          let mutedByUs = false, savedRate = null, skipSentAt = 0;
          setInterval(() => {
            const player = document.getElementById('movie_player');
            const video = player?.querySelector('video');
            if (!video) return;
            if (player.classList.contains('ad-showing')) {
              const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
              if (skip?.offsetParent && Date.now() - skipSentAt > 1000) {
                const r = skip.getBoundingClientRect();
                window.chrome?.webview?.postMessage({ type: 'skip-ad', x: r.left + r.width / 2, y: r.top + r.height / 2 });
                skipSentAt = Date.now();
              }
              if (!video.muted) { video.muted = true; mutedByUs = true; }
              if (savedRate === null) savedRate = video.playbackRate;
              if (video.playbackRate !== 16) video.playbackRate = 16;
              if (video.paused && !video.ended && video.readyState > 0) video.play().catch(() => {});
            } else {
              if (mutedByUs) { video.muted = false; mutedByUs = false; }
              // Only undo our 16x; leave any speed YouTube applied to the real video.
              if (savedRate !== null) { if (video.playbackRate === 16) video.playbackRate = savedRate; savedRate = null; }
            }
          }, 250);

          // Optional: hide VP9/AV1 so YouTube streams H.264.
          if (__FORCE_H264__) {
            for (const MS of [window.MediaSource, window.ManagedMediaSource]) {
              if (!MS) continue;
              const supported = MS.isTypeSupported.bind(MS);
              MS.isTypeSupported = (type) => /vp0?9|av01/i.test(type) ? false : supported(type);
            }
          }
        })();
        """;
}
