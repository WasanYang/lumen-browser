package io.github.wasanyang.lumen

import android.Manifest
import android.annotation.SuppressLint
import android.app.AlertDialog
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.os.SystemClock
import android.text.TextUtils
import android.view.Gravity
import android.view.InputDevice
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.webkit.CookieManager
import android.webkit.ServiceWorkerClient
import android.webkit.ServiceWorkerController
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.PopupMenu
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import org.json.JSONObject
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * YouTube full screen with a bar at the bottom like the iPhone app: back, the site name and a ⋯ menu with
 * forward, reload, home, the uBO update and the ad counter. The ⋯ button shows a green dot when GitHub has a
 * newer uBO Lite. Phones get m.youtube.com.
 */
class MainActivity : ComponentActivity() {
    companion object {
        const val HOME_URL = "https://www.youtube.com"
        /** Where YouTube may talk to the app and where uBO's YouTube rules run. */
        val YOUTUBE = setOf("https://*.youtube.com")
    }

    /** Android's web view pauses a playing video as soon as its window is hidden (measured on Android 16:
     *  a pause no page script asked for, repeated each time the page plays it again). So while music plays,
     *  Lumen leaving the screen does not reach it: it keeps its window "visible". */
    class LumenWebView(context: Context) : WebView(context) {
        var keepVisible = false

        override fun onWindowVisibilityChanged(visibility: Int) {
            super.onWindowVisibilityChanged(if (keepVisible) View.VISIBLE else visibility)
        }
    }

    private lateinit var root: FrameLayout
    private lateinit var webView: LumenWebView
    private lateinit var backButton: ImageButton
    private lateinit var moreButton: ImageButton
    private lateinit var siteLabel: TextView
    private lateinit var dot: View
    private var fullscreenView: View? = null
    private var fullscreenCallback: WebChromeClient.CustomViewCallback? = null

