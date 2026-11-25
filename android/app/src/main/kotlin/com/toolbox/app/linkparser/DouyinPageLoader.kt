package com.toolbox.app.linkparser

import android.app.Activity
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.ViewGroup
import android.webkit.WebSettings
import android.webkit.WebView
import androidx.webkit.WebSettingsCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import androidx.webkit.UserAgentMetadata

/**
 * 抖音「隐藏 WebView」解析：让页面自己的 JS 跑起来，再把结果取回来。
 *
 * 为什么必须真跑一遍：分享页会 302 到 `www.douyin.com`，纯 HTTP 拿到的是
 * `byted_acrawler` 的挑战页（用 `__ac_nonce` 算出 `__ac_signature` 写回 Cookie 再
 * reload），页面里那几个详情接口又要 `a_bogus` 这类每次请求都变的签名。
 * 只有把页面放进 WebView 跑完挑战、再等它自己把详情请求发出去，才拿得到直链。
 *
 * 取数走三条路（与 YunX 一致，按优先级）：
 * 1. `window.__toolboxAwemeDetail`：文档开始前挂的 XHR 钩子存下的详情响应；
 * 2. `#RENDER_DATA` / `window.SSR_RENDER_DATA` 里的 `app.videoDetail`（图文与动图最全）；
 * 3. DOM 里的作品图（兜底，只有静态图）。
 *
 * WebView 以 1×1、全透明挂到当前 Activity 上：不挂窗口的话 requestAnimationFrame
 * 与 visibilityState 都不正常，挑战脚本容易卡住。
 */
