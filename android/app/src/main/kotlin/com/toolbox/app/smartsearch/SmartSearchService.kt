package com.toolbox.app.smartsearch

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.RectF
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.TextRecognizer
import com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions
import com.toolbox.app.overlay.OverlayBall
import com.toolbox.app.overlay.OverlayBallView
import com.toolbox.app.overlay.OverlayThemeStore
import com.toolbox.app.quicksearch.QuickSearchIndex
import java.io.File
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.max
import kotlin.math.min

/**
 * 智能搜题的悬浮窗宿主：一个结果窗 + 一个框选窗，同一时间只显示其中一个。
 *
 * 流程：框选窗摆好位置 → 返回结果窗 → 宿主应用内容一变（无障碍事件）就截屏、
 * 裁出选区、OCR、在题库里找最像的一道，结果窗随之刷新。
 *
 * 注意：截屏时不能把结果窗藏起来再显示（那样每隔一两秒闪一下），改成截图裁剪后
 * 把结果窗盖住的那块涂掉；反正那块内容本来就被窗口挡住了，用户也看不到。
 */
class SmartSearchService : Service(), SmartResultView.Host, RegionSelectView.Host {

    companion object {
        @Volatile
        var isShowing: Boolean = false

        const val EXTRA_INDEX_PATH = "index_path"

        /** 每次最多返回几道题（相关度从高到低）。 */
        const val EXTRA_MAX_RESULTS = "max_results"

        /** 悬浮窗背景色；不传表示沿用偏好里的值。 */
        const val EXTRA_THEME = "theme"

        private const val KEY_MAX_RESULTS = "smart_max_results"
        private const val DEFAULT_MAX_RESULTS = 3

        private const val PREFS = "overlay_state"
        private const val KEY_RESULT_X = "smart_result_x"
        private const val KEY_RESULT_Y = "smart_result_y"

        /** 手动拖出来的窗口宽/高（dp，0 表示跟随内容）。 */
        private const val KEY_RESULT_W = "smart_result_w"
        private const val KEY_RESULT_H = "smart_result_h"
        private const val KEY_REGION_X = "smart_region_x"
        private const val KEY_REGION_Y = "smart_region_y"
        private const val KEY_REGION_W = "smart_region_w"
        private const val KEY_REGION_H = "smart_region_h"

        /** 收起后小球的边与高度。 */
        private const val KEY_BALL_SIDE = "smart_ball_side"
        private const val KEY_BALL_Y = "smart_ball_y"

        /** 两次截屏之间的最小间隔，防止宿主应用频繁刷新把 OCR 打满。 */
        private const val MIN_SCAN_INTERVAL_MS = 900L

        /** 防抖最长可推迟的时间：事件不断时也不能无限延后，否则永远扫不到。 */
        private const val MAX_DEBOUNCE_MS = 1200L

        /** 兜底轮询间隔：宿主不发无障碍事件时靠它发现换题。 */
        private const val POLL_INTERVAL_MS = 1200L

        /**
         * 画面指纹的采样尺寸与变化阈值。
         *
         * 轮询只做「截屏 + 缩到 48x36 灰度 + 逐像素比较」，不算 OCR；
         * 只有明显变化（>=3% 像素）才真正跑 OCR，避免 OCR 噪声让窗口一直重绘。
         */
        private const val FP_W = 48
        private const val FP_H = 36
        private const val FP_PIXEL_DELTA = 18
        private const val FP_CHANGED_PERCENT = 3

        /** 无障碍事件安静多久之后开始轮询；事件本身可靠时几乎不轮询。 */
        private const val EVENT_IDLE_MS = 1800L

        /** 截屏 / OCR 没有任何回调时的看门狗，防止 scanning 卡死后再也不扫。 */
        private const val SCAN_TIMEOUT_MS = 6000L

        /** 换题后短时间内不允许跳回刚换掉的那道题，打断「A→B→A」的抖动。 */
        private const val SWITCH_GUARD_MS = 1600L

        /**
         * 禁截页面里每隔几轮试一次截图。
         *
         * 节点取词能用，但没有 OCR 准（自绘题目读不到），所以一旦用户切到能截图的
         * 页面就要尽快换回 OCR；每轮都试又太浪费，4 轮一次（约 4 秒）足够。
         */
        private const val SECURE_RETRY_EVERY = 4

        /** 与 [RegionSelectView] 里的操作条高度、描边内缩保持一致。 */
        private const val REGION_HEADER_DP = 34f
        private const val REGION_INSET_DP = 3f

        fun start(
            context: Context,
            indexPath: String,
            maxResults: Int = 3,
        ): Boolean {
            if (!Settings.canDrawOverlays(context)) return false
            return try {
                val intent = Intent(context, SmartSearchService::class.java)
                    .putExtra(EXTRA_INDEX_PATH, indexPath)
                    .putExtra(EXTRA_MAX_RESULTS, maxResults)
                context.startService(intent)
                true
            } catch (_: Exception) {
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, SmartSearchService::class.java))
            } catch (_: Exception) {
            }
        }

        /** 改背景色：写偏好；窗口开着时发一条带主题的空 intent 让 View 立即换色。 */
        fun applyTheme(context: Context, theme: String) {
            OverlayThemeStore.write(context, theme)
            if (isShowing) {
                try {
                    context.startService(
                        Intent(context, SmartSearchService::class.java)
                            .putExtra(EXTRA_THEME, theme)
                    )
                } catch (_: Exception) {
                }
            }
        }
    }

    private enum class Mode { RESULT, REGION }

    private var windowManager: WindowManager? = null
    private var resultView: SmartResultView? = null
    private var resultParams: WindowManager.LayoutParams? = null
    private var regionView: RegionSelectView? = null
    private var regionParams: WindowManager.LayoutParams? = null

    /** 智能搜题要全量题库；与便捷搜题各持一份，互不改范围。 */
    private val index = QuickSearchIndex()

    private var mode = Mode.RESULT
    private var scanning = false
    private var lastText = ""
    private var lastScanAt = 0L
    private var scanRunnable: Runnable? = null

    /** 扫描期间又有画面变化：结束后立刻补一次，不能把这次变化丢掉。 */
    private var pendingScan = false

    /** 当前这次防抖是从什么时候开始排队的，用来实现 [MAX_DEBOUNCE_MS] 上限。 */
    private var pendingSince = 0L

    /** 最近一次无障碍事件时间；用来判断要不要开兜底轮询。 */
    private var lastEventAt = 0L

    /** 当前窗里正在显示的题目题干，用来避免同一题被重复重绘。 */
    private var renderedStem = ""

    /** 上一次送检画面的灰度指纹；用来判断框选区域到底有没有变。 */
    private var lastShot: Shot? = null

    /** 刚被换掉的那道题，用来打断「A→B→A」这种来回抖。 */
    private var previousStem = ""
    private var lastSwitchAt = 0L

    private var pollRunnable: Runnable? = null
    private var watchdog: Runnable? = null
    private var scanSeq = 0

    /**
     * 选区在屏幕上的位置与大小（x, y, w, h）。
     *
     * 框选窗只在框选模式存在，搜索结果窗单独显示时窗口已经移除，所以位置必须
     * 单独记下来，OCR 才有得裁。
     */
    private var regionBounds = IntArray(4)

    /**
     * 框选窗在屏幕上的真实位置（x, y, w, h）。
     *
     * lp.x / lp.y 是窗口坐标，遇到状态栏之类会被整体挤下若干像素；截屏是全屏坐标，
     * 用 getLocationOnScreen 记下来的值去裁剪和涂盖才不会整体偏一条。
     */
    private val regionScreen = IntArray(4)

    /** 窗口坐标 → 屏幕坐标的差值（一般就是状态栏高度），给没窗口可量的场合兜底。 */
    private var windowOffsetX = 0
    private var windowOffsetY = 0

    /** 是否已经框过选区：没框过就先引导用户点左上角，别拿随机区域去 OCR。 */
    private var regionReady = false

    /**
     * 当前页面禁止截图（`FLAG_SECURE`）：截出来是纯黑，改用无障碍节点文本。
     *
     * 会一直保持这个状态，但每隔 [SECURE_RETRY_EVERY] 轮试截一次图——用户切到
     * 别的（可截图的）页面后要能自动恢复走 OCR，不能永远停在节点模式。
     */
    private var secureScreen = false
    private var secureTries = 0

    /** 上一轮节点文本：节点模式没有画面指纹，用它判断「内容有没有变」。 */
    private var lastNodeText = ""

    /** 收起成边缘小球时的宿主（收起后答案窗会整个移除，省得挡屏幕）。 */
    private var ball: OverlayBall? = null

    /** 最近一次展示给用户的内容，收起再展开时直接还原，不用等下一轮 OCR。 */
    private var lastPayload: SmartResultView.Payload? = null

    /** 最近一次 OCR 的多条候选与当前查看下标，左右滑动切换。 */
    private var lastResults: List<QuickSearchIndex.QItem> = emptyList()
    private var lastResultIndex = 0

    /** 每次最多返回几道题，由开启页下发（默认 3）。 */
    private var maxResults = 3

    /** 收起前窗口的位置（窗口坐标），展开时回到原处。 */
    private var stashedX = 0
    private var stashedY = 0
    private var hasStash = false

    private val handler = Handler(Looper.getMainLooper())
    private var recognizer: TextRecognizer? = null

    /** 涂掉自身窗口用的纯色（OCR 只认字形，颜色不影响识别）。 */
    private val maskPaint = Paint().apply { color = Color.WHITE }

    private val density by lazy { resources.displayMetrics.density }
    private fun dp(v: Float) = (v * density).toInt()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        ball = OverlayBall(
            this,
            windowManager!!,
            prefs(),
            KEY_BALL_SIDE,
            KEY_BALL_Y,
        ).apply {
            onTap = { restoreFromBall() }
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val path = intent?.getStringExtra(EXTRA_INDEX_PATH)
        if (path != null) {
            index.load(File(path))
        }
        val extraMax = intent?.getIntExtra(EXTRA_MAX_RESULTS, -1) ?: -1
        if (extraMax > 0) {
            prefs().edit().putInt(KEY_MAX_RESULTS, extraMax).apply()
        }
        maxResults = if (extraMax > 0) {
            extraMax
        } else {
            prefs().getInt(KEY_MAX_RESULTS, DEFAULT_MAX_RESULTS)
        }
        // 运行中改背景色：只换画笔，不重建窗口。
        intent?.getStringExtra(EXTRA_THEME)?.let { resultView?.setTheme(it) }
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return START_NOT_STICKY
        }
        // 无障碍事件 → 防抖后重新搜题。
        SmartSearchAccessibilityService.instance?.onScreenChanged = { noteScreenChange() }
        startPolling()
        loadRegionBounds()
        if (ball?.isShowing == true) {
            // 用户收起过：再点开启就当展开，别同时挂出两个窗口。
            restoreFromBall()
        } else if (resultView == null) {
            mode = Mode.RESULT
            attachResultWindow()
            // 上次的选区还记着：别再让结果窗压在框上。
            runAfterLayout { avoidRegionOverlap() }
            scheduleScan(500)
        }
        return START_NOT_STICKY
    }

    // ---------- 窗口 ----------

    private fun baseParams(w: Int, h: Int): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        return WindowManager.LayoutParams(
            w,
            h,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }
    }

    /** 上次框选的位置与大小；没有记录时给一个居中的默认框，但不认为「已框好」。 */
    private fun loadRegionBounds() {
        val (sw, sh) = usableSize()
        val defW = (sw * 0.88f).toInt()
        val defH = (sh * 0.26f).toInt()
        val saved = prefs()
        regionBounds[0] = saved.getInt(KEY_REGION_X, ((sw - defW) / 2).coerceAtLeast(0))
        regionBounds[1] = saved.getInt(KEY_REGION_Y, (sh * 0.34f).toInt())
        regionBounds[2] = saved.getInt(KEY_REGION_W, defW)
        regionBounds[3] = saved.getInt(KEY_REGION_H, defH)
        regionReady = saved.contains(KEY_REGION_W)
    }

    /** 挂上结果窗；[atX] / [atY] 传入时用它们定位（从球展开时回到收起前的位置）。 */
    private fun attachResultWindow(atX: Int? = null, atY: Int? = null) {
        val wm = windowManager ?: return
        if (resultView != null) return
        val view = SmartResultView(this).apply {
            host = this@SmartSearchService
            setTheme(OverlayThemeStore.read(this@SmartSearchService))
            setPreferredSize(
                prefs().getFloat(KEY_RESULT_W, 0f),
                prefs().getFloat(KEY_RESULT_H, 0f),
            )
        }
        val lp = baseParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
        ).apply {
            x = atX ?: prefs().getInt(KEY_RESULT_X, dp(14f))
            y = atY ?: prefs().getInt(KEY_RESULT_Y, usableSize().second / 5)
        }
        try {
            wm.addView(view, lp)
        } catch (_: Exception) {
            // 被 ROM 拦截：交给 Flutter 侧提示。
            stopSelf()
            return
        }
        resultView = view
        resultParams = lp
        isShowing = true
        if (SmartSearchAccessibilityService.isConnected) {
            view.showBusy("正在识别…")
        } else {
            view.showBusy("无障碍服务未开启")
        }
    }

    private fun attachRegionWindow() {
        val wm = windowManager ?: return
        if (regionView != null) return
        val (sw, sh) = usableSize()
        val view = RegionSelectView(this).apply { host = this@SmartSearchService }
        val lp = baseParams(
            regionBounds[2].coerceIn(dp(160f), sw),
            regionBounds[3].coerceIn(dp(120f), sh),
        ).apply {
            x = regionBounds[0].coerceIn(0, max(0, sw - width))
            y = regionBounds[1].coerceIn(0, max(0, sh - height))
        }
        try {
            wm.addView(view, lp)
        } catch (_: Exception) {
            return
        }
        regionView = view
        regionParams = lp
        regionBounds[0] = lp.x
        regionBounds[1] = lp.y
        regionBounds[2] = lp.width
        regionBounds[3] = lp.height
    }

    private fun detachResultWindow() {
        val view = resultView ?: return
        resultView = null
        resultParams = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
        }
    }

    private fun detachRegionWindow() {
        val view = regionView ?: return
        rememberRegionScreenRect(view)
        regionView = null
        regionParams = null
        try {
            windowManager?.removeView(view)
        } catch (_: Exception) {
        }
    }

    /** 框选窗挪好了、即将收起时把它的真实屏幕位置记下来，之后 OCR 照着裁。 */
    private fun rememberRegionScreenRect(view: View) {
        val lp = regionParams ?: return
        if (view.width <= 0 || view.height <= 0) return
        val loc = IntArray(2)
        try {
            view.getLocationOnScreen(loc)
        } catch (_: Exception) {
            return
        }
        if (loc[1] < 0) return
        regionScreen[0] = loc[0]
        regionScreen[1] = loc[1]
        regionScreen[2] = view.width
        regionScreen[3] = view.height
        val dx = loc[0] - lp.x
        val dy = loc[1] - lp.y
        if (abs(dx) <= dp(120f) && abs(dy) <= dp(120f)) {
            windowOffsetX = dx
            windowOffsetY = dy
        }
    }

    /** 选区在屏幕坐标系里的矩形；框选窗不在时用记住的偏移把 lp 坐标补回来。 */
    private fun regionScreenRect(): IntArray {
        if (regionScreen[2] > 0 && regionScreen[3] > 0) return regionScreen
        return intArrayOf(
            regionBounds[0] + windowOffsetX,
            regionBounds[1] + windowOffsetY,
            regionBounds[2],
            regionBounds[3],
        )
    }

    // ---------- 结果窗回调 ----------

    override fun onDragBy(dx: Float, dy: Float) {
        val lp = resultParams ?: return
        val view = resultView ?: return
        val (sw, sh) = usableSize()
        lp.x = (lp.x + dx.toInt()).coerceIn(0, max(0, sw - view.width))
        lp.y = (lp.y + dy.toInt()).coerceIn(0, max(0, sh - view.height))
        safeUpdate(view, lp)
    }

    /** 边缘把手：只改一个方向的尺寸，宽度变化时正文按新宽度重排。 */
    override fun onResizeBy(dw: Float, dh: Float) {
        resultView?.resizeBy(dw, dh)
    }

    override fun onResizeFinished() {
        val view = resultView ?: return
        prefs().edit()
            .putFloat(KEY_RESULT_W, view.preferredWidthDp)
            .putFloat(KEY_RESULT_H, view.preferredHeightDp)
            .apply()
        // 尺寸变了要重新算窗口位置的上限，顺手把当前位置夹回屏幕内。
        val lp = resultParams ?: return
        val (sw, sh) = usableSize()
        lp.x = lp.x.coerceIn(0, max(0, sw - max(view.width, dp(120f))))
        lp.y = lp.y.coerceIn(0, max(0, sh - max(view.height, dp(80f))))
        safeUpdate(view, lp)
    }

    override fun onPickRegion() {
        switchToRegion()
    }

    override fun onMinimize() {
        minimizeToBall()
    }

    override fun onClose() {
        stopSelf()
    }

    // ---------- 收起 / 展开 ----------

    /**
     * 收起成边缘小球。
     *
     * 窗口要真移除而不是设成不可见：留着就还挡着屏幕，而且截屏里那块依旧要涂白。
     * 移除后没有结果窗，扫描自然停摆（[doScan] 拿不到 view），展开时再补扫一次。
     */
    private fun minimizeToBall() {
        if (mode != Mode.RESULT) return
        val view = resultView ?: return
        val lp = resultParams ?: return
        val cx = lp.x + view.width / 2
        val cy = lp.y + view.height / 2
        // 先挂球：挂不上就保持原样，不能出现「窗口没了、球也没有」的空屏。
        if (ball?.show(OverlayBallView.Glyph.SEARCH, cx, cy) != true) return
        stashedX = lp.x
        stashedY = lp.y
        hasStash = true
        // 收起状态下被关掉的话，下次也要回到这个位置，所以先落盘。
        prefs().edit()
            .putInt(KEY_RESULT_X, lp.x)
            .putInt(KEY_RESULT_Y, lp.y)
            .apply()
        scanning = false
        pendingScan = false
        scanRunnable?.let { handler.removeCallbacks(it) }
        scanRunnable = null
        disarmWatchdog()
        detachResultWindow()
        lastShot = null
    }

    /** 点小球展开：先摆回原内容（不必等 OCR），再重扫一次确认有没有换题。 */
    private fun restoreFromBall() {
        ball?.hide()
        if (mode != Mode.RESULT) return
        attachResultWindow(if (hasStash) stashedX else null, if (hasStash) stashedY else null)
        val view = resultView ?: return
        val payload = lastPayload
        if (payload != null) {
            view.show(payload)
        } else if (SmartSearchAccessibilityService.isConnected) {
            view.showBusy("正在识别…")
        } else {
            view.showBusy("无障碍服务未开启")
        }
        runAfterLayout { avoidRegionOverlap() }
        lastText = ""
        renderedStem = ""
        lastNodeText = ""
        previousStem = ""
        lastShot = null
        pendingScan = false
        pendingSince = 0L
        scheduleScan(220)
    }

    // ---------- 框选窗回调 ----------

    override fun onMoveBy(dx: Float, dy: Float) {
        val lp = regionParams ?: return
        val view = regionView ?: return
        val (sw, sh) = usableSize()
        lp.x = (lp.x + dx.toInt()).coerceIn(0, max(0, sw - view.width))
        lp.y = (lp.y + dy.toInt()).coerceIn(0, max(0, sh - view.height))
        regionBounds[0] = lp.x
        regionBounds[1] = lp.y
        safeUpdate(view, lp)
    }

    override fun onResizeTo(width: Int, height: Int) {
        val lp = regionParams ?: return
        val view = regionView ?: return
        val (sw, sh) = usableSize()
        lp.width = width.coerceIn(dp(160f), sw - lp.x)
        lp.height = height.coerceIn(dp(120f), sh - lp.y)
        regionBounds[2] = lp.width
        regionBounds[3] = lp.height
        safeUpdate(view, lp)
    }

    override fun onBack() {
        switchToResult()
    }

    private fun safeUpdate(view: View, lp: WindowManager.LayoutParams) {
        try {
            windowManager?.updateViewLayout(view, lp)
        } catch (_: Exception) {
        }
    }

    // ---------- 模式切换 ----------

    private fun switchToRegion() {
        if (mode == Mode.REGION) return
        mode = Mode.REGION
        scanning = false
        pendingScan = false
        scanRunnable?.let { handler.removeCallbacks(it) }
        scanRunnable = null
        disarmWatchdog()
        detachResultWindow()
        attachRegionWindow()
    }

    private fun switchToResult() {
        if (mode == Mode.RESULT) return
        mode = Mode.RESULT
        scanning = false
        scanRunnable?.let { handler.removeCallbacks(it) }
        scanRunnable = null
        disarmWatchdog()
        saveRegionBounds()
        regionReady = regionBounds[2] > 0 && regionBounds[3] > 0
        detachRegionWindow()
        attachResultWindow()
        // 结果窗要是正好压在选区上，OCR 就只看得见窗口自己：自动挪到选区外面去。
        runAfterLayout { avoidRegionOverlap() }
        // 画面可能已经翻页，强制重算一次。
        lastText = ""
        renderedStem = ""
        lastNodeText = ""
        previousStem = ""
        lastShot = null
        pendingScan = false
        pendingSince = 0L
        scheduleScan(320)
    }

    private fun saveRegionBounds() {
        prefs().edit()
            .putInt(KEY_REGION_X, regionBounds[0])
            .putInt(KEY_REGION_Y, regionBounds[1])
            .putInt(KEY_REGION_W, regionBounds[2])
            .putInt(KEY_REGION_H, regionBounds[3])
            .apply()
    }

    /** 窗口第一次量出尺寸之后再执行（刚 addView 时 width/height 还是 0）。 */
    private fun runAfterLayout(block: () -> Unit) {
        val view = resultView ?: return
        if (view.width > 0 && view.height > 0) {
            block()
            return
        }
        view.addOnLayoutChangeListener(object : View.OnLayoutChangeListener {
            override fun onLayoutChange(
                v: View,
                left: Int,
                top: Int,
                right: Int,
                bottom: Int,
                oldLeft: Int,
                oldTop: Int,
                oldRight: Int,
                oldBottom: Int,
            ) {
                v.removeOnLayoutChangeListener(this)
                block()
            }
        })
    }

    /**
     * 把结果窗挪到选区之外。
     *
     * 悬浮窗和题目在同一块屏幕上，窗口压住哪几行，OCR 就永远读不到那几行——涂白只是
     * 别让窗口里的「答案」被当成题目，救不回被挡住的字。所以框选完就主动挪开：
     * 优先放到选区下方，放不下放上方，再不行放左右。挪不出空位（选区几乎铺满屏幕）
     * 就原地不动，走涂白兜底。
     */
    private fun avoidRegionOverlap() {
        val view = resultView ?: return
        val lp = resultParams ?: return
        if (regionBounds[2] <= 0 || regionBounds[3] <= 0) return
        if (view.width <= 0 || view.height <= 0) return
        val reg = regionScreenRect()
        if (reg[2] <= 0 || reg[3] <= 0) return
        val w = view.width
        val h = view.height
        // 量一次结果窗的真实屏幕位置：lp 坐标跟屏幕坐标可能差一条状态栏。
        val loc = IntArray(2)
        try {
            view.getLocationOnScreen(loc)
        } catch (_: Exception) {
            loc[0] = lp.x
            loc[1] = lp.y
        }
        if (loc[1] < 0) {
            loc[0] = lp.x
            loc[1] = lp.y
        }
        val dx = loc[0] - lp.x
        val dy = loc[1] - lp.y
        if (abs(dx) <= dp(120f) && abs(dy) <= dp(120f)) {
            windowOffsetX = dx
            windowOffsetY = dy
        }
        val dm = resources.displayMetrics
        val scrW = dm.widthPixels
        val scrH = dm.heightPixels
        val regR = reg[0] + reg[2]
        val regB = reg[1] + reg[3]
        val curX = loc[0]
        val curY = loc[1]
        val overlap = { x: Int, y: Int ->
            x < regR && x + w > reg[0] && y < regB && y + h > reg[1]
        }
        if (!overlap(curX, curY)) return
        val gap = dp(8f).toInt()
        val topLimit = statusBarHeight()
        val bottomLimit = scrH - navBarHeight()
        val sideY = curY.coerceIn(topLimit, max(topLimit, bottomLimit - h))
        var nx = curX
        var ny: Int
        when {
            regB + gap + h <= bottomLimit -> ny = regB + gap
            reg[1] - gap - h >= topLimit -> ny = reg[1] - gap - h
            regR + gap + w <= scrW -> {
                nx = regR + gap
                ny = sideY
            }
            reg[0] - gap - w >= 0 -> {
                nx = reg[0] - gap - w
                ny = sideY
            }
            else -> return
        }
        nx = nx.coerceIn(0, max(0, scrW - w))
        ny = ny.coerceIn(0, max(0, scrH - h))
        // 夹回屏幕后又压上去了，就别挪了，免得来回跳。
        if (overlap(nx, ny)) return
        lp.x = nx - windowOffsetX
        lp.y = ny - windowOffsetY
        safeUpdate(view, lp)
    }

    // ---------- 扫描 ----------

    private fun scheduleScan(delayMs: Long = 700) {
        if (mode != Mode.RESULT) return
        if (resultView == null) return
        val now = SystemClock.uptimeMillis()
        if (scanRunnable == null) pendingSince = now
        // 换题动画、倒计时这类高频事件会一直重置防抖，超过上限就直接扫。
        val wait = if (now - pendingSince > MAX_DEBOUNCE_MS) 0L else delayMs
        scanRunnable?.let { handler.removeCallbacks(it) }
        val runnable = Runnable { doScan() }
        scanRunnable = runnable
        handler.postDelayed(runnable, wait)
    }

    /** 无障碍事件入口：记录时间并防抖重扫。 */
    private fun noteScreenChange() {
        lastEventAt = SystemClock.uptimeMillis()
        scheduleScan(700)
    }

    /**
     * 兜底轮询。
     *
     * WebView / Flutter / Compose 之类的宿主常常不发（或很少发）内容变化事件，
     * 纯事件驱动会漏掉换题。这里在「事件安静了一段时间」之后每秒补扫一次，
     * 事件正常时几乎不会触发，不影响耗电。
     */
    private fun startPolling() {
        if (pollRunnable != null) return
        val runnable = object : Runnable {
            override fun run() {
                if (pollRunnable !== this) return
                pollTick()
                handler.postDelayed(this, POLL_INTERVAL_MS)
            }
        }
        pollRunnable = runnable
        handler.postDelayed(runnable, POLL_INTERVAL_MS)
    }

    private fun stopPolling() {
        pollRunnable?.let { handler.removeCallbacks(it) }
        pollRunnable = null
    }

    private fun pollTick() {
        if (mode != Mode.RESULT || resultView == null || !regionReady) return
        if (!isScreenOn()) return
        // 事件还在来，说明宿主会自己通知，轮询没必要插一脚。
        if (SystemClock.uptimeMillis() - lastEventAt < EVENT_IDLE_MS) return
        if (scanning || scanRunnable != null) return
        scheduleScan(0)
    }

    private fun isScreenOn(): Boolean = try {
        val pm = getSystemService(Context.POWER_SERVICE) as? android.os.PowerManager
        pm?.isInteractive ?: true
    } catch (_: Exception) {
        true
    }

    private fun armWatchdog() {
        disarmWatchdog()
        val seq = ++scanSeq
        val runnable = Runnable {
            if (seq == scanSeq && scanning) {
                // 截图或 OCR 的回调丢了：复位后重新排一次，别让悬浮窗永久停在旧答案。
                scanning = false
                scheduleScan(300)
            }
        }
        watchdog = runnable
        handler.postDelayed(runnable, SCAN_TIMEOUT_MS)
    }

    private fun disarmWatchdog() {
        watchdog?.let { handler.removeCallbacks(it) }
        watchdog = null
    }

    private fun takePending() {
        if (!pendingScan) return
        pendingScan = false
        if (mode == Mode.RESULT) scheduleScan(150)
    }

    private fun doScan() {
        scanRunnable = null
        pendingSince = 0L
        if (mode != Mode.RESULT) return
        if (scanning) {
            // 上一轮还在截屏 / OCR：记下来，这一轮结束后立刻补扫。
            pendingScan = true
            return
        }
        val view = resultView ?: return
        val acc = SmartSearchAccessibilityService.instance
        if (acc == null) {
            lastText = ""
            view.showBusy("无障碍服务未开启")
            return
        }
        // 用户可能刚在设置里打开无障碍，这里补挂事件监听。
        acc.onScreenChanged = { noteScreenChange() }
        if (!regionReady) {
            lastText = ""
            view.showBusy("先点左上角框选，把题目框进绿框里")
            return
        }
        val now = SystemClock.uptimeMillis()
        if (now - lastScanAt < MIN_SCAN_INTERVAL_MS) {
            scheduleScan(MIN_SCAN_INTERVAL_MS - (now - lastScanAt) + 40)
            return
        }
        lastScanAt = now
        scanning = true
        armWatchdog()
        // 已知是禁截页面时不再每轮都截（很贵），隔几轮试一次，切页后能自动恢复 OCR。
        if (secureScreen && secureTries++ % SECURE_RETRY_EVERY != 0) {
            scanByNodes(acc)
            return
        }
        capture(acc)
    }

    private fun capture(acc: SmartSearchAccessibilityService) {
        acc.captureScreen { bitmap ->
            if (bitmap == null) {
                // Android 11 以下没有截屏 API；也有些 ROM 直接返回 null。
                scanByNodes(acc)
                return@captureScreen
            }
            val region = ocrRect(bitmap.width, bitmap.height)
            if (region == null) {
                finishScan()
                resultView?.showBusy("选区太小，拖右下角放大一点")
                return@captureScreen
            }
            val cropped = try {
                Bitmap.createBitmap(bitmap, region[0], region[1], region[2], region[3])
            } catch (_: Exception) {
                null
            }
            if (cropped == null) {
                finishScan()
                return@captureScreen
            }
            // 裁出来的位图可能和整屏共享像素（不可写），复制一份再涂掉自己的窗口。
            val work = try {
                cropped.copy(Bitmap.Config.ARGB_8888, true) ?: cropped
            } catch (_: Exception) {
                cropped
            }
            // 整块纯黑 = 这个页面开了 FLAG_SECURE，截图被系统涂掉了，换节点取词。
            if (isMostlyBlack(work)) {
                work.recycle()
                scanByNodes(acc)
                return@captureScreen
            }
            secureScreen = false
            secureTries = 0
            val mask = maskOwnWindow(work, region[0], region[1])
            // 画面（框选区域）没变就不要跑 OCR、更不要重绘窗口——定时轮询不该引起闪烁。
            val shot = fingerprintOf(work, mask)
            if (shot == null || !pictureChanged(shot)) {
                work.recycle()
                finishScan()
                return@captureScreen
            }
            try {
                recognizer().process(InputImage.fromBitmap(work, 0))
                    .addOnSuccessListener { handleText(it.text) }
                    .addOnFailureListener { handleText("") }
            } catch (_: Exception) {
                handleText("")
            }
        }
    }

    /**
     * 不截图，直接读无障碍节点里的文字。
     *
     * 用途：页面禁止截图（截出来纯黑）、系统版本太低没有截屏 API。节点文本和
     * OCR 文本同构，所以解析选项、题干 + 选项双口径匹配都能直接复用。
     */
    private fun scanByNodes(acc: SmartSearchAccessibilityService) {
        val region = regionScreenRect()
        val text = try {
            acc.collectTextInRect(if (region[2] > 0 && region[3] > 0) region else null)
        } catch (_: Exception) {
            ""
        }
        if (text.isBlank()) {
            secureScreen = true
            finishScan()
            ensureVisible()
            resultView?.showBusy("这个页面禁止截屏，也没读到可识别的文字：换一道能选中的题试试")
            return
        }
        secureScreen = true
        lastShot = null
        // 文字没变就不用重新匹配，省电也不会闪。
        if (text == lastNodeText && renderedStem.isNotEmpty()) {
            finishScan()
            return
        }
        lastNodeText = text
        handleText(text)
    }

    /**
     * 这块位图是不是几乎全黑。
     *
     * `FLAG_SECURE` 的窗口被系统从截图里剔除，那块区域就是纯黑；正常页面哪怕
     * 深色主题也有文字和图标。按 20x20 网格采样，99% 以上是近黑才算。
     */
    private fun isMostlyBlack(bitmap: Bitmap): Boolean {
        val stepX = max(1, bitmap.width / 20)
        val stepY = max(1, bitmap.height / 20)
        var dark = 0
        var total = 0
        var y = stepY / 2
        while (y < bitmap.height) {
            var x = stepX / 2
            while (x < bitmap.width) {
                val c = try {
                    bitmap.getPixel(x, y)
                } catch (_: Exception) {
                    return false
                }
                val r = (c ushr 16) and 0xFF
                val g = (c ushr 8) and 0xFF
                val b = c and 0xFF
                total++
                if (r < 12 && g < 12 && b < 12) dark++
                x += stepX
            }
            y += stepY
        }
        return total > 0 && dark * 100 >= total * 99
    }

    /**
     * 把结果窗覆盖的那块涂成纯色。
     *
     * 不隐藏窗口就不会闪；涂掉是因为窗口自己的「答案 / 题干 / 选项」要是被 OCR
     * 读进去，会一直匹配回同一题，换题时也容易判错。
     */
    private fun maskOwnWindow(work: Bitmap, originX: Int, originY: Int): RectF? {
        val view = resultView ?: return null
        val lp = resultParams ?: return null
        if (view.width <= 0 || view.height <= 0) return null
        var left = lp.x
        var top = lp.y
        val loc = IntArray(2)
        try {
            view.getLocationOnScreen(loc)
            if (loc[1] >= 0) {
                left = loc[0]
                top = loc[1]
                val dx = loc[0] - lp.x
                val dy = loc[1] - lp.y
                if (abs(dx) <= dp(120f) && abs(dy) <= dp(120f)) {
                    windowOffsetX = dx
                    windowOffsetY = dy
                }
            }
        } catch (_: Exception) {
        }
        val l = (left - originX).toFloat()
        val t = (top - originY).toFloat()
        val right = l + view.width
        val bottom = t + view.height
        if (right <= 0f || bottom <= 0f || l >= work.width || t >= work.height) return null
        val rect = RectF(
            l.coerceAtLeast(0f),
            t.coerceAtLeast(0f),
            right.coerceAtMost(work.width.toFloat()),
            bottom.coerceAtMost(work.height.toFloat()),
        )
        try {
            Canvas(work).drawRect(rect, maskPaint)
        } catch (_: Exception) {
            return null
        }
        return rect
    }

    /** 一次画面采样：灰度值 + 「被结果窗挡住、不参与比较」的掩码。 */
    private class Shot(val values: IntArray, val skip: BooleanArray)

    /**
     * 把位图压成 FP_W x FP_H 的灰度数组，作为「这一段画面」的指纹。
     *
     * 结果窗盖住的那块要标进 [Shot.skip]：窗口高度会随答案长短变化，遮挡区域
     * 一变指纹就跟着变，会把「窗口自己变高」误判成「题目变了」，进而再扫一次、
     * 再重绘一次——正是来回闪的成因。比较时把两次的遮挡区取并集跳过即可。
     */
    private fun fingerprintOf(bitmap: Bitmap, mask: RectF?): Shot? {
        val w = FP_W
        val h = FP_H
        if (bitmap.width <= 0 || bitmap.height <= 0) return null
        val small = try {
            Bitmap.createScaledBitmap(bitmap, w, h, true)
        } catch (_: Exception) {
            return null
        }
        if (small.width != w || small.height != h) {
            if (small !== bitmap) small.recycle()
            return null
        }
        val px = IntArray(w * h)
        try {
            small.getPixels(px, 0, w, 0, 0, w, h)
        } catch (_: Exception) {
            if (small !== bitmap) small.recycle()
            return null
        }
        if (small !== bitmap) small.recycle()
        val values = IntArray(px.size)
        for (i in px.indices) {
            val c = px[i]
            val r = (c ushr 16) and 0xFF
            val g = (c ushr 8) and 0xFF
            val b = c and 0xFF
            values[i] = (r * 77 + g * 151 + b * 28) shr 8
        }
        val skip = BooleanArray(px.size)
        if (mask != null) {
            val sx = w.toFloat() / bitmap.width
            val sy = h.toFloat() / bitmap.height
            val left = (mask.left * sx).toInt().coerceIn(0, w)
            val right = ceil(mask.right * sx).toInt().coerceIn(0, w)
            val top = (mask.top * sy).toInt().coerceIn(0, h)
            val bottom = ceil(mask.bottom * sy).toInt().coerceIn(0, h)
            for (gy in top until bottom) {
                for (gx in left until right) skip[gy * w + gx] = true
            }
        }
        return Shot(values, skip)
    }

    /** 与上次指纹比较；差异达到阈值才算「画面变了」。遮挡区不参与判断。 */
    private fun pictureChanged(shot: Shot): Boolean {
        val prev = lastShot
        lastShot = shot
        if (prev == null || prev.values.size != shot.values.size) return true
        var compared = 0
        var diff = 0
        for (i in shot.values.indices) {
            if (shot.skip[i] || prev.skip[i]) continue
            compared++
            if (abs(shot.values[i] - prev.values[i]) > FP_PIXEL_DELTA) diff++
        }
        // 几乎整块都被窗口挡住：判断不了，宁可重扫一次（内容没变不会重绘）。
        if (compared * 100 < shot.values.size * 15) return true
        return diff * 100 / compared >= FP_CHANGED_PERCENT
    }

    /** 选区（屏幕坐标）→ 截屏位图里的裁剪矩形；越界或过小时返回 null。 */
    private fun ocrRect(bitmapW: Int, bitmapH: Int): IntArray? {
        val rect = regionScreenRect()
        if (rect[2] <= 0 || rect[3] <= 0) return null
        val inset = (REGION_INSET_DP * density).toInt()
        val header = (REGION_HEADER_DP * density).toInt()
        val left = (rect[0] + inset).coerceIn(0, max(0, bitmapW - 1))
        val top = (rect[1] + header).coerceIn(0, max(0, bitmapH - 1))
        val w = min(rect[2] - inset * 2, bitmapW - left)
        val h = min(rect[3] - header - inset, bitmapH - top)
        if (w < dp(40f) || h < dp(30f)) return null
        return intArrayOf(left, top, w, h)
    }

    private fun finishScan() {
        scanning = false
        disarmWatchdog()
        ensureVisible()
        takePending()
    }

    private fun ensureVisible() {
        val view = resultView ?: return
        if (view.visibility != View.VISIBLE) view.visibility = View.VISIBLE
    }

    private fun handleText(text: String) {
        scanning = false
        disarmWatchdog()
        ensureVisible()
        try {
            applyText(text)
        } finally {
            takePending()
        }
    }

    private fun applyText(text: String) {
        val view = resultView ?: return
        val norm = text.filter { it.isLetterOrDigit() }.lowercase()
        if (norm.isEmpty()) {
            // 识别失败时把基线清掉，否则下次识别出同样的字会被当成「没变化」而卡住。
            lastText = ""
            renderedStem = ""
            view.showBusy("没识别到文字：把答案窗挪开一点，别挡住题目")
            return
        }
        if (norm == lastText) return
        lastText = norm
        val matches = index.topForOcr(text, maxResults)
        if (matches.isEmpty()) {
            renderedStem = ""
            previousStem = ""
            lastResults = emptyList()
            lastResultIndex = 0
            val missing = SmartResultView.Payload(
                summary = "未匹配到题目",
                stem = "",
                options = emptyList(),
                hint = "题库里没有同时对上题干和选项的题。让绿框把题干和选项都盖住再看一次；答案窗也别压在题目上。",
            )
            lastPayload = missing
            view.show(missing)
            return
        }
        // 只是 OCR 抖动（框外字变了、这一题还是同一道）就不要重绘，省得看着一直在跳。
        if (matches.first().first.stem == renderedStem) return
        // A→B→A 的来回跳：刚换掉的那道题马上又跳回来，先别理它。
        val now = SystemClock.uptimeMillis()
        if (matches.first().first.stem == previousStem && now - lastSwitchAt < SWITCH_GUARD_MS) return
        previousStem = renderedStem
        lastSwitchAt = now
        val top = matches.first().first
        renderedStem = top.stem
        lastResults = matches.map { it.first }
        lastResultIndex = 0
        val payload = payloadOf(top, 0)
        lastPayload = payload
        view.show(payload)
    }

    /** 左右滑动切换候选：delta 为 +1 看下一条、-1 看上一条。 */
    override fun onSwipeResult(delta: Int) {
        if (lastResults.size <= 1) return
        val next = (lastResultIndex + delta).coerceIn(0, lastResults.size - 1)
        if (next == lastResultIndex) return
        lastResultIndex = next
        val payload = payloadOf(lastResults[next], next)
        lastPayload = payload
        resultView?.show(payload)
    }

    private fun payloadOf(
        item: QuickSearchIndex.QItem,
        index: Int = 0,
    ): SmartResultView.Payload {
        // 索引里已经带了中文答案与选项标注，判断题不会再露出 true / false。
        val options = item.displayOptions().map { it.text to it.correct }
        val answer = item.displayAnswer()
        val page = if (lastResults.size > 1) "  ${index + 1}/${lastResults.size}" else ""
        val summary = when {
            answer.isNotEmpty() -> "答案：$answer$page"
            page.isNotEmpty() -> page.trim()
            else -> "已匹配"
        }
        return SmartResultView.Payload(
            summary = summary,
            stem = item.stem,
            options = options,
            hint = "",
        )
    }

    private fun recognizer(): TextRecognizer {
        recognizer?.let { return it }
        val created = TextRecognition.getClient(ChineseTextRecognizerOptions.Builder().build())
        recognizer = created
        return created
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    private fun usableSize(): Pair<Int, Int> {
        val dm = resources.displayMetrics
        val w = dm.widthPixels
        val h = dm.heightPixels - statusBarHeight() - navBarHeight()
        return w to max(h, dm.heightPixels / 2)
    }

    private fun statusBarHeight(): Int = systemRes("status_bar_height", 0)

    private fun navBarHeight(): Int = systemRes("navigation_bar_height", 0)

    private fun systemRes(name: String, fallback: Int): Int = try {
        val id = resources.getIdentifier(name, "dimen", "android")
        if (id > 0) resources.getDimensionPixelSize(id) else fallback
    } catch (_: Exception) {
        fallback
    }

    override fun onDestroy() {
        isShowing = false
        SmartSearchAccessibilityService.instance?.onScreenChanged = null
        ball?.hide()
        ball = null
        scanRunnable?.let { handler.removeCallbacks(it) }
        scanRunnable = null
        stopPolling()
        disarmWatchdog()
        resultParams?.let { lp ->
            prefs().edit()
                .putInt(KEY_RESULT_X, lp.x)
                .putInt(KEY_RESULT_Y, lp.y)
                .apply()
        }
        saveRegionBounds()
        detachResultWindow()
        detachRegionWindow()
        try {
            recognizer?.close()
        } catch (_: Exception) {
        }
        recognizer = null
        super.onDestroy()
    }
}