    private val background = Executors.newSingleThreadExecutor()
    /** The uBO Lite copy this run uses, picked once so a download cannot mix versions; a newer one is used
     *  from the next start. */
    private var uBOCopy: UBOLite.Copy? = null
    private var adsSeen = 0
    private var playing = false
    private var mediaTitle = ""
    private var onScreen = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // chrome://inspect on the computer, for debug builds.
        if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) WebView.setWebContentsDebuggingEnabled(true)
        uBOCopy = UBOLite.newest(this)
        buildViews()
        setUpWebView(AdBlock.load(this))
        PlaybackService.controller = ::mediaCommand
        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                when {
                    fullscreenView != null -> exitFullscreen()
                    webView.canGoBack() -> webView.goBack()
                    // Leave Lumen without closing it, so music keeps playing.
                    else -> moveTaskToBack(true)
                }
            }
        })
        webView.loadUrl(HOME_URL)
    }

    // MARK: Views

    private fun dp(value: Int) = (value * resources.displayMetrics.density).roundToInt()

    private fun buildViews() {
        root = FrameLayout(this).apply { setBackgroundColor(Color.BLACK) }
        val column = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        webView = LumenWebView(this).apply { setBackgroundColor(Color.BLACK) }
        column.addView(webView, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))

        val bar = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply { cornerRadius = dp(24).toFloat(); setColor(0xFF1F2128.toInt()) }
        }
        backButton = iconButton(R.drawable.ic_back, "Back") { webView.goBack() }
        moreButton = iconButton(R.drawable.ic_more, "More") { showMenu() }
        siteLabel = TextView(this).apply {
            setTextColor(Color.WHITE)
            textSize = 15f
            gravity = Gravity.CENTER
            maxLines = 1
            ellipsize = TextUtils.TruncateAt.END
        }
        dot = View(this).apply {
            background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(0xFF22C55E.toInt()) }
            visibility = View.GONE
        }
        val more = FrameLayout(this).apply {
            addView(moreButton, FrameLayout.LayoutParams(dp(48), dp(48)))
            addView(dot, FrameLayout.LayoutParams(dp(8), dp(8), Gravity.TOP or Gravity.END).apply { setMargins(0, dp(10), dp(10), 0) })
        }
        bar.addView(backButton, LinearLayout.LayoutParams(dp(48), dp(48)))
        bar.addView(siteLabel, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
        bar.addView(more, LinearLayout.LayoutParams(dp(48), dp(48)))
        column.addView(bar, LinearLayout.LayoutParams(MATCH_PARENT, dp(48)).apply { setMargins(dp(16), dp(6), dp(16), dp(6)) })

        root.addView(column, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        setContentView(root)
        // Apps are edge to edge from Android 15: keep the page below the status bar and the bar above the
        // navigation bar and the keyboard.
        column.setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
            val ime = insets.getInsets(WindowInsets.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
            insets
        }
        updateBar()
    }

    private fun iconButton(icon: Int, label: String, action: () -> Unit) = ImageButton(this).apply {
        setImageResource(icon)
        contentDescription = label
        setBackgroundColor(Color.TRANSPARENT)
        setOnClickListener { action() }
    }

    private fun updateBar() {
        backButton.isEnabled = webView.canGoBack()
        backButton.alpha = if (backButton.isEnabled) 1f else 0.35f
        siteLabel.text = siteName(webView.url)
    }

    /** "youtube.com" for www.youtube.com and m.youtube.com. */
    private fun siteName(url: String?): String {
        var host = url?.let(AdBlock::hostOf) ?: return ""
        for (prefix in listOf("www.", "m.")) if (host.startsWith(prefix)) host = host.removePrefix(prefix)
        return host
    }

    private fun showMenu() {
        val popup = PopupMenu(this, moreButton)
        val menu = popup.menu
        menu.add(0, 1, 0, "Forward").isEnabled = webView.canGoForward()
        menu.add(0, 2, 1, "Reload")
        menu.add(0, 3, 2, "Home")
        menu.add(1, 4, 3, when (val status = UBOLiteUpdater.status(this, uBOCopy?.version)) {
            is UBOLiteUpdater.Status.Available -> "Update uBO (new: ${status.version})"
            is UBOLiteUpdater.Status.Downloaded -> "uBO ${status.version} ready: restart"
            UBOLiteUpdater.Status.Current -> "Check uBO (${uBOCopy?.version ?: "-"})"
        })
        menu.add(1, 5, 4, "Ads missed: $adsSeen").isEnabled = false
        popup.setOnMenuItemClickListener {
            when (it.itemId) {
                1 -> webView.goForward()
                2 -> webView.reload()
                3 -> webView.loadUrl(HOME_URL)
                4 -> updateUBlock()
            }
            true
        }
        popup.show()
    }

    // MARK: Web view

    @SuppressLint("SetJavaScriptEnabled")
    private fun setUpWebView(blocklist: AdBlock.Blocklist) {
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            mediaPlaybackRequiresUserGesture = false
            // Pop-ups the user did not tap (typical ad pop-unders) are dropped; tapped links open here.
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(false)
            // So Google sign-in sees Chrome: "; wv" and "Version/4.0" mark an embedded web view.
            userAgentString = userAgentString.replace("; wv", "").replace(Regex("Version/[\\d.]+ "), "")
        }
        // Logins are kept across restarts; Google sign-in needs third-party cookies.
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            setAcceptThirdPartyCookies(webView, true)
        }

        webView.webViewClient = object : WebViewClient() {
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
                if (blocklist.blocks(request.url.toString())) AdBlock.blockedResponse() else null

            // Stay in Lumen: links to other apps (intent://, YouTube's "open app" prompt) are ignored.
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest) =
                request.url.scheme !in setOf("http", "https")

            override fun doUpdateVisitedHistory(view: WebView, url: String?, isReload: Boolean) = updateBar()
        }
        // YouTube's service worker fetches outside the web view's own requests.
        ServiceWorkerController.getInstance().setServiceWorkerClient(object : ServiceWorkerClient() {
            override fun shouldInterceptRequest(request: WebResourceRequest): WebResourceResponse? =
                if (blocklist.blocks(request.url.toString())) AdBlock.blockedResponse() else null
        })
        webView.webChromeClient = object : WebChromeClient() {
            override fun onShowCustomView(view: View, callback: CustomViewCallback) = enterFullscreen(view, callback)
            override fun onHideCustomView() = exitFullscreen()
        }

        if (WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            WebViewCompat.addWebMessageListener(webView, "lumen", YOUTUBE) { _, message, _, isMainFrame, _ ->
                if (isMainFrame) handle(message.data)
            }
        }
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            uBOCopy?.let(AdBlock::uBOScripts).orEmpty().forEach { WebViewCompat.addDocumentStartJavaScript(webView, it, YOUTUBE) }
            WebViewCompat.addDocumentStartJavaScript(webView, AdBlock.pageScript, setOf("*"))
            WebViewCompat.addDocumentStartJavaScript(webView, AdBlock.backgroundPlayScript, YOUTUBE)
        }
    }

    private fun enterFullscreen(view: View, callback: WebChromeClient.CustomViewCallback) {
        if (fullscreenView != null) return callback.onCustomViewHidden()
        fullscreenView = view
        fullscreenCallback = callback
        root.addView(view, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
        window.insetsController?.apply {
            hide(WindowInsets.Type.systemBars())
            systemBarsBehavior = WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    private fun exitFullscreen() {
        val view = fullscreenView ?: return
        root.removeView(view)
        fullscreenView = null
        window.insetsController?.show(WindowInsets.Type.systemBars())
        fullscreenCallback?.onCustomViewHidden()
        fullscreenCallback = null
    }

    // MARK: Messages from the page

    private fun handle(data: String?) {
        val message = runCatching { JSONObject(data ?: return) }.getOrNull() ?: return
        when (message.optString("type")) {
            "ad-start" -> adsSeen++
            "skip-ad" -> tap(message.getDouble("x"), message.getDouble("y"),
                message.optDouble("scale", resources.displayMetrics.density.toDouble()))
            "media" -> mediaChanged(message.optBoolean("playing"), message.optString("title"))
        }
    }

    /** YouTube ignores script clicks on its skip button. A touch sent to the web view is a real one
     *  (isTrusted), like the real clicks on Windows and Mac. x and y are CSS pixels from the viewport. */
    private fun tap(x: Double, y: Double, scale: Double) {
        val px = (x * scale).toFloat()
        val py = (y * scale).toFloat()
        val down = SystemClock.uptimeMillis()
        for ((action, time) in listOf(MotionEvent.ACTION_DOWN to down, MotionEvent.ACTION_UP to down + 50)) {
            val event = MotionEvent.obtain(down, time, action, px, py, 0)
            event.source = InputDevice.SOURCE_TOUCHSCREEN
            webView.dispatchTouchEvent(event)
            event.recycle()
        }
    }

    // MARK: Background play

    private fun mediaChanged(isPlaying: Boolean, title: String) {
        playing = isPlaying
        if (title.isNotEmpty()) mediaTitle = title
        val service = PlaybackService.instance
        when {
            service != null -> service.show(playing, mediaTitle)
            // A foreground service may only be started while Lumen is on screen.
            playing && onScreen -> {
                askForNotifications()
                PlaybackService.start(this, mediaTitle)
            }
        }
    }

    /** "play" or "pause" from the notification or lock screen. pause() goes through the page's own
     *  pause(), so backgroundPlayScript respects it. */
    private fun mediaCommand(command: String) {
        val call = if (command == "play") "v.play().catch(() => {})" else "v.pause()"
        webView.evaluateJavascript(
            "(() => { const v = document.querySelector('#movie_player video') || document.querySelector('video'); if (v) $call; })()", null)
    }

    private fun askForNotifications() {
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1)
        }
    }

    override fun onResume() {
        super.onResume()
        onScreen = true
        webView.keepVisible = false
        webView.evaluateJavascript("window.__lumenLeavingUntil = 0;", null)
        if (!playing) PlaybackService.stop(this)
        checkForUBOUpdate()
    }

    /** Arms backgroundPlayScript while Lumen leaves the screen: from now, until 3 s after it is hidden. */
    override fun onPause() {
        super.onPause()
        onScreen = false
        webView.keepVisible = playing
        webView.evaluateJavascript(
            "(() => { const v = document.querySelector('video'); if (v && !v.paused && !v.ended) window.__lumenLeavingUntil = Number.MAX_SAFE_INTEGER; })()", null)
        CookieManager.getInstance().flush()
    }

    override fun onStop() {
        super.onStop()
        webView.evaluateJavascript("if (window.__lumenLeavingUntil) window.__lumenLeavingUntil = Date.now() + 3000;", null)
    }

    override fun onDestroy() {
        PlaybackService.controller = null
        PlaybackService.stop(this)
        background.shutdown()
        webView.destroy()
        super.onDestroy()
    }

    // MARK: uBO Lite update

    private fun checkForUBOUpdate() {
        refreshDot()
        background.execute { if (UBOLiteUpdater.checkIfDue(this)) runOnUiThread { refreshDot() } }
    }

    private fun refreshDot() {
        dot.visibility = if (UBOLiteUpdater.status(this, uBOCopy?.version) is UBOLiteUpdater.Status.Available) View.VISIBLE else View.GONE
    }

    /** Downloads a newer version if there is one, then offers to restart Lumen to use it. */
    private fun updateUBlock() {
        (UBOLiteUpdater.status(this, uBOCopy?.version) as? UBOLiteUpdater.Status.Downloaded)?.let { return offerRestart(it.version) }
        moreButton.isEnabled = false
        background.execute {
            val outcome = UBOLiteUpdater.update(this)
            runOnUiThread {
                moreButton.isEnabled = true
                refreshDot()
                when (outcome) {
                    is UBOLiteUpdater.Outcome.Downloaded -> offerRestart(outcome.version)
                    is UBOLiteUpdater.Outcome.UpToDate ->
                        // A version downloaded earlier is not in use until a restart.
                        if (outcome.version != uBOCopy?.version) offerRestart(outcome.version)
                        else alert("uBO is up to date", outcome.version)
                    is UBOLiteUpdater.Outcome.Failed -> alert("uBO update failed", outcome.message)
                }
            }
        }
    }

    private fun offerRestart(version: String) {
        AlertDialog.Builder(this)
            .setTitle("uBO $version downloaded")
            .setMessage("Restart Lumen to use it.")
            .setPositiveButton("Restart") { _, _ ->
                startActivity(Intent.makeRestartActivityTask(ComponentName(this, MainActivity::class.java)))
                Runtime.getRuntime().exit(0)
            }
            .setNegativeButton("Later", null)
            .show()
    }

    private fun alert(title: String, message: String) {
        AlertDialog.Builder(this).setTitle(title).setMessage(message).setPositiveButton("OK", null).show()
    }
}
