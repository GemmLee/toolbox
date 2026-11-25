package com.toolbox.app.quicksearch

import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import android.view.Gravity
import android.view.WindowManager
import android.widget.FrameLayout
import com.toolbox.app.overlay.OverlayBall
import com.toolbox.app.overlay.OverlayBallView
import com.toolbox.app.overlay.OverlayThemeStore
import java.io.File
import kotlin.math.max

/**
 * 便捷搜题的悬浮窗宿主。
 *
 * 窗口本身只占内容大小（WRAP_CONTENT），配合 `FLAG_NOT_FOCUSABLE`：
 * 不会抢走宿主 App 的输入焦点，窗口外的触摸照常落到下面的应用。
 *
 * 位置以「搜索框左上角」为锚点保存 —— 键盘/结果面板切换会改变窗口高度，
 * 只按左上角记位置会导致面板一展开就整体上移，这里每次尺寸变化都反算一次。
 *
 * 自绘键盘只有 26 个字母，中文题按拼音首字母搜（`aq` → 「安全」），
 * 所以全程不需要输入法，也不会动宿主 App 的焦点。
 */
class QuickSearchService : Service(), QuickSearchOverlayView.Host {

    companion object {
        @Volatile
        var isShowing: Boolean = false

        const val EXTRA_INDEX_PATH = "index_path"

        /** 只在这些题库里搜；不带 / 空表表示全部题库。 */
        const val EXTRA_BANK_IDS = "bank_ids"

        /** 每次最多返回几道题（相关度从高到低）。 */
        const val EXTRA_MAX_RESULTS = "max_results"

        /** 悬浮窗背景色；不传表示沿用偏好里的值。 */
        const val EXTRA_THEME = "theme"

        private const val PREFS = "overlay_state"

        /** 旧版是单一缩放值，升级后两个方向都从它起步。 */
        private const val KEY_QUICK_SCALE_OLD = "quick_scale"
        private const val KEY_QUICK_SCALE_X = "quick_scale_x"
        private const val KEY_QUICK_SCALE_Y = "quick_scale_y"
        private const val KEY_TYPE_FILTER = "quick_type_filter"
        private const val KEY_MAX_RESULTS = "quick_max_results"
        private const val DEFAULT_MAX_RESULTS = 3

        /** 收起后小球的边与高度。 */
        private const val KEY_BALL_SIDE = "quick_ball_side"
        private const val KEY_BALL_Y = "quick_ball_y"

        /** 启动悬浮窗；没有悬浮窗权限或系统拦截时返回 false，由 UI 走降级。 */
        fun start(
            context: Context,
            indexPath: String,
            bankIds: Set<String>? = null,
            maxResults: Int = DEFAULT_MAX_RESULTS,
        ): Boolean {
            if (!Settings.canDrawOverlays(context)) return false
            return try {
                val intent = Intent(context, QuickSearchService::class.java)
                    .putExtra(EXTRA_INDEX_PATH, indexPath)
                    .putExtra(EXTRA_BANK_IDS, bankIds?.toTypedArray())
                    .putExtra(EXTRA_MAX_RESULTS, maxResults)
                context.startService(intent)
                true
            } catch (_: Exception) {
                false
            }
        }

        fun stop(context: Context) {
            try {
                context.stopService(Intent(context, QuickSearchService::class.java))
            } catch (_: Exception) {
            }
        }

        /**
         * 改背景色：写偏好；窗口开着时再发一条带主题的空 intent，
         * onStartCommand 会把新色应用到现有 View（不重建窗口）。
         */
        fun applyTheme(context: Context, theme: String) {
            OverlayThemeStore.write(context, theme)
            if (isShowing) {
                try {
                    context.startService(
                        Intent(context, QuickSearchService::class.java)
                            .putExtra(EXTRA_THEME, theme)
                    )
                } catch (_: Exception) {
                }
            }
        }
    }

    private var windowManager: WindowManager? = null
    private var root: FrameLayout? = null
    private var overlay: QuickSearchOverlayView? = null
    private var params: WindowManager.LayoutParams? = null

    /** 便捷搜题自己的索引：只含所选题库的题，与智能搜题的全量索引互不影响。 */
    private val index = QuickSearchIndex()

    /** 收起成边缘小球时的宿主；[minimized] 为真时主窗口已从 WindowManager 摘下。 */
    private var ball: OverlayBall? = null
    private var minimized = false

