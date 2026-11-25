package com.toolbox.app.autoclick

import android.annotation.SuppressLint
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.provider.Settings
import android.util.TypedValue
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import io.flutter.plugin.common.MethodChannel
import kotlin.math.abs
import kotlin.random.Random

/**
 * 自动点击的悬浮控制面板 + 动作调度。
 *
 * 启动后面板处于「待开始」，用户先切到目标应用再点面板上的「开始」，
 * 避免刚启动就在 XMtools 自己界面里乱点。所有手势由
 * [AutoClickAccessibilityService] 发出，本服务只管循环、间隔与随机延迟。
 *
 * 「取点」是本服务的一部分：点它之后临时铺一层全屏透明窗口，用户在目标界面
 * 上点哪里就把哪里换算成百分比，直接追加成一个点击动作，并把坐标回传给
 * Flutter（页面存盘、列表同步刷新）。
 */
class AutoClickService : Service() {

    private data class Step(
        val type: String,
        val x: Double,
        val y: Double,
        val x2: Double,
        val y2: Double,
        val durationMs: Long,
    )

    private data class Config(
        val steps: List<Step>,
        val intervalMs: Long,
        val randomDelayMs: Int,
        val repeat: Int,
    )

    companion object {
        @Volatile
        private var instance: AutoClickService? = null

        @Volatile
        private var pendingConfig: Config? = null

        /** 由 MainActivity 注入，用来把取点结果回传给 Flutter。 */
        @Volatile
        var channel: MethodChannel? = null

        val isShowing: Boolean get() = instance != null
        val isRunning: Boolean get() = instance?.running == true

        fun start(context: Context, raw: Map<String, Any?>): Boolean {
            if (!Settings.canDrawOverlays(context)) return false
            pendingConfig = parseConfig(raw)
            val existing = instance
            if (existing != null) {
                existing.applyConfig(pendingConfig!!)
                return true
            }
            return try {
                context.startService(Intent(context, AutoClickService::class.java))
                true
            } catch (_: Exception) {
                false
            }
        }

        /** 面板在屏时热更新动作序列：不改变运行状态，也不重开窗口。 */
        fun update(raw: Map<String, Any?>): Boolean {
            val service = instance ?: return false
            val config = parseConfig(raw)
            pendingConfig = config
            service.applyConfig(config)
            return true
        }

        fun stop(context: Context) {
            instance?.shutdown()
            try {
                context.stopService(Intent(context, AutoClickService::class.java))
            } catch (_: Exception) {
            }
        }

        @Suppress("UNCHECKED_CAST")
        private fun parseConfig(raw: Map<String, Any?>): Config {
            val actions = raw["actions"] as? List<*> ?: emptyList<Any>()
            val steps = actions.mapNotNull { item ->
                val m = item as? Map<*, *> ?: return@mapNotNull null
                Step(
                    type = (m["type"] as? String) ?: "tap",
                    x = (m["x"] as? Number)?.toDouble() ?: 50.0,
                    y = (m["y"] as? Number)?.toDouble() ?: 50.0,
                    x2 = (m["x2"] as? Number)?.toDouble() ?: 50.0,
                    y2 = (m["y2"] as? Number)?.toDouble() ?: 50.0,
                    durationMs = (m["durationMs"] as? Number)?.toLong() ?: 100L,
                )
            }
            return Config(
                steps = steps,
                intervalMs = ((raw["intervalMs"] as? Number)?.toLong() ?: 500L)
                    .coerceIn(50L, 60_000L),
                randomDelayMs = ((raw["randomDelayMs"] as? Number)?.toInt() ?: 0)
                    .coerceIn(0, 60_000),
                repeat = ((raw["repeat"] as? Number)?.toInt() ?: 0)
                    .coerceIn(0, 9999),
            )
        }
    }

    private lateinit var windowManager: WindowManager
    private var panel: View? = null
    private var statusView: TextView? = null
    private var toggleView: TextView? = null
    private var pickView: View? = null
    private val handler = Handler(Looper.getMainLooper())
    private val random = Random.Default