class DouyinPageLoader(
    private val activity: Activity,
    private val url: String,
    private val callback: (String?) -> Unit,
) {

    private val handler = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private var finished = false
    private var extracted = false
    private var inFlight = false
    private var inFlightSince = 0L
    private val deadline = SystemClock.uptimeMillis() + TIMEOUT_MS

    fun start() {
        val view = WebView(activity)
        webView = view
        activity.addContentView(view, ViewGroup.LayoutParams(1, 1))
        view.alpha = 0f
        configure(view)
        view.loadUrl(url)
        handler.postDelayed(pollRunnable, FIRST_POLL_MS)
    }

    private fun configure(view: WebView) {
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            databaseEnabled = true
            userAgentString = DESKTOP_UA
            cacheMode = WebSettings.LOAD_DEFAULT
        }
        alignClientHints(view)
        // navigator.platform 也必须是 Win32：Android WebView 恒为 "Linux armv8l"，
        // 页面会把它序列化进请求参数，和服务端的桌面判定矛盾，详情就不直出了。
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            runCatching {
                WebViewCompat.addDocumentStartJavaScript(
                    view,
                    "(function(){try{Object.defineProperty(navigator,'platform'," +
                        "{get:function(){return 'Win32';},configurable:true});}catch(e){}})()",
                    setOf("*"),
                )
            }
            runCatching {
                WebViewCompat.addDocumentStartJavaScript(view, XHR_DETAIL_HOOK_JS, setOf("*"))
            }
        }
    }

    /** client hints 必须跟着 UA 改，否则「UA 说 Windows Chrome、hints 说 Android」会被风控降级。 */
    private fun alignClientHints(view: WebView) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.USER_AGENT_METADATA)) return
        val major = Regex("Chrome/(\\d+)").find(DESKTOP_UA)?.groupValues?.getOrNull(1) ?: "131"
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
        runCatching { WebSettingsCompat.setUserAgentMetadata(view.settings, metadata) }
    }

    private val pollRunnable = object : Runnable {
        override fun run() {
            if (finished) return
            val view = webView ?: return finish(null)
            val now = SystemClock.uptimeMillis()
            if (now > deadline) return finish(null)
            // 上一轮 evaluate 的回调可能永远不来（页面正在导航），超过 4 秒就允许重发。
            if (inFlight && now - inFlightSince < EVAL_TIMEOUT_MS) {
                handler.postDelayed(this, POLL_INTERVAL_MS)
                return
            }
            inFlight = true
            inFlightSince = now
            view.evaluateJavascript(READY_JS) { value ->
                inFlight = false
                if (finished) return@evaluateJavascript
                if (value != null && value.contains("true")) {
                    extract(view)
                } else {
                    handler.postDelayed(this, POLL_INTERVAL_MS)
                }
            }
        }
    }

    private fun extract(view: WebView) {
        if (extracted) return
        extracted = true
        // 取数脚本本身也可能卡住（页面正在跳转），加个硬超时兜底。
        handler.postDelayed({ if (!finished) finish(null) }, EVAL_TIMEOUT_MS)
        view.evaluateJavascript(EXTRACT_JS) { value ->
            if (finished) return@evaluateJavascript
            if (value == null || value == "null" || value.isEmpty()) {
                finish(null)
                return@evaluateJavascript
            }
            finish(value)
        }
    }

    private fun finish(payload: String?) {
        if (finished) return
        finished = true
        handler.removeCallbacksAndMessages(null)
        val view = webView
        webView = null
        if (view != null) {
            runCatching { view.stopLoading() }
            runCatching { (view.parent as? ViewGroup)?.removeView(view) }
            runCatching { view.destroy() }
        }
        callback(payload)
    }

    companion object {
        private const val TIMEOUT_MS = 40_000L
        private const val EVAL_TIMEOUT_MS = 4_000L
        private const val POLL_INTERVAL_MS = 350L
        private const val FIRST_POLL_MS = 600L

        private const val DESKTOP_UA =
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        /** 作品详情接口的响应原文存到全局变量；必须挂在文档开始前才抓得到。 */
        private const val XHR_DETAIL_HOOK_JS = """
(function () {
  try {
    if (window.__toolboxDetailHookInstalled) return;
    window.__toolboxDetailHookInstalled = true;
    var rawOpen = XMLHttpRequest.prototype.open;
    var rawSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      try { this.__toolboxUrl = String(url || ''); } catch (e) { this.__toolboxUrl = ''; }
      return rawOpen.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      var xhr = this;
      try {
        xhr.addEventListener('load', function () {
          try {
            var url = xhr.__toolboxUrl || '';
            if (url.indexOf('aweme/v1/web/aweme/detail') < 0) return;
            if (xhr.status !== 200) return;
            var text = '';
            try { text = xhr.responseText || ''; } catch (e) { text = ''; }
            if (!text) {
              try {
                var r = xhr.response;
                if (r) text = (typeof r === 'string') ? r : JSON.stringify(r);
              } catch (e) { text = ''; }
            }
            if (text) window.__toolboxAwemeDetail = text;
          } catch (e) {}
        });
      } catch (e) {}
      return rawSend.apply(this, arguments);
    };
  } catch (e) {}
})()
"""

        /**
         * 就绪判据：钩子拿到详情、或 DOM 里出现真正的作品图。
         *
         * 不能按链接类型分支：`/video/<id>` 会被抖音 302 到 `/note/<id>`，
         * 视频那条判据在图文页上永远不成立，只能干等到超时。
         */
        private const val READY_JS = """
(function () {
  var raw = window.__toolboxAwemeDetail;
  if (typeof raw === 'string' && raw.length > 0) return 'true';
  var imgs = document.querySelectorAll('img');
  for (var i = 0; i < imgs.length; i++) {
    if (isWorkImage(imgs[i].src || '')) return 'true';
  }
  return 'false';
  function isWorkImage(s) {
    if (!s || s.indexOf('douyinpic.com') < 0) return false;
    if (s.indexOf('WEBPC_RELATED') >= 0) return false;
    return s.indexOf('biz_tag=aweme_images') >= 0 || s.indexOf('tplv-dy-aweme-images') >= 0;
  }
})()
"""

        /** 取数：多条数据源都试，只回传必要字段（整份详情 100KB+，传回来又慢又不稳）。 */
        private const val EXTRACT_JS = """
(function () {
  try {
    function firstUrl(node) {
      if (!node) return '';
      var list = node.url_list || node.urlList || null;
      if (list && list.length) {
        // 有些图片项首项是空串占位，必须跳过，否则整张图被丢弃
        for (var k = 0; k < list.length; k++) {
          var candidate = String(list[k] || '');
          if (candidate) return candidate;
        }
      }
      return '';
    }

    function motionUrl(item) {
      if (!item) return '';
      var v = item.video;
      if (!v) return '';
      var direct = firstUrl(v.playAddr) || firstUrl(v.play_addr)
          || firstUrl(v.playApi) || firstUrl(v.play_addr_h264)
          || firstUrl(v.downloadAddr) || firstUrl(v.download_addr);
      if (direct) return direct;
      var list = v.playAddr || v.play_addr || null;
      if (list && list.length) {
        var first = list[0];
        if (first) return String(first.src || first.url || '');
      }
      return '';
    }

    function hookDetail() {
      var raw = window.__toolboxAwemeDetail || '';
      if (!raw) return null;
      try {
        var root = JSON.parse(raw);
        return root.aweme_detail || root.awemeDetail || (root.data && root.data.aweme_detail) || null;
      } catch (e) { return null; }
    }

    function readSsrDetail() {
      var node = document.querySelector('#RENDER_DATA');
      if (node && node.textContent) {
        try {
          var app = JSON.parse(decodeURIComponent(node.textContent)).app;
          if (app && app.videoDetail) return app.videoDetail;
        } catch (e) {}
      }
      try {
        var ssr = window.SSR_RENDER_DATA;
        if (ssr && ssr.app && ssr.app.videoDetail) return ssr.app.videoDetail;
      } catch (e) {}
      return null;
    }

    function imagesFrom(node) {
      if (!node || !node.length) return null;
      var list = [];
      var mlist = [];
      for (var i = 0; i < node.length; i++) {
        var item = node[i];
        var u = firstUrl(item)
            || firstUrl(item.download_url) || firstUrl(item.download_addr)
            || firstUrl(item.source_static_image) || firstUrl(item.user_watermark_image)
            || firstUrl(item.display_image) || firstUrl(item.owner_watermark_image)
            || firstUrl(item.thumbnail);
        if (!u) {
          // 终极兜底：从 uri 拼一个 CDN 地址（不是头像）
          var uri = item.uri || '';
          if (uri && uri.indexOf('avatar') < 0) {
            u = 'https://p3-sign.douyinpic.com/tos-cn-i-0813/' + uri + '~tplv-dy-aweme-images:q75.jpeg';
          }
        }
        if (u) {
          list.push(u);
          mlist.push(motionUrl(item));
        }
      }
      if (!list.length) return null;
      return { images: list, motions: mlist };
    }

    function domWorkImages() {
      var result = [];
      var all = document.querySelectorAll('img');
      for (var i = 0; i < all.length; i++) {
        var src = all[i].src || '';
        if (src.indexOf('douyinpic') < 0) continue;
        if (src.indexOf('WEBPC_RELATED') >= 0) continue;
        var isWork = src.indexOf('biz_tag=aweme_images') >= 0 || src.indexOf('tplv-dy-aweme-images') >= 0;
        if (isWork && result.indexOf(src) < 0) result.push(src);
      }
      return result;
    }

    var hooked = hookDetail();
    var ssr = readSsrDetail();

    var images = [];
    var motions = [];
    var src = '';
    // 图文作品常常出现「顶层 images 只有部分、image_post_info 才是全量」的情况，
    // 例如 3 张图 SSR / aweme_detail.images 只给 2 张。取图片数最多的一份，而不是先到先得。
    var candidates = [
      { node: ssr && ssr.images, src: 'ssr' },
      { node: ssr && ssr.image_post_info && (ssr.image_post_info.images || ssr.image_post_info.image_list), src: 'ssr' },
      { node: hooked && hooked.images, src: 'hook' },
      { node: hooked && hooked.image_post_info && (hooked.image_post_info.images || hooked.image_post_info.image_list), src: 'hook' }
    ];
    var best = null;
    var bestSrc = '';
    for (var i = 0; i < candidates.length; i++) {
      var p = imagesFrom(candidates[i].node);
      if (p && (!best || p.images.length > best.images.length)) {
        best = p;
        bestSrc = candidates[i].src;
      }
    }
    if (best) {
      images = best.images;
      motions = best.motions;
      src = bestSrc;
    } else {
      images = domWorkImages();
      src = images.length ? 'dom' : 'none';
    }

    var v = (hooked && hooked.video) || (ssr && ssr.video) || null;
    var video = '';
    if (v) {
      video = firstUrl(v.play_addr) || firstUrl(v.playAddr) || firstUrl(v.play_addr_h264);
      if (!video && v.bit_rate && v.bit_rate.length) {
        for (var i = 0; i < v.bit_rate.length; i++) {
          var candidate = firstUrl(v.bit_rate[i].play_addr);
          if (candidate) { video = candidate; break; }
        }
      }
      video = video.replace('/playwm/', '/play/');
    }

    var d = hooked || ssr;
    var author = '';
    if (d && d.author) author = d.author.nickname || d.author.unique_id || '';
    if (!author && d && d.authorInfo) author = d.authorInfo.nickname || d.authorInfo.nickName || '';

    var title = (d && d.desc) || '';
    if (!title) {
      var pageTitle = document.title || '';
      var tail = pageTitle.lastIndexOf(' - 抖音');
      if (tail > 0) pageTitle = pageTitle.substring(0, tail);
      title = pageTitle;
    }

    return {
      title: title,
      desc: (d && d.desc) || '',
      author: author,
      video: video,
      images: images,
      motions: motions,
      src: src,
      cover: (v && (firstUrl(v.cover) || firstUrl(v.origin_cover))) || ''
    };
  } catch (e) {
    return { error: 'js: ' + e };
  }
})()
"""
    }
}
