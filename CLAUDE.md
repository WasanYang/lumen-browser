# MiniBrowser — context for Claude

Minimal ad-blocking browser, used almost only for YouTube. Goals: fast, no stutter, low RAM, low network.
Monorepo: one folder per platform, shared files in `shared/`.

## Working with the owner
- Reply in Thai. Answer briefly first; the owner asks follow-ups.
- The owner often asks "can this be done?" before deciding. Explain and wait; change code only when asked.
- Never commit or push until the owner has reviewed and said so. No `Co-Authored-By` or Claude attribution in commits.

## Layout
- `windows/`: C# / WPF / WebView2 (.NET 10). `AdBlock.cs` (network filters + page CSS + YouTube ad skip script),
  `Extensions.cs` (bundled uBlock Origin Lite in `windows/Extensions/uBOLite`), `MainWindow.xaml.cs` (tabs, sleep).
  `installer/` holds the Inno Setup script and `build.ps1`.
- `shared/`: `Assets/` (logo.svg, logo-mark.svg, logo.ico) and `blocklist.txt`. The csproj links both
  (`blocklist.txt` is copied next to the exe, `logo.ico` is the window/exe icon).
- `ios/`: not started. The plan is in `ios/README.md` (Swift + WKWebView, XcodeGen `project.yml`).

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

## Next steps the owner has in mind
1. iOS app on a Mac: background playback, ad blocking, persistent login (see `ios/README.md`).
2. Versioning for releases (`<Version>` in csproj, `build.ps1 -Version`).
3. Optional perf ideas discussed: discard long-idle tabs, AV1-only codec block instead of ForceH264, hover-preview block.