    private var config: Config = Config(emptyList(), 500L, 0, 0)
    private var running = false
    private var stepIndex = 0
    private var round = 0

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        instance = this
        pendingConfig?.let { config = it }
        addPanel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        pendingConfig?.let { applyConfig(it) }
        return START_STICKY
    }

    private fun applyConfig(next: Config) {
        config = next
        // 运行中换配置从第一步重新开始，避免下标越界。
        stepIndex = 0
        round = 0
        if (running) {
            handler.removeCallbacks(tick)
            handler.post(tick)
        } else {
            updatePanel()
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()

    @SuppressLint("ClickableViewAccessibility", "SetTextI18n")
    private fun addPanel() {
        if (panel != null) return

        val status = TextView(this).apply {
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11.5f)
            text = "待开始"
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
            setPadding(dp(2), 0, dp(6), 0)
        }
        val grip = TextView(this).apply {
            text = "⋮⋮"
            setTextColor(Color.argb(110, 255, 255, 255))
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 11f)
            setPadding(0, 0, dp(4), 0)
        }
        val pick = pillButton("取点", Color.argb(46, 255, 255, 255), dp(44)) {
            startPick()
        }
        val toggle = pillButton("开始", Color.rgb(58, 116, 214), dp(50)) {
            toggleRunning()
        }
        val close = pillButton("×", Color.argb(28, 255, 255, 255), dp(26)) {
            shutdown()
        }
        // 三个按钮统一 30dp 高，面板整体压到一行，尽量少挡屏幕。
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            background = GradientDrawable().apply {
                setColor(Color.argb(232, 30, 33, 40))
                cornerRadius = dp(18).toFloat()
            }
            setPadding(dp(8), dp(5), dp(5), dp(5))
            addView(grip)
            addView(status, LinearLayout.LayoutParams(0, -2, 1f))
            addView(pick)
            addView(toggle)
            addView(close)
            // 视图本身要吃掉 DOWN，否则后续 MOVE 不会送到这里，面板就拖不动了。
            isClickable = true
        }

        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
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
            x = dp(16)
            y = dp(96)
            width = dp(256)
        }

        // 长按拖动：移动超过阈值才算拖动，避免把点击按钮误判成移动。
        var downX = 0f
        var downY = 0f
        var startX = 0
        var startY = 0
        var moved = false
        root.setOnTouchListener { _, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX
                    downY = event.rawY
                    startX = lp.x
                    startY = lp.y
                    moved = false
                    false
                }
                MotionEvent.ACTION_MOVE -> {
                    val dx = (event.rawX - downX).toInt()
                    val dy = (event.rawY - downY).toInt()
                    if (abs(dx) > 8 || abs(dy) > 8) {
                        moved = true
                        lp.x = startX + dx
                        lp.y = startY + dy
                        try {
                            windowManager.updateViewLayout(root, lp)
                        } catch (_: Exception) {
                        }
                        true
                    } else {
                        false
                    }
                }
                MotionEvent.ACTION_UP -> moved
                else -> false
            }
        }

        try {
            windowManager.addView(root, lp)
            panel = root
            statusView = status
            toggleView = toggle
            updatePanel()
        } catch (_: Exception) {
            // 部分 ROM 会在 addView 时直接抛异常。
            shutdown()
        }
    }

    private fun pillButton(
        label: String,
        color: Int,
        width: Int,
        onClick: () -> Unit,
    ): TextView = TextView(this).apply {
        text = label
        setTextColor(Color.WHITE)
        setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
        typeface = Typeface.DEFAULT_BOLD
        gravity = Gravity.CENTER
        minWidth = width
        minimumWidth = width
        setPadding(dp(7), 0, dp(7), 0)
        layoutParams = LinearLayout.LayoutParams(-2, dp(30)).apply {
            leftMargin = dp(4)
        }
        background = GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(9).toFloat()
        }
        isClickable = true
        setOnClickListener { onClick() }
    }

    // ---------- 取点 ----------

    /**
     * 铺一层全屏透明窗口，下一次点击就当作「要点的位置」。
     *
     * 用的是 `Resources.getSystem()` 的整屏尺寸——和
     * [AutoClickAccessibilityService] 换算百分比时完全一致，取到的点回放不会偏移。
     */
    @SuppressLint("ClickableViewAccessibility", "SetTextI18n")
    private fun startPick() {
        if (pickView != null) return
        if (!AutoClickAccessibilityService.isConnected) {
            statusView?.text = "请先开启无障碍服务"
            return
        }
        val hint = TextView(this).apply {
            text = "点屏幕上要点的位置 · 点这里取消"
            setTextColor(Color.WHITE)
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
            gravity = Gravity.CENTER
            setPadding(dp(14), dp(8), dp(14), dp(8))
            background = GradientDrawable().apply {
                setColor(Color.argb(235, 30, 33, 40))
                cornerRadius = dp(16).toFloat()
            }
            isClickable = true
            setOnClickListener { stopPick() }
        }
        val root = FrameLayout(this).apply {
            setBackgroundColor(Color.argb(28, 0, 0, 0))
            addView(
                hint,
                FrameLayout.LayoutParams(-2, -2).apply {
                    gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                    topMargin = dp(96)
                },
            )
            isClickable = true
        }
        root.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_UP -> {
                    val dm = Resources.getSystem().displayMetrics
                    val x = (event.rawX / dm.widthPixels * 100.0)
                        .coerceIn(0.0, 100.0)
                    val y = (event.rawY / dm.heightPixels * 100.0)
                        .coerceIn(0.0, 100.0)
                    stopPick()
                    addPickedPoint(x, y)
                    true
                }
                else -> true
            }
        }
        val lp = WindowManager.LayoutParams(
            WindowManager.LayoutParams.MATCH_PARENT,
            WindowManager.LayoutParams.MATCH_PARENT,
            overlayType(),
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply { gravity = Gravity.TOP or Gravity.START }
        try {
            windowManager.addView(root, lp)
            pickView = root
            statusView?.text = "点屏幕上要点的位置"
        } catch (_: Exception) {
            pickView = null
        }
    }

    private fun stopPick() {
        val view = pickView ?: return
        pickView = null
        try {
            windowManager.removeView(view)
        } catch (_: Exception) {
        }
        updatePanel()
    }

    /** 把取到的点追加成一个点击动作，并回传给 Flutter 存盘。 */
    private fun addPickedPoint(xPct: Double, yPct: Double) {
        config = config.copy(
            steps = config.steps + Step(
                type = "tap",
                x = xPct,
                y = yPct,
                x2 = 50.0,
                y2 = 50.0,
                durationMs = 80L,
            ),
        )
        stepIndex = 0
        round = 0
        statusView?.text = "已取点 ${xPct.toInt()}%, ${yPct.toInt()}%"
        try {
            channel?.invokeMethod(
                "onPointPicked",
                mapOf("x" to xPct, "y" to yPct),
            )
        } catch (_: Exception) {
        }
    }

    private fun overlayType(): Int = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
    } else {
        WindowManager.LayoutParams.TYPE_PHONE
    }

    // ---------- 运行 ----------

    private fun toggleRunning() {
        if (running) {
            stopExecution()
            return
        }
        if (!AutoClickAccessibilityService.isConnected) {
            statusView?.text = "请先开启无障碍服务"
            return
        }
        if (config.steps.isEmpty()) {
            statusView?.text = "请先添加动作"
            return
        }
        if (!AutoClickAccessibilityService.gesturesSupported &&
            config.steps.any { it.type == "tap" || it.type == "swipe" }
        ) {
            statusView?.text = "点击/滑动需要 Android 7.0+"
            return
        }
        running = true
        stepIndex = 0
        round = 0
        handler.removeCallbacks(tick)
        handler.post(tick)
        updatePanel()
    }

    private fun stopExecution() {
        running = false
        handler.removeCallbacks(tick)
        updatePanel()
    }

    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            val steps = config.steps
            if (steps.isEmpty()) {
                stopExecution()
                return
            }
            val step = steps[stepIndex]
            execute(step)
            stepIndex++
            if (stepIndex >= steps.size) {
                stepIndex = 0
                round++
                if (config.repeat in 1..round) {
                    stopExecution()
                    return
                }
            }
            val jitter = if (config.randomDelayMs > 0) {
                random.nextInt(config.randomDelayMs + 1).toLong()
            } else {
                0L
            }
            handler.postDelayed(
                this,
                (config.intervalMs + jitter + step.durationMs)
                    .coerceAtLeast(50L)
                    .coerceAtMost(120_000L),
            )
            updatePanel()
        }
    }

    private fun execute(step: Step) {
        when (step.type) {
            "tap" -> AutoClickAccessibilityService.tap(step.x, step.y, step.durationMs)
            "swipe" -> AutoClickAccessibilityService.swipe(
                step.x, step.y, step.x2, step.y2, step.durationMs
            )
            "back" -> AutoClickAccessibilityService.back()
            else -> Unit // wait：只靠上面的延时
        }
    }

    private fun updatePanel() {
        statusView?.text = when {
            !AutoClickAccessibilityService.isConnected -> "请先开启无障碍服务"
            running -> "${round + 1} 轮 · ${stepIndex + 1}/${config.steps.size} 步"
            else -> "待开始 · ${config.steps.size} 步"
        }
        toggleView?.text = if (running) "暂停" else "开始"
    }

    private fun shutdown() {
        stopExecution()
        stopPick()
        val view = panel
        if (view != null) {
            try {
                windowManager.removeView(view)
            } catch (_: Exception) {
            }
        }
        panel = null
        statusView = null
        toggleView = null
        if (instance == this) instance = null
        stopSelf()
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }
}
