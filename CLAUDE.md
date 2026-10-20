# MiniBrowser — context for Claude

Minimal ad-blocking browser, used almost only for YouTube. Goals: fast, no stutter, low RAM, low network.
Monorepo: one folder per platform, shared files in `shared/`.

## Working with the owner
- Reply in Thai. Answer briefly first; the owner asks follow-ups.
- The owner often asks "can this be done?" before deciding. Explain and wait; change code only when asked.
- Never commit or push until the owner has reviewed and said so. No `Co-Authored-By` or Claude attribution in commits.
- Commit author is always `Wasan <33808589+WasanYang@users.noreply.github.com>` (owner, 20 Oct 2026), on every machine.
  Before the first commit in a clone, check `git config user.email`; if it differs, set it for this repo:
  `git config user.name "Wasan"` and `git config user.email "33808589+WasanYang@users.noreply.github.com"`.

## Layout
- `windows/`: C# / WPF / WebView2 (.NET 10). `AdBlock.cs` (network filters + page CSS + YouTube ad skip script),
  `Extensions.cs` (bundled uBlock Origin Lite in `windows/Extensions/uBOLite`), `MainWindow.xaml.cs` (tabs, sleep).
  `installer/` holds the Inno Setup script and `build.ps1`.
- `shared/`: `Assets/` (logo.svg, logo-mark.svg, logo.ico) and `blocklist.txt`. The csproj links both
  (`blocklist.txt` is copied next to the exe, `logo.ico` is the window/exe icon).
  `shared/LumenCore/`: Swift package (macOS 14, iOS 17) with the ad blocking used by `macos/` and later `ios/`:
  `AdBlock.swift` (blocklist.txt → WKContentRuleList, uBO Lite's YouTube scriptlets, page CSS, the 16x/skip page
  script; it reports where to press skip, each app presses) and `UBOLite.swift` (picks the newest uBO copy, bundled
  or downloaded; `UBOLiteUpdater` checks GitHub (`checkIfDue`, `status`) and downloads the newest built files
  (`update`) as separate steps). No AppKit/UIKit in it.
  Check it still builds for iOS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -scheme LumenCore
  -destination 'generic/platform=iOS' build` in `shared/LumenCore` (Xcode 27.1 is installed but not the selected
  developer dir, so pass DEVELOPER_DIR instead of running xcode-select).
- `macos/`: the Mac app is named **Lumen** (owner, 20 Oct 2026; Windows keeps MiniBrowser until the owner renames it
  there). The bundle ID stays `io.github.wasanyang.minibrowser` because YouTube logins are stored under it.
  One window. Swift package `Lumen` (depends on `../shared/LumenCore`), built with the Command Line Tools alone.
  `PageClick.swift` (real NSEvent click on YouTube's skip button), `BrowserWindow.swift`, `SelfTest.swift`,
  `main.swift` (menus; checks GitHub for a newer uBO at most once a day, at start and hourly). The top bar's
  ↻ uBO button shows a green dot when a newer version exists; downloading happens only when the owner presses it
  (owner's choice, 20 Oct 2026), then it offers a restart. Build `macos/build.sh` →
  `macos/build/Lumen.app` (copies the uBO scriptlet files from `windows/Extensions/uBOLite`, renders the icon
  from `shared/Assets/logo.svg` with `make-icon.swift`). `build.sh --install` replaces `/Applications/Lumen.app`,
  which the owner uses day to day.
  Verify with `build/Lumen.app/Contents/MacOS/Lumen --selftest` (must print ALL PASSED).
  Goal (owner, 20 Oct 2026): listen to music on YouTube only. Other browsers carry too many tools and feel slow, so keep
  the Mac app small; no site-wide filter lists or features unrelated to YouTube.
- `ios/`: **Lumen** for iPhone and iPad (one universal app, iOS 17+), Swift + UIKit + WKWebView, using `LumenCore`.
  `project.yml` (XcodeGen; `Lumen.xcodeproj` and `Generated/` are generated, not committed), `build.sh sim [--selftest]
  | device`, `Sources/Lumen/` (`LumenApp.swift` audio session, `BrowserViewController.swift` web view, ⋯ menu,
  uBO update, background play; `FloatingBar.swift` the Safari-style bar the owner asked for instead of a toolbar; `SelfTestView.swift` runs `SelfTestCore`). Bundle ID `io.github.wasanyang.lumen`,
  the owner's free personal team `4UWS4ZVGMD` (apps expire after 7 days; re-run `build.sh device`).
  Shared build helpers: `shared/copy-ubo.sh` (uBO files) and `shared/Assets/make-icon.swift mac|ios`.

## Windows build
- Run: `dotnet run -c Release` in `windows/`.
- Installer: `powershell -ExecutionPolicy Bypass -File windows\installer\build.ps1` → `windows\installer\Output\MiniBrowser-Setup-<ver>.exe`.
  Installs per user to `%LOCALAPPDATA%\Programs\MiniBrowser`; the same AppId means re-running it updates in place.
  Browsing data stays in `%LOCALAPPDATA%\MiniBrowser` (`MINIBROWSER_DATA` overrides).
- No `<Version>` is set yet, so builds are 1.0.0.0. The owner wants versioned releases later.

## Measured facts (do not re-learn the hard way)
- `dotnet publish` with PublishSingleFile **again over an existing publish folder** drops WebView2Loader.dll,
  blocklist.txt and all of Extensions, and the app then crashes on start (DllNotFoundException). Always publish into an emptied folder.
- Installing/updating a WebView2 extension while pages are open left WebView2 networking stuck until restart,
  so uBO updates are only downloaded and are installed at the next start.
- `AdBlock.PruneYouTubeAds` (strip ad data from the player response) makes YouTube delay video start by about 3–13 s, so it is off.
- YouTube telemetry (`/api/stats/qoe`, `atr`, `/youtubei/v1/log_event`) is about 3 KB per 25 s, so blocking it is a privacy gain, not speed.
  `watchtime` / `playback` drive watch history and resume. Do not block them.
- Hover previews on YouTube download about 0.8–1.2 MB per 6 s hover. Tested in Chromium, signed out, search page:
  - CSS hiding (what userscripts do) still downloads.
  - Rejecting `play()` still prebuffers (~1.8 MB).
  - Blocking `videoplayback?...epbp=1` **breaks the main player**.
  - Capture-phase `stopImmediatePropagation` of mouseenter/over/move + pointer* on the whole card
    (`ytd-video-renderer, ytd-rich-item-renderer, ytd-compact-video-renderer, ytd-grid-video-renderer, yt-lockup-view-model, ytd-reel-item-renderer`)
    → 0 KB, ⋮ menu and click-to-play still work. Not yet implemented (owner deferred). Planned as an `AdBlock.DisableHoverPreview` flag.

## Measured facts — macOS (20 Oct 2026, macOS 26.6, Apple Silicon)
- WKContentRuleList built from blocklist.txt blocks every ad URL in the self-test while the same URLs load without it.
  WebKit's url-filter has no `|` or `{n}`; a bare domain becomes `^[^:]+://+([^:/]+\.)?domain[:/]`.
