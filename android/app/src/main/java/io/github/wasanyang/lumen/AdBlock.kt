package io.github.wasanyang.lumen

import android.content.Context
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream

/**
 * The same layers as shared/LumenCore/AdBlock.swift on Mac and iOS, in the order they act:
 * 1. Network: shared/blocklist.txt. Every request of the web view and of its service workers is checked
 *    (one hash lookup per host label) and a match gets an empty 403.
 * 2. uBlock Origin Lite's YouTube scriptlets (see UBOLite). They take the ads out of YouTube's player
 *    data, so most ads never start.
 * 3. Cosmetic: CSS that hides ad slots which still render.
 * 4. Fallback for an ad that gets through: mute it, run it at 16x and ask the app to tap skip for real.
 * Android's WebView has no isolated script worlds like WebKit, so uBO's isolated scriptlets and our page
 * script run in the page's own world.
 */
object AdBlock {
    class Blocklist(private val domains: Set<String>, private val patterns: List<Regex>) {
        val size get() = domains.size + patterns.size

        /** Called on the web view's network threads, so it only reads. */
        fun blocks(url: String): Boolean {
            var host = hostOf(url) ?: return false
            while (true) {
                if (host in domains) return true
                val dot = host.indexOf('.')
                if (dot < 0) break
                host = host.substring(dot + 1)
            }
            return patterns.any { it.matches(url) }
        }
    }

    fun load(context: Context): Blocklist =
        parse(runCatching { context.assets.open("blocklist.txt").bufferedReader().use { it.readText() } }.getOrDefault(""))

    /** Same format as Windows and Mac/iOS: a bare domain blocks it and all subdomains; a line containing
     *  * or / is a URL pattern where * matches anything. */
    fun parse(text: String): Blocklist {
        val domains = HashSet<String>()
        val patterns = ArrayList<Regex>()
        for (raw in text.lineSequence()) {
            val line = raw.trim()
            if (line.isEmpty() || line.startsWith("#")) continue
            if ('*' in line || '/' in line) patterns += patternRegex(line) else domains += line.lowercase()
        }
        return Blocklist(domains, patterns)
    }

    fun patternRegex(line: String): Regex {
        var body = line
        val regex = StringBuilder("^")
        if (body.startsWith("*://")) {
            regex.append("[^:]+://")
            body = body.removePrefix("*://")
        }
        regex.append(body.split('*').joinToString(".*") { if (it.isEmpty()) "" else Regex.escape(it) })
        if (!line.endsWith("*")) regex.append('$')
        return Regex(regex.toString())
    }

    /** The host of an http(s) URL, lower case, without user info or port. */
    fun hostOf(url: String): String? {
        val start = url.indexOf("://").takeIf { it > 0 }?.plus(3) ?: return null
        var end = url.length
        for (c in "/?#") url.indexOf(c, start).takeIf { it >= 0 && it < end }?.let { end = it }
        var host = url.substring(start, end)
        host = host.substringAfterLast('@')
        if (!host.startsWith("[")) host = host.substringBefore(':')
        return host.lowercase().ifEmpty { null }
    }

    fun blockedResponse() =
        WebResourceResponse("text/plain", "utf-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))

    /** One script per uBO world (main, then isolated), each wrapped so it only runs on YouTube. */
    fun uBOScripts(copy: UBOLite.Copy): List<String> = UBOLite.worlds.mapNotNull { world ->
        val parts = UBOLite.scriptPaths(world).map { copy.read(it)?.toString(Charsets.UTF_8) ?: return@mapNotNull null }
        "if (/(^|\\.)youtube\\.com$/.test(location.hostname)) {\n" + parts.joinToString("\n") + "\n}"
    }

    /** Layers 3 and 4, plus the playing/paused reports the notification needs. Messages go to
     *  `window.lumen`, which the app adds on YouTube only. */
    val pageScript = """
        (() => {
          // ---- Layer 3: hide ad slots ----
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

          if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.top !== window) return;
          const post = (msg) => window.lumen?.postMessage(JSON.stringify(msg));

          // ---- Layer 4: if an ad still plays, mute it, run it at 16x and press skip ----
          // YouTube ignores script clicks on the skip button, so the app taps it for real.
          let inAd = false, mutedByUs = false, savedRate = null, skipSentAt = 0;
          setInterval(() => {
            const player = document.getElementById('movie_player');
            const video = player?.querySelector('video');
            if (!video) return;
            if (player.classList.contains('ad-showing')) {
              if (!inAd) { inAd = true; post({ type: 'ad-start' }); }
              const skip = document.querySelector('.ytp-skip-ad-button, .ytp-ad-skip-button, .ytp-ad-skip-button-modern');
              if (skip?.offsetParent && Date.now() - skipSentAt > 1000) {
                const r = skip.getBoundingClientRect();
                const scale = window.devicePixelRatio * (window.visualViewport?.scale || 1);
                post({ type: 'skip-ad', x: r.left + r.width / 2, y: r.top + r.height / 2, scale });
                skipSentAt = Date.now();
              }
              if (!video.muted) { video.muted = true; mutedByUs = true; }
              if (savedRate === null) savedRate = video.playbackRate;
              if (video.playbackRate !== 16) video.playbackRate = 16;
              const atEnd = video.ended || video.currentTime >= video.duration - 0.5;
              if (video.paused && !atEnd && video.readyState > 0) video.play().catch(() => {});
            } else {
              inAd = false;
              if (mutedByUs) { video.muted = false; mutedByUs = false; }
              // Only undo our 16x; leave any speed YouTube applied to the real video.
              if (savedRate !== null) { if (video.playbackRate === 16) video.playbackRate = savedRate; savedRate = null; }
            }
          }, 250);

          // ---- Playing or paused, for the notification and lock screen ----
          const report = (e) => {
            if (!(e.target instanceof HTMLVideoElement)) return;
            post({ type: 'media', playing: e.type === 'playing', title: document.title.replace(/ - YouTube$/, '') });
          };
          for (const type of ['playing', 'pause', 'ended']) document.addEventListener(type, report, true);
        })();
    """.trimIndent()

    /** Same as iOS: YouTube pauses a video when the page says it is hidden, so the page stays "visible".
     *  And while the app is leaving the screen (armed by MainActivity), a pause no page script asked for
     *  is the web view's own: play on at once. A pause from the notification or YouTube's own button goes
     *  through pause(), so it is respected, and outside the armed time nothing is resumed. */
    val backgroundPlayScript = """
        (() => {
          if (!/(^|\.)youtube\.com$/.test(location.hostname) || window.top !== window) return;
          let scriptPauseAt = 0;
          const pause = HTMLMediaElement.prototype.pause;
          HTMLMediaElement.prototype.pause = function () { scriptPauseAt = Date.now(); return pause.apply(this, arguments); };
          document.addEventListener('pause', (e) => {
            const media = e.target;
            if (!(media instanceof HTMLMediaElement)) return;
            if (Date.now() > (window.__lumenLeavingUntil || 0) || Date.now() - scriptPauseAt < 500) return;
            media.play().catch(() => {});
          }, true);
          for (const [name, value] of [['hidden', false], ['webkitHidden', false],
                                       ['visibilityState', 'visible'], ['webkitVisibilityState', 'visible']]) {
            Object.defineProperty(Document.prototype, name, { get: () => value, configurable: true });
          }
          for (const type of ['visibilitychange', 'webkitvisibilitychange']) {
            window.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
            document.addEventListener(type, (e) => e.stopImmediatePropagation(), true);
          }
        })();
    """.trimIndent()
}