    private var anchorX = 0
    private var anchorY = 0
    private var placed = false
    private var lastW = 0
    private var lastH = 0

    /**
     * 正在拖把手缩放。
     *
     * 缩放时窗口左上角保持不动、尺寸向右下长，所以这期间不能再按「搜索框锚点」
     * 反算位置 —— 那会把窗口往回拽，看着像原地抖动。
     */
    private var scaling = false

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
        // 换题库会重建首字母表；建好后补搜一次，不让窗口停在「没有匹配到题目」。
        index.onInitialsReady = { overlay?.refreshResult() }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val path = intent?.getStringExtra(EXTRA_INDEX_PATH)
        if (path != null) {
            // 索引加载完会自己在后台建拼音首字母表，键盘打字时只查表。
            index.load(File(path))
        }
        val bankIds = intent?.getStringArrayExtra(EXTRA_BANK_IDS)?.toSet()
        val extraMax = intent?.getIntExtra(EXTRA_MAX_RESULTS, -1) ?: -1
        if (extraMax > 0) {
            prefs().edit().putInt(KEY_MAX_RESULTS, extraMax).apply()
        }
        val maxResults = if (extraMax > 0) {
            extraMax
        } else {
            prefs().getInt(KEY_MAX_RESULTS, DEFAULT_MAX_RESULTS)
        }
        if (overlay == null) {
            attach(bankIds, maxResults)
        } else {
            // 页面里换了题库 / 显示数：窗口不重建，只更新对应项。
            // 换范围的 intent 一定带 EXTRA_BANK_IDS；纯换主题的 intent 不带，
            // 若照样 setBankFilter(null) 会把用户选的范围悄悄重置成「全部」。
            if (intent?.hasExtra(EXTRA_BANK_IDS) == true) {
                overlay?.setBankFilter(bankIds)
            }
            overlay?.setMaxResults(maxResults)
            intent?.getStringExtra(EXTRA_THEME)?.let { overlay?.setTheme(it) }
            if (minimized) restoreFromBall()
        }
        return START_NOT_STICKY
    }

    private fun attach(
        bankIds: Set<String>? = null,
        maxResults: Int = DEFAULT_MAX_RESULTS,
    ) {
        val wm = windowManager ?: return
        if (!Settings.canDrawOverlays(this)) {
            stopSelf()
            return
        }
        val typeFilter = prefs().getString(KEY_TYPE_FILTER, null)
        // 起落两个名字：`apply` 里的 bankIds 会先撞到 View 自己的属性。
        val initialBanks = bankIds
        val container = FrameLayout(this)
        val view = QuickSearchOverlayView(this, index).apply {
            host = this@QuickSearchService
            val legacy = prefs().getFloat(KEY_QUICK_SCALE_OLD, 1f)
            applyScale(
                prefs().getFloat(KEY_QUICK_SCALE_X, legacy),
                prefs().getFloat(KEY_QUICK_SCALE_Y, legacy),
            )
            setMaxResults(maxResults)
            setBankFilter(initialBanks)
            restoreTypeFilter(typeFilter)
            setTheme(OverlayThemeStore.read(this@QuickSearchService))
        }
        container.addView(
            view,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.WRAP_CONTENT,
            WindowManager.LayoutParams.WRAP_CONTENT,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = 0
            y = 0
        }
        params = lp
        root = container
        overlay = view
        try {
            wm.addView(container, lp)
            isShowing = true
        } catch (_: Exception) {
            // 国产系统常见拦截：直接放弃，交由 Flutter 侧降级。
            root = null
            overlay = null
            params = null
            stopSelf()
            return
        }
        container.addOnLayoutChangeListener { _, _, _, right, bottom, _, _, _, _ ->
            val w = right
            val h = bottom
            if (w == lastW && h == lastH) return@addOnLayoutChangeListener
            lastW = w
            lastH = h
            if (scaling) return@addOnLayoutChangeListener
            if (!placed) {
                placed = true
                placeInitial()
            } else {
                applyAnchor()
            }
        }
    }

    private fun prefs() = getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 初始位置：水平居中、屏幕上方 1/4 处，留出状态栏高度。 */
    private fun placeInitial() {
        val view = overlay ?: return
        val (sw, sh) = usableSize()
        val w = if (view.width > 0) view.width else sw / 2
        anchorX = ((sw - w) / 2).coerceAtLeast(0)
        anchorY = (sh / 4).coerceAtLeast(statusBarHeight())
        applyAnchor()
    }

    /** 按锚点反算窗口左上角，并夹在可用区域内。 */
    private fun applyAnchor() {
        val view = overlay ?: return
        val lp = params ?: return
        val container = root ?: return
        if (view.width == 0 || view.height == 0) return
        val (sw, sh) = usableSize()
        val offsetX = view.searchOffsetX()
        val offsetY = view.searchOffsetY()
        val h = view.height
        val x = (anchorX - offsetX).coerceIn(0, max(0, sw - view.width))
        val y = (anchorY - offsetY).coerceIn(0, max(0, sh - h))
        lp.x = x
        lp.y = y
        try {
            windowManager?.updateViewLayout(container, lp)
        } catch (_: Exception) {
            return
        }
        // 夹紧后同步锚点，避免多次展开/收起后漂移。
        anchorX = x + offsetX
        anchorY = y + offsetY
    }

    override fun onDragBy(dx: Float, dy: Float) {
        anchorX += dx.toInt()
        anchorY += dy.toInt()
        applyAnchor()
    }

    /**
     * 拖动右下角缩放把手：只改视图的缩放比，窗口位置（左上角）一律不动。
     *
     * 左上角固定 + 尺寸向右下长，手指往右下拖就是「变大」，方向和结果一致；
     * 落盘与夹回屏幕放到 [onScaleFinished]，拖动过程中不写 SharedPreferences。
     */
    override fun onScaleChanged(zoomX: Float, zoomY: Float) {
        val view = overlay ?: return
        scaling = true
        view.applyScale(zoomX, zoomY)
    }

    override fun onScaleFinished() {
        val view = overlay ?: return
        if (!scaling) return
        scaling = false
        prefs().edit()
            .putFloat(KEY_QUICK_SCALE_X, view.zoomX)
            .putFloat(KEY_QUICK_SCALE_Y, view.zoomY)
            .remove(KEY_QUICK_SCALE_OLD)
            .apply()
        val lp = params ?: return
        // 放大后可能顶出屏幕：把锚点按当前实际位置重算，交给 applyAnchor 夹回去。
        anchorX = lp.x + view.searchOffsetX()
        anchorY = lp.y + view.searchOffsetY()
        applyAnchor()
    }

    override fun onMinimize() {
        minimizeToBall()
    }

    /** 题型筛选落盘：关掉再开、收起再展开都沿用上一次的选择。 */
    override fun onTypeFilterChanged(type: String?) {
        prefs().edit().putString(KEY_TYPE_FILTER, type).apply()
    }

    override fun onClose() {
        stopSelf()
    }

    // ---------- 收起 / 展开 ----------

    /**
     * 收起成边缘小球。
     *
     * 视图层次保留着（输入到一半的词、当前是键盘还是结果都还在），只是从
     * WindowManager 摘下来，省得还挡着屏幕；点小球再原样挂回去。
     */
    private fun minimizeToBall() {
        if (minimized) return
        val container = root ?: return
        val lp = params ?: return
        val view = overlay ?: return
        val w = if (container.width > 0) container.width else view.width
        val h = if (container.height > 0) container.height else view.height
        val cx = lp.x + w / 2
        val cy = lp.y + h / 2
        // 先挂球：挂不上就保持原样，不能出现「窗口没了、球也没有」的空屏。
        if (ball?.show(OverlayBallView.Glyph.KEYBOARD, cx, cy) != true) return
        minimized = true
        try {
            windowManager?.removeView(container)
        } catch (_: Exception) {
        }
    }

    private fun restoreFromBall() {
        if (!minimized) return
        val container = root ?: return
        val lp = params ?: return
        ball?.hide()
        minimized = false
        try {
            windowManager?.addView(container, lp)
        } catch (_: Exception) {
            stopSelf()
            return
        }
        // 视图离开窗口时会把 host 清掉，重新挂上后得接回来，否则按键全无反应。
        overlay?.host = this
        container.post { applyAnchor() }
    }

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
        index.onInitialsReady = null
        ball?.hide()
        ball = null
        minimized = false
        val view = root
        root = null
        overlay = null
        params = null
        if (view != null) {
            try {
                windowManager?.removeView(view)
            } catch (_: Exception) {
            }
        }
        super.onDestroy()
    }
}