- `NSEvent` mouse down/up passed straight to `WKWebView.mouseDown/mouseUp` give `isTrusted = true` clicks,
  also while the app is hidden. So the Windows skip-click approach works on Mac without DevTools.
- The page script runs in a named WKContentWorld; DOM changes (mute, playbackRate) still reach YouTube's player.
- Google sign-in works in WKWebView with `applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"` (owner tested).
- Real YouTube, signed out, 7 popular music videos (probe in a scratch copy, not in the repo):
  - Our own layers only (16x + skip click): ads in 6 of 7. Skippable ads were skipped within ~1 s, but YouTube's
    non-skippable 6 s / 15 s ads have no skip button, so they only ran fast. The owner did not want that.
  - Our own prune (`JSON.parse` / `Response.json` override): no ads, but video start 13–17 s after page load.
  - uBO Lite scriptlets (current build): no ads in 7 of 7, every video played, start 8–15 s after page load.
    DuckDuckGo for Mac (also WKWebView) uses the same uBO lists and says its blocker adds some buffering too.
    Owner tested it signed in (20 Oct 2026): works, start delay acceptable, feels better than DuckDuckGo.
- uBO Lite's built scriptlet files (`rulesets/scripting/scriptlet/{main,isolated}/`) need no extension API: run
  `scriptlet-begin.js` + ruleset files + `scriptlet-end.js` in one world at document start. YouTube rules are in
  `ublock-filters` and `ublock-experimental`. They include `adjustSetTimeout ["[native code]","17000","0.001"]`
  (cuts YouTube's 17 s wait) and `set-constant ytInitialPlayerResponse.adPlacements undefined` (key stays, value undefined).
  To list what runs on a host, run the files in Node with stub globals and log `functionRefs` calls.

## Measured facts — iOS (20 Oct 2026, Xcode 27.1, iOS 27 simulator; owner's iPhone 17 runs iOS 26.6.2)
- uBO rules per host (run the scriptlet files in Node with stub globals): www.youtube.com 31 main + 3 isolated,
  m.youtube.com 8 main, music.youtube.com 7. m.youtube.com has no `adjustSetTimeout 17000`.
- Simulator, real YouTube, signed out: m.youtube.com played 2 of 2 test videos with no ads, start about 6 s.
  m.youtube.com autoplays muted until the user taps.
- When the app goes to the background, WebKit pauses the <video> itself (pause event with no page `pause()` call),
  even with sound on and `document.hidden` faked. Calling `play()` from the app 0.3 s after
  `didEnterBackground` resumed it and it kept playing (simulator). A muted video is not allowed to play on.
- The Simulator app is not in Xcode 27.1's bundle; `simctl` runs the app headless and `--console-pty` prints its output.

## Next steps the owner has in mind
1. iOS app on a Mac: background playback, ad blocking, persistent login (see `ios/README.md`).
2. Versioning for releases (`<Version>` in csproj, `build.ps1 -Version`).
3. Optional perf ideas discussed: discard long-idle tabs, AV1-only codec block instead of ForceH264, hover-preview block.
