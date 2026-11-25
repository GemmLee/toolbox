package com.toolbox.app.linkparser

import android.app.Activity
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.Toast
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.UserAgentMetadata
import kotlin.math.roundToInt

/**
 * 网盘登录页：复用官方登录页，不逆向协议。
 *
 * 默认按**桌面端**加载（[EXTRA_DESKTOP]，默认 true）：
 * 多数网盘的移动版首页只有「下载 App」按钮、没有登录入口，桌面版才有账号密码 / 扫码登录。
 * 光改 UA 不够——WebView 默认发出的 client hints 里带着 "Android WebView" 品牌与 Android 平台，
 * 服务端会看到「UA 说自己是桌面 Chrome、client hints 却说是 WebView」的矛盾指纹，把页面降级成
 * 移动端落地页。所以这里同时用 [WebSettingsCompat.setUserAgentMetadata] 对齐 client hints
 * （WebView 不支持该特性时静默跳过），并在页面加载完成后把布局视口改成桌面宽度，
 * 让 WebView 按桌面版排版渲染再整体缩放到屏幕宽度。
 *
 * 用户扫码或密码登录完成后点「完成登录并提取凭证」，这里用 CookieManager 同步取 Cookie，
 * 再从 localStorage 里挑出 credentials_* / token / device_id 一类键，一并返回给 Flutter 侧保存。
 *
 * 明文存储是刻意选择：Keystore 密钥随系统升级失效会直接丢账号，
 * 这里只做「本机文件 + 用户可导出」的凭证管理。
 */
class WebViewLoginActivity : Activity() {

    private lateinit var webView: WebView
    private var currentUrl: String = ""
    private var cookieDomains: List<String> = emptyList()
    private var captured = false
    private var desktop = true

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val url = intent.getStringExtra(EXTRA_URL)
        if (url.isNullOrBlank()) {
            finish()
            return
        }
        desktop = intent.getBooleanExtra(EXTRA_DESKTOP, true)
        title = intent.getStringExtra(EXTRA_PLATFORM)?.takeIf { it.isNotBlank() }
            ?.let { "$it · 登录" } ?: "网盘登录"

