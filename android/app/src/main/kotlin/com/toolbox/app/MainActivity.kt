package com.toolbox.app

import android.Manifest
import android.app.ActivityManager
import android.content.ClipData
import android.content.ComponentName
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import android.webkit.MimeTypeMap
import android.webkit.WebView
import androidx.core.content.FileProvider
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.BatteryManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.StatFs
import android.os.SystemClock
import android.view.Choreographer
import android.view.WindowManager
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.toolbox.app.autoclick.AutoClickAccessibilityService
import com.toolbox.app.autoclick.AutoClickService
import com.toolbox.app.idphoto.IdPhotoProcessor
import com.toolbox.app.overlay.OverlayThemeStore
import com.toolbox.app.linkparser.DouyinPageLoader
import com.toolbox.app.linkparser.PublicDownloadExporter
import com.toolbox.app.linkparser.WebViewLoginActivity
import com.toolbox.app.quicksearch.PinyinInitials
import com.toolbox.app.quicksearch.QuickSearchService
import com.toolbox.app.smartsearch.SmartSearchAccessibilityService
import com.toolbox.app.smartsearch.SmartSearchService
import com.toolbox.app.watermark.WatermarkGeo
import android.content.pm.PackageManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.atomic.AtomicLong

/// Dart 的 int 过通道解码成 Kotlin Long / Double，直接 `argument<Int>` 会抛
/// `ClassCastException: Long cannot be cast to Integer`，统一按 Number 取。
private fun MethodCall.intArg(name: String, fallback: Int): Int {
    val args = arguments as? Map<*, *> ?: return fallback
    return (args[name] as? Number)?.toInt() ?: fallback
}