        val progress = ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
            layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, dp(3))
            max = 100
        }
        webView = WebView(this).apply {
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, 0, 1f)
        }
        val finishButton = Button(this).apply {
            text = "完成登录并提取凭证"
            layoutParams = LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT)
        }

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            addView(progress)
            addView(webView)
            addView(finishButton)
        }
        setContentView(root)

        configureWebView()
        webView.webViewClient = object : WebViewClient() {
            override fun onPageFinished(view: WebView?, url: String?) {
                super.onPageFinished(view, url)
                if (!url.isNullOrBlank()) currentUrl = url
                progress.visibility = View.GONE
                // 桌面版页面是固定宽度布局：把视口改成桌面宽度后，WebView 会按
                // loadWithOverviewMode 整页缩放，否则右侧内容会被裁掉、找不到登录框。
                if (desktop) view?.evaluateJavascript(DESKTOP_VIEWPORT_JS, null)
            }

            override fun shouldOverrideUrlLoading(
                view: WebView?,
                request: WebResourceRequest?,
            ): Boolean = false
        }
        webView.webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                progress.progress = newProgress
                progress.visibility = if (newProgress >= 100) {
                    View.GONE
                } else {
                    View.VISIBLE
                }
            }
        }
        finishButton.setOnClickListener { captureAndFinish() }

        currentUrl = url
        cookieDomains = intent.getStringArrayListExtra(EXTRA_COOKIE_DOMAINS)?.toList().orEmpty()
        webView.loadUrl(url)
    }

    private fun dp(value: Int): Int = (value * resources.displayMetrics.density).roundToInt()

    private fun configureWebView() {
        CookieManager.getInstance().apply {
            setAcceptCookie(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                setAcceptThirdPartyCookies(webView, true)
            }
        }
        webView.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            loadWithOverviewMode = true
            useWideViewPort = true
            // 桌面版页面比屏幕宽，必须允许双指缩放 + 拖动，否则登录按钮可能落在可视区外。
            setSupportZoom(desktop)
            builtInZoomControls = desktop
            displayZoomControls = false
            if (desktop) {
                userAgentString = DESKTOP_UA
                alignClientHints(DESKTOP_UA)
            } else {
                userAgentString = "$userAgentString; XMtools"
            }
        }
    }

    /**
     * 把 WebView 的 client hints（`Sec-CH-UA` 系）对齐到刚设置的桌面 UA。
     *
     * 不同步就会出现「UA 是桌面 Chrome、client hints 是 Android WebView」的矛盾指纹，
     * 登录页背后的风控会据此判成非浏览器环境。特性不支持时静默跳过。
     */
    private fun alignClientHints(userAgent: String) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) return
        val major = Regex("Chrome/(\\d+)").find(userAgent)?.groupValues?.getOrNull(1) ?: "131"
        val full = "$major.0.0.0"
        val brands = listOf(
            Triple("Google Chrome", major, full),
            Triple("Chromium", major, full),
            Triple("Not_A Brand", "24", "24.0.0.0"),
        ).map { (brand, brandMajor, brandFull) ->
            UserAgentMetadata.BrandVersion.Builder()
                .setBrand(brand)
                .setMajorVersion(brandMajor)
                .setFullVersion(brandFull)
                .build()
        }
        val metadata = UserAgentMetadata.Builder()
            .setBrandVersionList(brands)
            .setFullVersion(full)
            .setPlatform("Windows")
            .setPlatformVersion("10.0.0")
            .setArchitecture("x86")
            .setModel("")
            .setMobile(false)
            .setBitness(64)
            .setWow64(false)
            .build()
        runCatching { WebSettingsCompat.setUserAgentMetadata(webView.settings, metadata) }
    }

    /**
     * Cookie 走 CookieManager 同步读取；localStorage 必须等 JS 回调，
     * 所以在回调里一起 setResult，避免拿到空串就返回。
     */
    private fun captureAndFinish() {
        if (captured) return
        captured = true
        val js = """
            (function () {
              var out = {};
              try {
                for (var i = 0; i < localStorage.length; i++) {
                  var k = localStorage.key(i);
                  if (/(credential|token|device|captcha|auth|session|user)/i.test(k)) {
                    out[k] = localStorage.getItem(k);
                  }
                }
              } catch (e) {}
              try { out.__documentCookie = document.cookie; } catch (e) {}
              return out;
            })()
        """.trimIndent()

        webView.evaluateJavascript(js) { value ->
            // 139 的登录态分布在 mail.10086.cn 与 yun.139.com，必须两个域都读；
            // 同一字段去重，避免重复 Cookie 头被服务端判坏。
            val cookies = runCatching {
                val domains = (cookieDomains + currentUrl).distinct()
                val seen = LinkedHashSet<String>()
                val joined = StringBuilder()
                for (domain in domains) {
                    val raw = CookieManager.getInstance().getCookie(domain).orEmpty()
                    for (pair in raw.split(";")) {
                        val kv = pair.trim()
                        if (kv.isEmpty()) continue
                        val key = kv.substringBefore("=")
                        if (seen.add(key)) {
                            if (joined.isNotEmpty()) joined.append("; ")
                            joined.append(kv)
                        }
                    }
                }
                joined.toString()
            }.getOrDefault("")
            val storage = value?.takeIf { it != "null" } ?: "{}"
            if (cookies.isNullOrBlank() && storage == "{}") {
                Toast.makeText(this, "还没检测到登录信息，请先完成登录", Toast.LENGTH_SHORT).show()
                captured = false
                return@evaluateJavascript
            }
            val data = Intent().apply {
                putExtra(EXTRA_COOKIES, cookies ?: "")
                putExtra(EXTRA_STORAGE, storage)
                putExtra(EXTRA_FINAL_URL, currentUrl)
            }
            setResult(RESULT_OK, data)
            finish()
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // 返回就是取消：不把半登录态写进凭证库。
        setResult(RESULT_CANCELED)
        super.onBackPressed()
    }

    override fun onDestroy() {
        runCatching {
            webView.destroy()
        }
        super.onDestroy()
    }

    companion object {
        const val EXTRA_URL = "url"
        const val EXTRA_PLATFORM = "platform"
        const val EXTRA_COOKIES = "cookies"
        const val EXTRA_STORAGE = "storage"
        const val EXTRA_FINAL_URL = "finalUrl"
        const val EXTRA_COOKIE_DOMAINS = "cookieDomains"
        const val EXTRA_DESKTOP = "desktop"

        /** 桌面 Chrome UA：版本号与 client hints 里的 Chrome 大版本必须一致。 */
        private const val DESKTOP_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        /**
         * 桌面布局视口：这类页面（Vue SPA）按布局宽度选变体，改成 1280 后
         * 会切到桌面双栏登录页，WebView 再整页缩放到屏幕宽度。
         */
        private const val DESKTOP_VIEWPORT_JS =
            "(function(){var c='width=1280,minimum-scale=0.2,maximum-scale=5.0,user-scalable=yes';" +
                "var m=document.querySelector('meta[name=\"viewport\"]');" +
                "if(m){m.setAttribute('content',c);}else{var n=document.createElement('meta');" +
                "n.name='viewport';n.content=c;document.head.appendChild(n);}" +
                "window.dispatchEvent(new Event('resize'));})()"
    }
}