private fun MethodCall.doubleArg(name: String, fallback: Double): Double {
    val args = arguments as? Map<*, *> ?: return fallback
    return (args[name] as? Number)?.toDouble() ?: fallback
}

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "toolbox/device_status"
        private const val LIGHT_CHANNEL = "toolbox/sensors/light"
        private const val WAKE_CHANNEL = "toolbox/wake_lock"
        private const val IMPORT_CHANNEL = "toolbox/file_import"
        private const val SHARE_CHANNEL = "toolbox/file_share"
        private const val OCR_CHANNEL = "toolbox/ocr"
        private const val QUICK_SEARCH_CHANNEL = "toolbox/quick_search"
        private const val PINYIN_CHANNEL = "toolbox/pinyin"
        private const val SMART_SEARCH_CHANNEL = "toolbox/smart_search"
        private const val ID_PHOTO_CHANNEL = "toolbox/id_photo"
        private const val AUTO_CLICK_CHANNEL = "toolbox/auto_click"
        private const val LINK_CHANNEL = "toolbox/link_webview"
        private const val GEO_CHANNEL = "toolbox/watermark_geo"
        private const val REQ_LINK_LOGIN = 0x5A01
        private const val REQ_GEO_PERMISSION = 0x5A02
        private const val DOWNLOAD_SUBDIR = "XMtools"
        private const val TICK_SLOTS = 8
    }

    // FPS sampling: count frames on the UI thread, Dart computes deltas.
    private val frameCount = AtomicLong(0L)
    @Volatile private var lastFrameCount = 0L
    @Volatile private var lastSampleNanos = 0L

    // AI 题库转换：息屏后仍保持 CPU 运行，避免长任务被系统挂起。
    private var cpuWakeLock: PowerManager.WakeLock? = null

    // 外部 App「用其他应用打开 / 分享」的文件先复制到私有临时目录，
    // Dart 启动后经 channel 取走并归档到应用存储空间。
    private var importChannel: MethodChannel? = null
    private val pendingImports = mutableListOf<Map<String, Any>>()

    // 网盘登录页返回后要把 Cookie / localStorage 交回发起请求的 Dart 调用。
    private var pendingLoginResult: MethodChannel.Result? = null

    // OCR：中文 + 拉丁 bundled 模型随包安装，复用同一个识别器避免反复加载模型。
    private var ocrRecognizer: TextRecognizer? = null

    // 证件照：解码/推理/压缩都是重活，串行排队在单线程里跑，别占 UI 线程。
    private val idPhotoExecutor = java.util.concurrent.Executors.newSingleThreadExecutor()

    // 拍照水印定位：等待权限结果的 MethodChannel.Result。
    private var pendingGeoResult: MethodChannel.Result? = null
    private val watermarkGeo by lazy { WatermarkGeo(this) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 本轮打开 WebView 调试：chrome://inspect 可直接看网盘官方登录页与 Cookie。
        // 只影响 WebView 的远程调试开关，不写入任何账号数据。
        WebView.setWebContentsDebuggingEnabled(true)
        handleImportIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleImportIntent(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        startFrameCounter()
        importChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, IMPORT_CHANNEL)
        importChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "consumePending" -> {
                    val list = synchronized(pendingImports) {
                        val copy = ArrayList<Map<String, Any>>(pendingImports)
                        pendingImports.clear()
                        copy
                    }
                    result.success(list)
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "staticInfo" -> result.success(staticInfo())
                        "snapshot" -> result.success(snapshot())
                        "batteryDetail" -> result.success(batteryDetail())
                        "cpuDetail" -> result.success(cpuDetail())
                        "memoryDetail" -> result.success(memoryDetail())
                        "storageDetail" -> result.success(storageDetail())
                        "appStorage" -> result.success(appStorage())
                        "cacheItems" -> result.success(cacheItems())
                        "clearCacheItem" -> result.success(
                            clearCacheItem(call.argument<String>("key"))
                        )
                        "clearCache" -> result.success(clearAppCache())
                        "networkInfo" -> result.success(networkInfo())
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("DEVICE_STATUS_ERROR", e.message, null)
                }
            }
        // 拼音首字母：全局搜索的「首字母」口径，与便捷搜题共用同一份字符缓存。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PINYIN_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "initials" -> {
                        val texts = call.argument<List<String>>("texts") ?: emptyList()
                        // ICU 转换是 CPU 活，别占主线程；几千题一次几十毫秒。
                        Thread({
                            val out = ArrayList<String>(texts.size)
                            for (text in texts) out.add(PinyinInitials.initialsOf(text))
                            Handler(Looper.getMainLooper()).post {
                                result.success(
                                    mapOf(
                                        "supported" to PinyinInitials.supported,
                                        "initials" to out,
                                    )
                                )
                            }
                        }, "pinyin-initials").apply { isDaemon = true }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        // 转换期间常亮 / 息屏后保活：不引入第三方插件，直接操作窗口与 PowerManager。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKE_CHANNEL)
            .setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "setKeepScreenOn" -> {
                            val enabled = call.argument<Boolean>("enabled") == true
                            runOnUiThread {
                                if (enabled) {
                                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                } else {
                                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                                }
                            }
                            result.success(true)
                        }
                        "setCpuAwake" -> {
                            setCpuAwake(call.argument<Boolean>("enabled") == true)
                            result.success(true)
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("WAKE_LOCK_ERROR", e.message, null)
                }
            }
        // 存储空间：分享给微信 / QQ 等，或导出到系统「下载」目录。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SHARE_CHANNEL)
            .setMethodCallHandler { call, result ->
                val paths = call.argument<List<String>>("paths").orEmpty()
                try {
                    when (call.method) {
                        "share" -> {
                            val ok = shareFiles(paths, call.argument<String>("subject"))
                            result.success(ok)
                        }
                        "export" -> result.success(exportToDownloads(paths))
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) {
                    result.error("FILE_SHARE_ERROR", e.message, null)
                }
            }
        // OCR 文字识别：ML Kit 中文脚本识别器，模型已打包，离线可用。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OCR_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "recognize" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("OCR_BAD_ARG", "image path is required", null)
                            return@setMethodCallHandler
                        }
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("OCR_NO_FILE", "image file not found", null)
                            return@setMethodCallHandler
                        }
                        try {
                            // fromFilePath 会按 EXIF 纠正旋转，拍照图片不会躺倒。
                            val image = InputImage.fromFilePath(this, Uri.fromFile(file))
                            textRecognizer().process(image)
                                .addOnSuccessListener { visionText ->
                                    val lines = ArrayList<Map<String, Any>>()
                                    for (block in visionText.textBlocks) {
                                        for (line in block.lines) {
                                            val box = line.boundingBox
                                            lines.add(
                                                mapOf(
                                                    "text" to line.text,
                                                    "left" to (box?.left ?: 0),
                                                    "top" to (box?.top ?: 0),
                                                    "width" to (box?.width() ?: 0),
                                                    "height" to (box?.height() ?: 0)
                                                )
                                            )
                                        }
                                    }
                                    result.success(
                                        mapOf<String, Any>(
                                            "text" to visionText.text,
                                            "lines" to lines
                                        )
                                    )
                                }
                                .addOnFailureListener { e ->
                                    result.error("OCR_FAILED", e.message, null)
                                }
                        } catch (e: Exception) {
                            result.error("OCR_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 证件照：人脸校验 + 抠图合成 + 相册导出。
        val idPhotoChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, ID_PHOTO_CHANNEL
        )
        idPhotoChannel.setMethodCallHandler { call, result ->
            when (call.method) {
                "detect" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("ID_PHOTO_BAD_ARG", "image path is required", null)
                        return@setMethodCallHandler
                    }
                    idPhotoExecutor.execute {
                        try {
                            val data = IdPhotoProcessor.detectFace(this, path)
                            Handler(Looper.getMainLooper()).post { result.success(data) }
                        } catch (e: Exception) {
                            val message = e.message ?: "face detection failed"
                            Handler(Looper.getMainLooper())
                                .post { result.error("ID_PHOTO_DETECT", message, null) }
                        }
                    }
                }
                "process" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrBlank()) {
                        result.error("ID_PHOTO_BAD_ARG", "image path is required", null)
                        return@setMethodCallHandler
                    }
                    val left = call.doubleArg("left", 0.0).toFloat()
                    val top = call.doubleArg("top", 0.0).toFloat()
                    val right = call.doubleArg("right", 0.0).toFloat()
                    val bottom = call.doubleArg("bottom", 0.0).toFloat()
                    val background = call.intArg("background", 0xFFFFFFFF.toInt())
                    val width = call.intArg("width", 295)
                    val height = call.intArg("height", 413)
                    val maxKb = call.intArg("maxKb", 0)
                    val edgeShrink = call.doubleArg("edgeShrink", 0.0).toFloat()
                    idPhotoExecutor.execute {
                        try {
                            val out = IdPhotoProcessor.process(
                                this, path, left, top, right, bottom,
                                background, width, height, maxKb, edgeShrink,
                            ) { stage, value ->
                                runOnUiThread {
                                    runCatching {
                                        idPhotoChannel.invokeMethod(
                                            "progress",
                                            mapOf("stage" to stage, "value" to value),
                                        )
                                    }
                                }
                            }
                            val payload = mapOf(
                                "path" to out.path,
                                "width" to out.width,
                                "height" to out.height,
                                "bytes" to out.bytes,
                            )
                            Handler(Looper.getMainLooper()).post { result.success(payload) }
                        } catch (e: Exception) {
                            val message = e.message ?: "process failed"
                            Handler(Looper.getMainLooper())
                                .post { result.error("ID_PHOTO_PROCESS", message, null) }
                        }
                    }
                }
                "recolor" -> {
                    val background = call.intArg("background", 0xFFFFFFFF.toInt())
                    val edgeShrink = call.doubleArg("edgeShrink", 0.0).toFloat()
                    val maxKb = call.intArg("maxKb", 0)
                    idPhotoExecutor.execute {
                        try {
                            val out = IdPhotoProcessor.recolor(
                                this, background, edgeShrink, maxKb,
                            )
                            val payload = out?.let {
                                mapOf(
                                    "path" to it.path,
                                    "width" to it.width,
                                    "height" to it.height,
                                    "bytes" to it.bytes,
                                )
                            }
                            Handler(Looper.getMainLooper()).post { result.success(payload) }
                        } catch (e: Exception) {
                            val message = e.message ?: "recolor failed"
                            Handler(Looper.getMainLooper())
                                .post { result.error("ID_PHOTO_RECOLOR", message, null) }
                        }
                    }
                }
                "saveToGallery" -> {
                    val path = call.argument<String>("path")
                    val name = call.argument<String>("name") ?: "idphoto.jpg"
                    if (path.isNullOrBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    idPhotoExecutor.execute {
                        val ok = IdPhotoProcessor.saveToGallery(this, path, name)
                        Handler(Looper.getMainLooper()).post { result.success(ok) }
                    }
                }
                else -> result.notImplemented()
            }
        }
        // 便捷搜题：悬浮窗权限、启停与状态查询。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, QUICK_SEARCH_CHANNEL)            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canDraw" -> result.success(canDrawOverlays())
                    "requestPermission" -> result.success(openOverlaySettings())
                    "show" -> {
                        val indexPath = call.argument<String>("indexPath")
                        if (indexPath.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        // 空值 / 空表 = 全部题库；页面里换了题库会再调一次 show，Service 只换范围。
                        val bankIds = call.argument<List<String>>("bankIds")?.toSet()
                        val maxResults = call.intArg("maxResults", 3)
                        if (!QuickSearchService.start(this, indexPath, bankIds, maxResults)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        // Service 是异步挂窗口的，部分国产 ROM 会在 addView 时直接抛异常。
                        // 稍等一拍再回真实状态，避免 UI 以为开启成功却没有悬浮窗。
                        Handler(Looper.getMainLooper()).postDelayed({
                            result.success(QuickSearchService.isShowing)
                        }, 300)
                    }
                    "hide" -> {
                        QuickSearchService.stop(this)
                        result.success(true)
                    }
                    "isShowing" -> result.success(QuickSearchService.isShowing)
                    "setTheme" -> {
                        QuickSearchService.applyTheme(this, call.argument<String>("theme") ?: "dark")
                        result.success(true)
                    }
                    "getTheme" -> result.success(OverlayThemeStore.read(this))
                    else -> result.notImplemented()
                }
            }
        // 智能搜题：悬浮窗 + 无障碍取字通道。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SMART_SEARCH_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canDraw" -> result.success(canDrawOverlays())
                    "requestPermission" -> result.success(openOverlaySettings())
                    "accessibilityEnabled" -> result.success(
                        accessibilityEnabled(
                            SmartSearchAccessibilityService::class.java
                        )
                    )
                    "openAccessibilitySettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "show" -> {
                        val indexPath = call.argument<String>("indexPath")
                        if (indexPath.isNullOrBlank()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        if (!SmartSearchService.start(
                                this,
                                indexPath,
                                call.intArg("maxResults", 3),
                            )
                        ) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        Handler(Looper.getMainLooper()).postDelayed({
                            result.success(SmartSearchService.isShowing)
                        }, 300)
                    }
                    "hide" -> {
                        SmartSearchService.stop(this)
                        result.success(true)
                    }
                    "isShowing" -> result.success(SmartSearchService.isShowing)
                    "setTheme" -> {
                        SmartSearchService.applyTheme(this, call.argument<String>("theme") ?: "dark")
                        result.success(true)
                    }
                    "getTheme" -> result.success(OverlayThemeStore.read(this))
                    else -> result.notImplemented()
                }
            }
        // 自动点击：权限引导 + 把动作序列下发给悬浮控制面板。
        val autoClickChannel =
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, AUTO_CLICK_CHANNEL)
        // 面板「取点」要主动回调 Flutter，所以通道实例交给 Service 复用。
        AutoClickService.channel = autoClickChannel
        autoClickChannel
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "canDraw" -> result.success(canDrawOverlays())
                    "requestPermission" -> result.success(openOverlaySettings())
                    "accessibilityEnabled" -> result.success(
                        accessibilityEnabled(AutoClickAccessibilityService::class.java)
                    )
                    "openAccessibilitySettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "start" -> {
                        val args = LinkedHashMap<String, Any?>()
                        (call.arguments as? Map<*, *>)?.forEach { (key, value) ->
                            if (key is String) args[key] = value
                        }
                        result.success(AutoClickService.start(this, args))
                    }
                    "update" -> {
                        val args = LinkedHashMap<String, Any?>()
                        (call.arguments as? Map<*, *>)?.forEach { (key, value) ->
                            if (key is String) args[key] = value
                        }
                        result.success(AutoClickService.update(args))
                    }
                    "stop" -> {
                        AutoClickService.stop(this)
                        result.success(true)
                    }
                    "isRunning" -> result.success(AutoClickService.isShowing)
                    else -> result.notImplemented()
                }
            }
        // 链接解析：拉起网盘官方登录 WebView，把 Cookie / localStorage 交回 Dart。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINK_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "openLogin" -> {
                        val url = call.argument<String>("url")
                        if (url.isNullOrBlank()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        pendingLoginResult = result
                        val intent = Intent(this, WebViewLoginActivity::class.java).apply {
                            putExtra(WebViewLoginActivity.EXTRA_URL, url)
                            putExtra(
                                WebViewLoginActivity.EXTRA_PLATFORM,
                                call.argument<String>("platform") ?: "",
                            )
                            val domains =
                                (call.argument<Any>("cookieDomains") as? List<*>)
                                    ?.mapNotNull { it as? String }
                                    .orEmpty()
                            putStringArrayListExtra(
                                WebViewLoginActivity.EXTRA_COOKIE_DOMAINS,
                                ArrayList(domains),
                            )
                            // 默认桌面端网页：移动版网盘首页往往只有「下载 App」没有登录入口。
                            putExtra(
                                WebViewLoginActivity.EXTRA_DESKTOP,
                                call.argument<Boolean>("desktop") ?: true,
                            )
                        }
                        startActivityForResult(intent, REQ_LINK_LOGIN)
                    }
                    // 抖音解析：隐藏 WebView 跑完页面风控后把作品数据交回 Dart。
                    // 纯 HTTP 拿不到——分享页是 acrawler 挑战页，详情接口又要 a_bogus 签名。
                    "douyinParse" -> {
                        val id = call.argument<String>("id").orEmpty()
                        if (id.isBlank()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val kind =
                            if (call.argument<String>("kind") == "note") "note" else "video"
                        val url = "https://www.douyin.com/$kind/$id"
                        runOnUiThread {
                            DouyinPageLoader(this, url) { payload ->
                                result.success(payload)
                            }.start()
                        }
                    }
                    // 把成品文件导出到系统下载目录（MediaStore，不需要重权限）。
                    "exportDownload" -> {
                        val path = call.argument<String>("path").orEmpty()
                        val dir = call.argument<String>("relativeDir").orEmpty()
                        val name = call.argument<String>("name").orEmpty()
                        if (path.isBlank()) {
                            result.error("bad_args", "缺少文件路径", null)
                            return@setMethodCallHandler
                        }
                        // 复制几百 MB 文件不能占主线程，Dart 侧在等这个回调。
                        Thread {
                            try {
                                val saved = PublicDownloadExporter.export(
                                    applicationContext,
                                    path,
                                    dir,
                                    name,
                                )
                                runOnUiThread { result.success(saved) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error(
                                        "export_failed",
                                        e.message ?: "导出到下载目录失败",
                                        null,
                                    )
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
        // 拍照水印：一次性定位（经纬度/海拔），需要时申请定位权限。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, GEO_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(watermarkGeo.hasPermission())
                    "getLocation" -> {
                        if (!watermarkGeo.hasPermission()) {
                            pendingGeoResult = result
                            ActivityCompat.requestPermissions(
                                this,
                                arrayOf(
                                    Manifest.permission.ACCESS_FINE_LOCATION,
                                    Manifest.permission.ACCESS_COARSE_LOCATION,
                                ),
                                REQ_GEO_PERMISSION,
                            )
                        } else {
                            deliverGeo(result)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, LIGHT_CHANNEL)
            .setStreamHandler(object : EventChannel.StreamHandler {
                private var sensorManager: SensorManager? = null
                private var listener: SensorEventListener? = null

                override fun onListen(args: Any?, events: EventChannel.EventSink?) {
                    val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
                    val sensor = sm.getDefaultSensor(Sensor.TYPE_LIGHT)
                    if (sensor == null) {
                        events?.error("no_sensor", "此设备没有环境光传感器", null)
                        return
                    }
                    val l = object : SensorEventListener {
                        override fun onSensorChanged(event: SensorEvent) {
                            if (event.sensor.type == Sensor.TYPE_LIGHT && event.values.isNotEmpty()) {
                                events?.success(event.values[0].toDouble())
                            }
                        }

                        override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {}
                    }
                    listener = l
                    sensorManager = sm
                    // SENSOR_DELAY_UI 约 60ms 一帧，足够读数用且省电。
                    sm.registerListener(l, sensor, SensorManager.SENSOR_DELAY_UI)
                }

                override fun onCancel(args: Any?) {
                    listener?.let { sensorManager?.unregisterListener(it) }
                    listener = null
                    sensorManager = null
                }
            })
    }

    /// 取一次定位并回传给 Dart：允许后台线程等待，完成后切回方法通道线程回传。
    private fun deliverGeo(result: MethodChannel.Result) {
        watermarkGeo.requestOnce(8000L) { geo ->
            val payload = if (geo == null) {
                null
            } else {
                mapOf(
                    "latitude" to geo.latitude,
                    "longitude" to geo.longitude,
                    "altitude" to geo.altitude,
                )
            }
            result.success(payload)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQ_GEO_PERMISSION) {
            val pending = pendingGeoResult
            pendingGeoResult = null
            if (pending == null) return
            val granted = grantResults.any { it == PackageManager.PERMISSION_GRANTED }
            if (granted) deliverGeo(pending) else pending.success(null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_LINK_LOGIN) return
        val pending = pendingLoginResult ?: return
        pendingLoginResult = null
        if (resultCode != RESULT_OK || data == null) {
            pending.success(null)
            return
        }
        pending.success(
            mapOf(
                "cookies" to (data.getStringExtra(WebViewLoginActivity.EXTRA_COOKIES) ?: ""),
                "storage" to (data.getStringExtra(WebViewLoginActivity.EXTRA_STORAGE) ?: "{}"),
                "url" to (data.getStringExtra(WebViewLoginActivity.EXTRA_FINAL_URL) ?: ""),
            ),
        )
    }

    /**
     * 指定的无障碍服务是否已开启。
     *
     * 用户可能刚在设置里打开、服务还没连上，所以「已连接」也算开启；
     * 已开启列表是 `packageName/服务类名` 冒号分隔的字符串。
     */
    private fun accessibilityEnabled(service: Class<*>): Boolean {
        if (service == SmartSearchAccessibilityService::class.java &&
            SmartSearchAccessibilityService.isConnected
        ) return true
        if (service == AutoClickAccessibilityService::class.java &&
            AutoClickAccessibilityService.isConnected
        ) return true
        return try {
            val expected = ComponentName(this, service).flattenToString()
            val enabled = Settings.Secure.getString(
                contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
            ) ?: return false
            enabled.split(':').any { it.equals(expected, ignoreCase = true) }
        } catch (_: Exception) {
            false
        }
    }

    /** 悬浮窗权限：便捷搜题 / 智能搜题两个通道共用。 */
    private fun canDrawOverlays(): Boolean = Settings.canDrawOverlays(this)

    /** 跳到「显示在其他应用上层」设置页；个别 ROM 没有这个页面，返回 false 交给 UI 降级。 */
    private fun openOverlaySettings(): Boolean = try {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName")
        )
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
        true
    } catch (_: Exception) {
        false
    }

    /** 复用中文 + 拉丁文字识别器，模型从 APK assets 加载，不联网下载。 */    private fun textRecognizer(): TextRecognizer {
        ocrRecognizer?.let { return it }
        val created = TextRecognition.getClient(
            ChineseTextRecognizerOptions.Builder().build()
        )
        ocrRecognizer = created
        return created
    }

    /** 息屏后仍保持 CPU 运行：AI 题库转换这类长网络任务不会被立刻挂起。 */
    private fun setCpuAwake(enable: Boolean) {
        try {
            if (enable) {
                if (cpuWakeLock == null) {
                    val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
                    cpuWakeLock = pm.newWakeLock(
                        PowerManager.PARTIAL_WAKE_LOCK, "toolbox:quiz_ai_convert"
                    ).apply { setReferenceCounted(false) }
                }
                // 单次最长 30 分钟，防止任务异常结束时永久持锁耗电。
                if (cpuWakeLock?.isHeld != true) cpuWakeLock?.acquire(30 * 60 * 1000L)
            } else {
                if (cpuWakeLock?.isHeld == true) cpuWakeLock?.release()
            }
        } catch (_: Exception) {
            // 权限/机型不支持时静默跳过，转换仍可在前台继续。
        }
    }

    /**
     * 处理第三方 App 的 VIEW / SEND intent：把 content:// 或 file:// 文件
     * 复制到私有目录，再通知 Dart 取走。复制在 onCreate 同步完成，因为
     * content URI 的临时读取授权只授予本次启动的 Activity。
     */
    private fun handleImportIntent(intent: Intent?) {
        val source = intent ?: return
        val action = source.action
        if (action != Intent.ACTION_VIEW &&
            action != Intent.ACTION_SEND &&
            action != Intent.ACTION_SEND_MULTIPLE
        ) return
        val uris = mutableListOf<Uri>()
        if (action == Intent.ACTION_VIEW) source.data?.let { uris.add(it) }
        when (val stream = source.extras?.get(Intent.EXTRA_STREAM)) {
            is Uri -> uris.add(stream)
            is String -> {
                runCatching { uris.add(Uri.parse(stream)) }
            }
            is List<*> -> uris.addAll(stream.filterIsInstance<Uri>())
        }
        // 部分 App 只把文件放在 clipData 里。
        val clip = source.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) {
                clip.getItemAt(i).uri?.let { uris.add(it) }
            }
        }
        val distinct = uris.distinct()
        if (distinct.isEmpty()) return
        val copied = distinct.mapNotNull { copyImportToPrivate(it, source.type) }
        if (copied.isEmpty()) return
        synchronized(pendingImports) { pendingImports.addAll(copied) }
        runOnUiThread {
            try {
                importChannel?.invokeMethod("onFilesImported", null)
            } catch (_: Exception) {
                // Dart 侧还没注册 handler：启动时 drain() 仍会取走队列。
            }
        }
    }

    private fun copyImportToPrivate(uri: Uri, mime: String?): Map<String, Any>? {
        return try {
            val name = displayNameOf(uri) ?: "import_${System.currentTimeMillis()}.txt"
            val safe = name.replace(Regex("""[\\/:*?"<>|\r\n]"""), "_")
                .take(120).ifEmpty { "import.txt" }
            val dir = File(filesDir, "imports").apply { mkdirs() }
            val target = File(dir, "${System.currentTimeMillis()}_${safe}")
            val input = if (uri.scheme.equals("file", ignoreCase = true)) {
                uri.path?.let { File(it).inputStream() }
            } else {
                contentResolver.openInputStream(uri)
            } ?: return null
            input.use { src -> target.outputStream().use { dst -> src.copyTo(dst) } }
            mapOf(
                "path" to target.absolutePath,
                "name" to safe,
                "mime" to (mime ?: ""),
                "size" to target.length(),
            )
        } catch (_: Exception) {
            null
        }
    }

    private fun displayNameOf(uri: Uri): String? = try {
        if (uri.scheme.equals("content", ignoreCase = true)) {
            contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0 && cursor.moveToFirst()) cursor.getString(idx) else null
            }
        } else {
            uri.lastPathSegment
        }
    } catch (_: Exception) {
        uri.lastPathSegment
    }

    /** 唤起系统分享面板（微信 / QQ / 邮件…），单文件与多文件都支持。 */
    private fun shareFiles(paths: List<String>, subject: String?): Boolean {
        val files = paths.map { File(it) }.filter { it.isFile }
        if (files.isEmpty()) return false
        val uris = files.map {
            FileProvider.getUriForFile(this, "$packageName.fileprovider", it)
        }
        val intent = if (uris.size == 1) {
            Intent(Intent.ACTION_SEND).apply {
                type = mimeOf(files.first().name)
                putExtra(Intent.EXTRA_STREAM, uris.first())
            }
        } else {
            val types = files.map { mimeOf(it.name) }.distinct()
            Intent(Intent.ACTION_SEND_MULTIPLE).apply {
                type = if (types.size == 1) types.first() else "*/*"
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
            }
        }
        // 少数接收方（含部分微信版本）只读 clipData 里的 URI。
        val clip = ClipData.newRawUri(null, uris.first())
        for (u in uris.drop(1)) clip.addItem(ClipData.Item(u))
        intent.clipData = clip
        intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        if (!subject.isNullOrBlank()) intent.putExtra(Intent.EXTRA_SUBJECT, subject)
        runOnUiThread {
            try {
                startActivity(Intent.createChooser(intent, "分享"))
            } catch (_: Exception) {
            }
        }
        return true
    }

    /**
     * 导出到系统「下载」目录的 XMtools 子目录，用户可在任意文件管理器里找到。
     * Android 10+ 走 MediaStore（免存储权限）；9 及以下写公共目录。
     */
    private fun exportToDownloads(paths: List<String>): Map<String, Any> {
        val files = paths.map { File(it) }.filter { it.isFile }
        if (files.isEmpty()) return mapOf("count" to 0, "failed" to 0,
            "dir" to "Download/$DOWNLOAD_SUBDIR")
        val used = HashSet<String>()
        var ok = 0
        var failed = 0
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val collection = MediaStore.Downloads.EXTERNAL_CONTENT_URI
            for (src in files) {
                val name = uniqueName(used, src.name)
                used.add(name)
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, name)
                    put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(name))
                    put(MediaStore.MediaColumns.RELATIVE_PATH,
                        "${Environment.DIRECTORY_DOWNLOADS}/$DOWNLOAD_SUBDIR")
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }
                try {
                    val uri = contentResolver.insert(collection, values)
                    if (uri == null) {
                        failed++
                        continue
                    }
                    contentResolver.openOutputStream(uri).use { out ->
                        if (out == null) throw IllegalStateException("无法写入")
                        src.inputStream().use { it.copyTo(out) }
                    }
                    values.clear()
                    values.put(MediaStore.MediaColumns.IS_PENDING, 0)
                    contentResolver.update(uri, values, null, null)
                    ok++
                } catch (_: Exception) {
                    failed++
                }
            }
        } else {
            val dir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                DOWNLOAD_SUBDIR,
            )
            if (!dir.exists() && !dir.mkdirs()) {
                return mapOf("count" to 0, "failed" to files.size,
                    "dir" to "Download/$DOWNLOAD_SUBDIR")
            }
            for (src in files) {
                val name = uniqueName(used, src.name)
                used.add(name)
                try {
                    src.copyTo(File(dir, name), overwrite = false)
                    ok++
                } catch (_: Exception) {
                    failed++
                }
            }
        }
        return mapOf(
            "count" to ok,
            "failed" to failed,
            "dir" to "Download/$DOWNLOAD_SUBDIR",
        )
    }

    private fun uniqueName(used: MutableSet<String>, raw: String): String {
        val safe = raw.replace(Regex("""[\\/:*?"<>|\r\n]"""), "_").ifEmpty { "file" }
        if (safe !in used) return safe
        val dot = safe.lastIndexOf('.')
        val stem = if (dot > 0) safe.substring(0, dot) else safe
        val ext = if (dot > 0) safe.substring(dot) else ""
        var i = 2
        while ("$stem($i)$ext" in used) i++
        return "$stem($i)$ext"
    }

    private fun mimeOf(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when (ext) {
            "json" -> "application/json"
            "md", "markdown" -> "text/markdown"
            "txt", "csv", "tsv", "log", "yml", "yaml" -> "text/plain"
            "png" -> "image/png"
            "jpg", "jpeg" -> "image/jpeg"
            "webp" -> "image/webp"
            "gif" -> "image/gif"
            "pdf" -> "application/pdf"
            "zip" -> "application/zip"
            else -> MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        }
    }

    override fun onDestroy() {
        try {
            if (cpuWakeLock?.isHeld == true) cpuWakeLock?.release()
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            ocrRecognizer?.close()
            ocrRecognizer = null
            idPhotoExecutor.shutdownNow()
        } catch (_: Exception) {
        }
        super.onDestroy()
    }

    /** IP 诊断：当前活动网络的系统侧属性（接口、网关、DNS、带宽估计）。 */
    @Suppress("MissingPermission")
    private fun networkInfo(): Map<String, Any> {
        val out = HashMap<String, Any>()
        // 任何机型差异/隐藏 API 抛错都返回完整的「未知」结构，Dart 侧无需判空。
        out["type"] = "unknown"
        out["typeName"] = ""
        out["metered"] = false
        out["validated"] = false
        out["downstreamKbps"] = 0
        out["upstreamKbps"] = 0
        out["dns"] = emptyList<String>()
        out["gateway"] = ""
        out["localAddresses"] = emptyList<String>()
        out["interfaceNames"] = emptyList<String>()
        try {
            val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network = cm.activeNetwork
            val caps = if (network != null) cm.getNetworkCapabilities(network) else null
            val link = if (network != null) cm.getLinkProperties(network) else null
            out["type"] = when {
                network == null || caps == null -> "none"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN) -> "vpn"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
                else -> "unknown"
            }
            out["typeName"] = out["type"].toString().uppercase()
            out["metered"] = caps?.let {
                !it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
            } ?: false
            out["validated"] =
                caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true
            out["downstreamKbps"] = caps?.linkDownstreamBandwidthKbps ?: 0
            out["upstreamKbps"] = caps?.linkUpstreamBandwidthKbps ?: 0
            out["dns"] = try {
                link?.dnsServers?.mapNotNull { it.hostAddress } ?: emptyList()
            } catch (_: Exception) {
                emptyList<String>()
            }
            out["gateway"] = try {
                link?.routes?.firstOrNull { it.isDefaultRoute }?.gateway?.hostAddress ?: ""
            } catch (_: Exception) {
                ""
            }
            out["localAddresses"] = try {
                link?.linkAddresses?.mapNotNull { it.address?.hostAddress } ?: emptyList()
            } catch (_: Exception) {
                emptyList<String>()
            }
            out["interfaceNames"] = listOfNotNull(link?.interfaceName)
        } catch (_: Exception) {
            // 保留上面的未知值
        }
        return out
    }

    private fun startFrameCounter() {
        Choreographer.getInstance().postFrameCallback(object : Choreographer.FrameCallback {
            override fun doFrame(frameTimeNanos: Long) {
                frameCount.incrementAndGet()
                Choreographer.getInstance().postFrameCallback(this)
            }
        })
    }

    private fun staticInfo(): Map<String, Any> {
        val map = HashMap<String, Any>()
        map["model"] = Build.MODEL ?: ""
        map["manufacturer"] = Build.MANUFACTURER ?: ""
        map["brand"] = Build.BRAND ?: ""
        map["device"] = Build.DEVICE ?: ""
        map["product"] = Build.PRODUCT ?: ""
        map["hardware"] = Build.HARDWARE ?: ""
        map["board"] = Build.BOARD ?: ""
        map["sdkInt"] = Build.VERSION.SDK_INT
        map["release"] = Build.VERSION.RELEASE ?: ""
        map["kernel"] = readText("/proc/version")?.lineSequence()?.firstOrNull() ?: ""
        map["uptimeMs"] = System.currentTimeMillis() - SystemClock.elapsedRealtime()
        map["refreshRate"] = readRefreshRate()
        return map
    }

    @Suppress("DEPRECATION")
    private fun readRefreshRate(): Double {
        return try {
            val wm = getSystemService(Context.WINDOW_SERVICE) as WindowManager
            wm.defaultDisplay.refreshRate.toDouble()
        } catch (e: Exception) {
            60.0
        }
    }

    private fun snapshot(): Map<String, Any> {
        val map = HashMap<String, Any>()

        // RAM
        val am = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val mem = ActivityManager.MemoryInfo()
        am.getMemoryInfo(mem)
        map["ramTotal"] = mem.totalMem
        map["ramAvail"] = mem.availMem

        // swap (zram included) from /proc/meminfo
        val meminfo = readText("/proc/meminfo") ?: ""
        map["swapTotal"] = parseMeminfoKb(meminfo, "SwapTotal") * 1024L
        map["swapFree"] = parseMeminfoKb(meminfo, "SwapFree") * 1024L

        // data storage
        val stat = StatFs(Environment.getDataDirectory().path)
        map["storageTotal"] = stat.totalBytes
        map["storageFree"] = stat.availableBytes

        // battery
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (intent != null) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            map["batteryLevel"] = if (level >= 0 && scale > 0) level * 100.0 / scale else -1.0
            map["batteryTemp"] = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) / 10.0
            map["batteryVoltageMv"] = intent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)
            map["batteryStatus"] = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            map["batteryPlugged"] = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            map["batteryHealth"] = intent.getIntExtra(BatteryManager.EXTRA_HEALTH, -1)
        }
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        map["batteryCurrentUa"] = normalizeMicroAmps(
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        )
        map["cpuTemp"] = cpuThermalTemp()

        // per-core cpu: current/min/max freq + /proc/stat ticks (Dart computes usage deltas)
        val coreCount = Runtime.getRuntime().availableProcessors()
        val procStat = readText("/proc/stat") ?: ""
        val statLines = procStat.split('\n')
        val cores = mutableListOf<Map<String, Any>>()
        for (i in 0 until coreCount) {
            val core = HashMap<String, Any>()
            core["index"] = i
            core["curFreq"] = readLong("/sys/devices/system/cpu/cpu$i/cpufreq/scaling_cur_freq")
            core["minFreq"] = readLong("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_min_freq")
            core["maxFreq"] = readLong("/sys/devices/system/cpu/cpu$i/cpufreq/cpuinfo_max_freq")
            core["ticks"] = parseCpuTicks(statLines, i)
            cores.add(core)
        }
        map["cores"] = cores

        // fps delta since previous snapshot
        val now = System.nanoTime()
        val frames = frameCount.get() - lastFrameCount
        val elapsedMs = if (lastSampleNanos == 0L) 0L else (now - lastSampleNanos) / 1_000_000L
        lastFrameCount = frameCount.get()
        lastSampleNanos = now
        map["framesDelta"] = frames
        map["framesElapsedMs"] = elapsedMs
        return map
    }

    /** 电池详情：技术/健康/容量估算/循环次数等。 */
    private fun batteryDetail(): Map<String, Any> {
        val map = HashMap<String, Any>()
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        if (intent != null) {
            val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
            val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
            map["level"] = if (level >= 0 && scale > 0) level * 100.0 / scale else -1.0
            map["temperature"] = intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE) / 10.0
            map["voltageMv"] = intent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1)
            map["status"] = intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)
            map["plugged"] = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0)
            map["health"] = intent.getIntExtra(BatteryManager.EXTRA_HEALTH, -1)
            map["technology"] = intent.getStringExtra(BatteryManager.EXTRA_TECHNOLOGY) ?: ""
        }
        val bm = getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        val chargeCounter = normalizeChargeUah(
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER)
        )
        map["capacityPercent"] = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY).toLong()
        map["currentNowUa"] = normalizeMicroAmps(
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
        )
        map["currentAvgUa"] = normalizeMicroAmps(
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_AVERAGE)
        )
        // 容量类数据走 sysfs：pms 通常在 /sys/class/power_supply/battery，
        // 但不少机型叫 bms / Battery / max170xx_battery 等，目录本身无需 root
        // 即可枚举，逐个节点找第一个有值的文件。
        val sysfsCounter = readBatteryUah("charge_now", "charge_counter")
        map["chargeCounterUah"] = if (chargeCounter > 0) chargeCounter else sysfsCounter
        map["chargeFullUah"] = readBatteryUah("charge_full", "charge_full_batt")
        map["chargeFullDesignUah"] = designCapacityUah()
        map["cycleCount"] = readFirstLong("cycle_count", "battery_cycle", "cycle")
        // 充电协议/功率：厂商节点名各不相同，全部是纯文本，读不到留空。
        map["chargeType"] = readBatteryText(
            "charge_type", "quick_charge_type", "usb_type", "real_type", "charge_protocol",
        )
        map["powerNowMw"] = readFirstLong("power_now") / 1000L
        map["energyCounterNwh"] = try {
            bm.getLongProperty(BatteryManager.BATTERY_PROPERTY_ENERGY_COUNTER)
        } catch (e: Exception) {
            0L
        }
        return map
    }

    /** CPU 详情：每核频率/调速器/在线状态/可用频率档 + 温度传感器 + SoC 信息。 */
    private fun cpuDetail(): Map<String, Any> {
        val map = HashMap<String, Any>()
        val count = Runtime.getRuntime().availableProcessors()
        val cores = mutableListOf<Map<String, Any>>()
        for (i in 0 until count) {
            val base = "/sys/devices/system/cpu/cpu$i"
            val core = HashMap<String, Any>()
            core["index"] = i
            core["curFreq"] = readLong("$base/cpufreq/scaling_cur_freq")
            core["minFreq"] = readLong("$base/cpufreq/cpuinfo_min_freq")
            core["maxFreq"] = readLong("$base/cpufreq/cpuinfo_max_freq")
            core["governor"] = readText("$base/cpufreq/scaling_governor")?.trim() ?: ""
            // cpu0 通常不可下线，没有 online 节点
            core["online"] = if (i == 0) {
                true
            } else {
                (readText("$base/online")?.trim() ?: "1") == "1"
            }
            val freqs = readText("$base/cpufreq/scaling_available_frequencies")
                ?.trim()
                ?.split(Regex("\\s+"))
                ?.mapNotNull { it.toLongOrNull() }
                ?.filter { it > 0 }
                ?.sorted()
                ?: emptyList()
            core["freqs"] = freqs
            cores.add(core)
        }
        map["cores"] = cores
        map["thermal"] = thermalZones()
        map["abi"] = Build.SUPPORTED_ABIS.joinToString(", ")
        map["soc"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MODEL
        } else {
            Build.HARDWARE
        }
        map["socManufacturer"] = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            Build.SOC_MANUFACTURER
        } else {
            Build.MANUFACTURER
        }
        return map
    }

    /** 快照用：只取 CPU/SoC 相关温区的最高温，避免每秒扫全部温区。 */
    private fun cpuThermalTemp(): Double {
        var max = 0.0
        try {
            val zones = File("/sys/class/thermal").listFiles() ?: return 0.0
            for (zone in zones) {
                if (!zone.name.startsWith("thermal_zone")) continue
                val type = readText("${zone.absolutePath}/type")?.trim()?.lowercase() ?: ""
                if (type.isEmpty()) continue
                if (!(type.contains("cpu") || type.contains("soc") || type.contains("ap") ||
                        type.contains("gpu") || type.contains("tsens") || type.contains("board"))) {
                    continue
                }
                val raw = readLong("${zone.absolutePath}/temp")
                if (raw == 0L) continue
                val celsius = if (kotlin.math.abs(raw) > 1000) raw / 1000.0 else raw.toDouble()
                if (celsius in -40.0..150.0 && celsius > max) max = celsius
            }
        } catch (_: Exception) {
            // 温区不可读时返回 0
        }
        return max
    }

    /** 温度传感器：/sys/class/thermal/thermal_zone*(type, temp)，同名的只留最高温。 */
    private fun thermalZones(): List<Map<String, Any>> {        val byName = LinkedHashMap<String, Map<String, Any>>()
        try {
            File("/sys/class/thermal").listFiles()
                ?.sortedBy { it.name }
                ?.forEach { zone ->
                    if (!zone.name.startsWith("thermal_zone")) return@forEach
                    val raw = readLong("${zone.absolutePath}/temp")
                    if (raw == 0L) return@forEach
                    // 多数平台是毫摄氏度，个别老平台直接给摄氏度
                    val celsius = if (kotlin.math.abs(raw) > 1000) raw / 1000.0 else raw.toDouble()
                    if (celsius < -40.0 || celsius > 150.0) return@forEach
                    val name = readText("${zone.absolutePath}/type")?.trim()
                        ?.takeIf { it.isNotEmpty() } ?: zone.name
                    val item = HashMap<String, Any>()
                    item["name"] = name
                    item["temp"] = celsius
                    val old = byName[name]
                    val oldTemp = (old?.get("temp") as? Double) ?: -273.0
                    if (old == null || celsius > oldTemp) byName[name] = item
                }
        } catch (_: Exception) {
            // /sys/class/thermal 不可读时返回空列表
        }
        return byName.values.sortedByDescending { (it["temp"] as? Double) ?: 0.0 }
    }

    /** /sys/class/power_supply 下的候选节点目录（含常见别名，去重保序）。 */
    private val batteryNodes: List<String> by lazy {
        val dirs = mutableListOf<String>()
        for (name in listOf(
            "battery", "bms", "Battery", "max170xx_battery",
            "rt9426_battery", "bq27541-0", "bq27x00_battery",
        )) {
            dirs.add("/sys/class/power_supply/$name")
        }
        try {
            File("/sys/class/power_supply").listFiles()
                ?.sortedBy { it.name }
                ?.forEach { f ->
                    val path = f.absolutePath
                    if (!dirs.contains(path)) dirs.add(path)
                }
        } catch (_: Exception) {
            // 目录不可读时只用常见别名
        }
        return@lazy dirs
    }

    /** 在候选节点里读第一个大于 0 的整数值（如 cycle_count）。 */
    private fun readFirstLong(vararg names: String): Long {
        for (dir in batteryNodes) {
            for (name in names) {
                val value = readLong("$dir/$name")
                if (value > 0) return value
            }
        }
        return 0L
    }

    /** 在候选节点里读第一个非空文本值（如 charge_type）。 */
    private fun readBatteryText(vararg names: String): String {
        for (dir in batteryNodes) {
            for (name in names) {
                val value = readText("$dir/$name")?.trim()
                if (!value.isNullOrEmpty()) return value
            }
        }
        return ""
    }

    /**
     * 读取容量类 sysfs 值并归一化到 µAh。
     *
     * Linux power_supply 规范单位是 µAh，但个别机型按 mAh 暴露；
     * 判断依据是量级：手机电池不可能小于 100 mAh，因此 < 100000 的按 mAh 处理。
     */
    private fun readBatteryUah(vararg names: String): Long {
        val raw = readFirstLong(*names)
        if (raw <= 0) return 0L
        val uah = if (raw < 100_000L) raw * 1000L else raw
        // 合理上限 100 Ah，超出视为异常值丢弃。
        return if (uah in 1_000L..100_000_000L) uah else 0L
    }

    /**
     * 标称（设计）容量，多路径尝试，全部失败返回 0（UI 显示「系统未提供」）。
     *
     * 顺序：sysfs 节点 → PowerProfile 反射 → dumpsys 文本。
     * 与「爱玩机工具箱」同类做法：普通 App 无 root 时，厂商常把设计容量藏在这几处。
     * 所有路径都包在 try 里，任何机型 / Android 版本的限制都静默跳过。
     */
    private fun designCapacityUah(): Long {
        // 1) sysfs：除了标准 charge_full_design，补几家厂商的私有命名。
        val fromSysfs = readBatteryUah(
            "charge_full_design", "design_capacity", "design_capacity_uah",
            "battery_design_capacity", "charge_design",
        )
        if (fromSysfs > 0) return fromSysfs

        // 2) PowerProfile：com.android.internal.os.PowerProfile 的电池容量配置，
        //    多数机型无需 root 即可反射读取（单位 mAh）。
        val fromProfile = powerProfileCapacityUah()
        if (fromProfile > 0) return fromProfile

        // 3) dumpsys battery：部分厂商在文本里带 "Design Capacity: xxx mAh"。
        return dumpsysDesignCapacityUah()
    }

    /** 反射 PowerProfile 读标称容量；隐藏 API 各版本签名不同，逐个尝试。 */
    private fun powerProfileCapacityUah(): Long {
        try {
            val clazz = Class.forName("com.android.internal.os.PowerProfile")
            val instance = try {
                clazz.getDeclaredConstructor(Context::class.java).newInstance(this)
            } catch (_: Exception) {
                clazz.getDeclaredConstructor().newInstance()
            }
            // 新版：getBatteryCapacity() → double mAh
            try {
                val method = clazz.getDeclaredMethod("getBatteryCapacity")
                method.isAccessible = true
                val mah = (method.invoke(instance) as? Number)?.toDouble() ?: 0.0
                val uah = (mah * 1000).toLong()
                if (uah in 1_000L..100_000_000L) return uah
            } catch (_: Exception) {
                // 该版本无此方法，尝试下一种签名
            }
            // 旧版：getAveragePower("battery.capacity")
            try {
                val method = clazz.getDeclaredMethod(
                    "getAveragePower", String::class.java,
                )
                method.isAccessible = true
                val mah = (method.invoke(instance, "battery.capacity") as? Number)
                    ?.toDouble() ?: 0.0
                val uah = (mah * 1000).toLong()
                if (uah in 1_000L..100_000_000L) return uah
            } catch (_: Exception) {
                // 忽略
            }
        } catch (_: Exception) {
            // 反射被限制 / 类不存在，静默跳过
        }
        return 0L
    }

    /** 解析 dumpsys battery 文本里的设计容量（mAh）。 */
    private fun dumpsysDesignCapacityUah(): Long {
        val text = try {
            val process = Runtime.getRuntime().exec(arrayOf("dumpsys", "battery"))
            process.inputStream.bufferedReader().use { it.readText() }
        } catch (_: Exception) {
            return 0L
        }
        val regex = Regex(
            "(?i)(design\\s*capacity|charge_full_design|full\\s*charge\\s*capacity)\\s*[:=]?\\s*([0-9]+(?:\\.[0-9]+)?)\\s*m?Ah?",
        )
        for (line in text.lineSequence()) {
            val match = regex.find(line) ?: continue
            val mah = match.groupValues.getOrNull(2)?.toDoubleOrNull() ?: continue
            val uah = (mah * 1000).toLong()
            if (uah in 1_000L..100_000_000L) return uah
        }
        return 0L
    }

    /** 内存详情：/proc/meminfo 关键行（单位 KB -> 字节）。 */
    private fun memoryDetail(): Map<String, Any> {
        val text = readText("/proc/meminfo") ?: return HashMap()
        val keys = listOf(
            "MemTotal", "MemFree", "MemAvailable", "Buffers", "Cached",
            "SwapTotal", "SwapFree", "SwapCached", "Slab", "SReclaimable", "Shmem",
        )
        val map = HashMap<String, Any>()
        for (key in keys) {
            map[key] = parseMeminfoKb(text, key) * 1024L
        }
        map["zramDisksize"] = readLong("/sys/block/zram0/disksize") / 1024L
        map["zramUsed"] = parseZramMmStat()[1]
        return map
    }

    /** /sys/block/zram0/mm_stat: orig_data_size compr_data_size mem_used_total ... */
    private fun parseZramMmStat(): List<Long> {
        val text = readText("/sys/block/zram0/mm_stat") ?: return listOf(0L, 0L, 0L)
        val parts = text.trim().split(Regex("\\s+"))
        return listOf(
            parts.getOrNull(0)?.toLongOrNull() ?: 0L,
            parts.getOrNull(1)?.toLongOrNull() ?: 0L,
            parts.getOrNull(2)?.toLongOrNull() ?: 0L,
        )
    }

    /** 存储详情：各分区 StatFs（无权限/不存在的分区返回 0）。 */
    @Suppress("DEPRECATION")
    private fun storageDetail(): List<Map<String, Any>> {
        val entries = listOf(
            "data" to Environment.getDataDirectory().path,
            "system" to Environment.getRootDirectory().path,
            "cache" to Environment.getDownloadCacheDirectory().path,
            "external" to Environment.getExternalStorageDirectory()?.path,
        )
        val list = mutableListOf<Map<String, Any>>()
        val seen = HashSet<String>()
        for ((id, path) in entries) {
            if (path == null || !seen.add(path)) continue
            val stat = try { StatFs(path) } catch (e: Exception) { null } ?: continue
            val item = HashMap<String, Any>()
            item["id"] = id
            item["path"] = path
            item["total"] = stat.totalBytes
            item["free"] = stat.availableBytes
            list.add(item)
        }
        return list
    }

    /** 应用本地存储概况：shared_prefs 文件列表 + 数据/缓存目录占用。 */
    private fun appStorage(): Map<String, Any> {
        val map = HashMap<String, Any>()
        val prefsDir = File(filesDir.parentFile, "shared_prefs")
        val prefs = mutableListOf<Map<String, Any>>()
        prefsDir.listFiles()?.sortedByDescending { it.length() }?.forEach { f ->
            prefs.add(mapOf("name" to f.name, "size" to f.length()))
        }
        map["prefsFiles"] = prefs
        map["dataSize"] = dirSize(filesDir)
        map["cacheSize"] = dirSize(cacheDir)
        return map
    }

    private fun dirSize(dir: File?): Long {
        if (dir == null || !dir.exists()) return 0L
        return dir.walkBottomUp().filter { it.isFile }.sumOf { it.length() }
    }

    /** 缓存根目录：tag 用于 Dart 侧判断归属，且限制单项清理只能落在这些目录内。 */
    private fun cacheRoots(): List<Pair<String, File>> = listOfNotNull(
        "runtime" to cacheDir,
        "external" to externalCacheDir,
        "imports" to File(filesDir, "imports"),
    ).filter { it.second.exists() }

    /**
     * 按顶层目录列出缓存明细，供「缓存」卡片按大小排序、逐项清理。
     *
     * 只展开一层：WebView / 图片库的深层结构对用户没有意义，
     * 但扩展名统计能让人大致看出是图片、视频还是临时数据。
     */
    private fun cacheItems(): List<Map<String, Any>> {
        val out = ArrayList<Map<String, Any>>()
        for ((tag, root) in cacheRoots()) {
            val children = root.listFiles() ?: continue
            for (child in children) {
                val files = if (child.isFile) {
                    listOf(child)
                } else {
                    child.walkBottomUp().filter { it.isFile }.toList()
                }
                if (files.isEmpty()) continue
                val size = files.sumOf { it.length() }
                if (size <= 0L) continue
                val types = HashMap<String, Long>()
                for (f in files) {
                    val ext = f.extension.lowercase()
                    val label = if (ext.isEmpty()) "其他" else ".$ext"
                    types[label] = (types[label] ?: 0L) + f.length()
                }
                val summary = types.entries
                    .sortedByDescending { it.value }
                    .take(2)
                    .joinToString("/") { it.key }
                out.add(
                    mapOf(
                        "key" to "$tag/${child.name}",
                        "tag" to tag,
                        "name" to child.name,
                        "size" to size,
                        "count" to files.size,
                        "types" to summary,
                    )
                )
            }
        }
        return out
    }

    /** 只清理 [key] 指向的那一项缓存；越界路径一律拒绝。 */
    private fun clearCacheItem(key: String?): Long {
        if (key.isNullOrEmpty()) return 0L
        val parts = key.split("/", limit = 2)
        if (parts.size != 2) return 0L
        val root = cacheRoots().firstOrNull { it.first == parts[0] }?.second
            ?: return 0L
        val target = try {
            File(root, parts[1]).canonicalFile
        } catch (_: Exception) {
            return 0L
        }
        val prefix = root.canonicalPath + File.separator
        if (!target.canonicalPath.startsWith(prefix)) return 0L
        if (!target.exists()) return 0L
        val freed = if (target.isFile) target.length() else dirSize(target)
        if (target.deleteRecursively()) return freed
        return 0L
    }

    /**
     * 清理运行时缓存，返回释放的字节数。
     *
     * 只动缓存目录与导入时的临时副本；app_storage/ 下的用户文件、题库、
     * 个人信息与电池历史都在 filesDir 里，不在此列，绝不能一起删掉。
     */
    private fun clearAppCache(): Long {
        val roots = listOfNotNull(
            cacheDir,
            externalCacheDir,
            File(filesDir, "imports"),
        )
        var freed = 0L
        for (root in roots) {
            if (!root.exists()) continue
            root.walkBottomUp().forEach { f ->
                if (f == root) return@forEach
                if (f.isFile) {
                    val size = f.length()
                    if (f.delete()) freed += size
                } else if (f.isDirectory) {
                    f.delete()
                }
            }
        }
        return freed
    }

    /**
     * 电池电流归一化到 µA。
     *
     * 各厂商实现差异很大：
     * - 标准实现返回 µA（如 1,250,000 = 1.25 A）；
     * - 部分机型返回 mA（如 1250），需 ×1000；
     * - 不支持时返回 Integer.MIN_VALUE / MAX_VALUE 或明显不合理的值。
     * 超过 20 A 的一律视为无效，避免出现「2000 A」这种荒谬数字。
     */
    private fun normalizeMicroAmps(raw: Int): Long {
        if (raw == 0 || raw == Int.MIN_VALUE || raw == Int.MAX_VALUE) return 0L
        val value = raw.toLong()
        // 小于 10 mA 的绝对值按 mA 口径处理（µA 口径下不可能这么小）
        val microAmps = if (kotlin.math.abs(value) < 10_000L) value * 1000L else value
        return if (kotlin.math.abs(microAmps) > 20_000_000L) 0L else microAmps
    }

    /** 电荷量（µAh）归一化：无效值归零，异常量级同样丢弃。 */
    private fun normalizeChargeUah(raw: Int): Long {
        if (raw <= 0 || raw == Int.MIN_VALUE) return 0L
        val value = raw.toLong()
        // 合理范围：1 mAh ~ 100 Ah
        return if (value in 1_000L..100_000_000L) value else 0L
    }

    private fun parseCpuTicks(lines: List<String>, index: Int): List<Long> {
        val prefix = "cpu$index "
        for (line in lines) {
            if (line.startsWith(prefix)) {
                val parts = line.trim().split(Regex("\\s+")).drop(1)
                return (0 until TICK_SLOTS).map { j ->
                    parts.getOrNull(j)?.toLongOrNull() ?: 0L
                }
            }
        }
        return List(TICK_SLOTS) { 0L }
    }

    private fun parseMeminfoKb(text: String, key: String): Long {
        for (line in text.split('\n')) {
            if (line.startsWith(key)) {
                return line.substringAfter(':').trim().split(' ').firstOrNull()?.toLongOrNull() ?: 0L
            }
        }
        return 0L
    }

    private fun readLong(path: String): Long {
        return try {
            File(path).readText().trim().toLongOrNull() ?: 0L
        } catch (e: Exception) {
            0L
        }
    }

    private fun readText(path: String): String? {
        return try {
            File(path).readText()
        } catch (e: Exception) {
            null
        }
    }
}
