package com.toolbox.app.smartsearch

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import com.toolbox.app.overlay.OverlayGlyphs
import com.toolbox.app.overlay.OverlayPalette
import kotlin.math.abs
import kotlin.math.min

/**
 * 智能搜题的结果悬浮窗。
 *
 * 顶部：左「框选」→ 切到框选窗，中「答案」，右「×」关闭；顶部空白处可拖动。
 * 正文：题干 + 选项，正确选项用绿色。
 *
 * 底部不再留一条空工具带：左下角收起、右下角缩放两个小把手浮在正文底部两角，
 * 正文可以一直画到窗口底部，同一屏能多放两行。
 * 缩放把手放右下角，往右下拖就是变大，与「左上角固定、宽高增加」的逻辑一致；
 * 横拖只改宽度（正文按新宽度重排），竖拖只改高度（拉矮时正文被裁），
 * 斜着拖就同时改两者。
 *
 * 正文放不下时可以上下拖着看：拖动正文区域滚动，右侧一条细指示条标出当前位置。
 */
class SmartResultView(context: Context) : View(context) {

    interface Host {
        fun onDragBy(dx: Float, dy: Float)
        fun onClose()
        fun onPickRegion()

        /** 左下角的收起标记：把窗口收成边缘小球。 */
        fun onMinimize()

        /** 窗口尺寸增量（像素）。右下角缩放把手：往右下拖为正，某一轴没动就传 0。 */
        fun onResizeBy(dw: Float, dh: Float)

        /** 缩放结束（松手），宿主在这里落盘，拖动过程中不写 SharedPreferences。 */
        fun onResizeFinished()

        /** 正文左右滑动切换候选：delta 为 +1 看下一条、-1 看上一条。 */
        fun onSwipeResult(delta: Int)
    }

    /** 一次搜索的可展示结果。 */
    data class Payload(
        val summary: String,
        val stem: String,
        val options: List<Pair<String, Boolean>>,
        val hint: String,
    )

    var host: Host? = null

    /** 手动拖出来的窗口宽/高（dp；0 表示跟随内容自适应）。 */
    var preferredWidthDp: Float = 0f
        private set
    var preferredHeightDp: Float = 0f
        private set

    private val density = resources.displayMetrics.density
    private val scaled = resources.displayMetrics.scaledDensity

    private fun dp(v: Float) = v * density

    private fun sp(v: Float) = v * scaled

    private val headerH get() = dp(34f)
    private val padH get() = dp(10f)
    private val cardPad get() = dp(8f)
    private val trayBox get() = dp(26f)

    /** 把手贴底时留的一点边距；正文不再为工具带让出一整条高度。 */
    private val handleInset get() = dp(6f)

    /** 当前主题配色；setTheme 时整表替换并重设所有画笔颜色。 */
    private var colors = OverlayPalette.of(null)

    private val panelPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1.6f)
        strokeCap = Paint.Cap.ROUND
    }

    private val summaryPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(14f)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }
    private val busyPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(13f)
        textAlign = Paint.Align.CENTER
    }
    private val stemPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(14f)
        typeface = Typeface.DEFAULT_BOLD
    }
    private val optionPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = sp(13f) }
    private val correctPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(13f)
        typeface = Typeface.DEFAULT_BOLD
    }
    private val hintPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = sp(13f) }

    init {
        applyColors()
    }

    /** 由宿主下发的主题切换（dark / light / transparent）。 */
    fun setTheme(theme: String?) {
        val next = OverlayPalette.of(theme)
        if (next === colors) return
        colors = next
        applyColors()
        requestLayout()
        invalidate()
    }

    private fun applyColors() {
        panelPaint.color = colors.panelBg
        iconPaint.color = colors.icon
        summaryPaint.color = colors.smartAccent
        busyPaint.color = colors.hintText
        stemPaint.color = colors.stemText
        optionPaint.color = colors.optionText
        correctPaint.color = colors.smartAccent
        hintPaint.color = colors.hintText
        // 透明底色上给文字加描边，保证压在任意 App 上都清晰。
        for (p in arrayOf(
            summaryPaint, busyPaint, stemPaint, optionPaint, correctPaint, hintPaint,
        )) {
            p.setShadowLayer(
                if (colors.textShadow == Color.TRANSPARENT) 0f else dp(1.4f),
                0f, 0f, colors.textShadow,
            )
        }
    }

    private var summary = ""
    private var statusText = ""
    private var busy = false
    private var stemLayout: StaticLayout? = null
    private var optionLayouts = ArrayList<StaticLayout>()
    private var hintLayout: StaticLayout? = null
    private var bodyHeight = 0f

    /** 正文滚动偏移；内容比窗口高时才有非零值。 */
    private var scrollY = 0f

    /** 当前滚动上限（内容高 - 可视高）。 */
    private var maxScroll = 0f
    private var scrollCandidate = false
    private var scrolling = false
    private var scrollAccum = 0f
    private var scrollLastRawY = 0f
    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()

    /** 正文按下的手势：横向滑动切换候选，纵向滚动看长题。 */
    private var bodyTouch = false
    private var swiping = false
    private var swipeAccum = 0f
    private var swipeLastRawX = 0f
    private var swipeStartY = 0f

    private val pickRect = RectF()
    private val closeRect = RectF()
    private val dragRect = RectF()
    private val trayRect = RectF()
    private val minRect = RectF()

    private var pressedId: String? = null
    private var dragging = false
    private var resizing = false
    private var lastRawX = 0f
    private var lastRawY = 0f

    // ---------- 对外 ----------
    fun show(payload: Payload) {
        // 内容一模一样就别再 requestLayout：窗口重新测量会让人看着像闪一下。
        if (!busy &&
            summary == payload.summary &&
            stem == payload.stem &&
            options == payload.options &&
            hint == payload.hint
        ) {
            return
        }
        summary = payload.summary
        statusText = ""
        busy = false
        scrollY = 0f
        stemLayout = null
        optionLayouts = ArrayList()
        hintLayout = null
        stem = payload.stem
        options = payload.options
        hint = payload.hint
        requestLayout()
        invalidate()
    }

    fun showBusy(text: String) {
        if (busy && statusText == text) return
        summary = text
        statusText = text
        busy = true
        scrollY = 0f
        stemLayout = null
        optionLayouts = ArrayList()
        hintLayout = null
        stem = ""
        options = emptyList()
        hint = ""
        requestLayout()
        invalidate()
    }

    /** 恢复上次拖出来的窗口大小；传 0 表示跟随内容。 */
    fun setPreferredSize(widthDp: Float, heightDp: Float) {
        val w = if (widthDp > 0f) widthDp else 0f
        val h = if (heightDp > 0f) heightDp else 0f
        if (w == preferredWidthDp && h == preferredHeightDp) return
        preferredWidthDp = w
        preferredHeightDp = h
        requestLayout()
        invalidate()
    }

    /**
     * 按像素增量改窗口大小，宽高互不牵连。
     *
     * 第一次拖动时把手动值锚定到当前实际尺寸，避免窗口突然跳一下。
     */
    fun resizeBy(dwPx: Float, dhPx: Float) {
        val maxW = resources.displayMetrics.widthPixels - density * 20f
        val maxH = resources.displayMetrics.heightPixels - density * 60f
        var changed = false
        if (dwPx != 0f) {
            val current = if (preferredWidthDp > 0f) dp(preferredWidthDp) else width.toFloat()
            val next = (current + dwPx).coerceIn(dp(170f), maxW)
            val nextDp = next / density
            if (nextDp != preferredWidthDp) {
                preferredWidthDp = nextDp
                changed = true
            }
        }
        if (dhPx != 0f) {
            val natural = lastNaturalHeight.takeIf { it > 0f } ?: height.toFloat()
            val current = if (preferredHeightDp > 0f) dp(preferredHeightDp) else natural
            val next = (current + dhPx).coerceIn(dp(96f), maxH)
            val nextDp = next / density
            if (nextDp != preferredHeightDp) {
                preferredHeightDp = nextDp
                changed = true
            }
        }
        if (changed) {
            requestLayout()
            invalidate()
        }
    }

    private var stem = ""
    private var options: List<Pair<String, Boolean>> = emptyList()
    private var hint = ""

    /** 内容自然需要的高度（不含手动拉高的部分）。 */
    private var lastNaturalHeight = 0f

    // ---------- 测量 ----------
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val metrics = resources.displayMetrics
        val maxW = metrics.widthPixels - density * 20f
        val minW = min(dp(170f), maxW)
        val wantedW = if (preferredWidthDp > 0f) dp(preferredWidthDp) else min(dp(300f), maxW)
        val w = wantedW.coerceIn(minW, maxW).toInt()
        val inner = (w - padH * 2 - cardPad * 2).toInt().coerceAtLeast(dp(80f).toInt())

        pickRect.set(0f, 0f, dp(40f), headerH)
        closeRect.set(w - dp(40f), 0f, w.toFloat(), headerH)
        dragRect.set(pickRect.right, 0f, closeRect.left, headerH)

        if (busy) {
            stemLayout = null
            optionLayouts = ArrayList()
            hintLayout = null
            bodyHeight = dp(20f)
        } else {
            val stemText = stem
            stemLayout = if (stemText.isNotEmpty()) {
                layout(stemText, stemPaint, inner, 12)
            } else {
                null
            }
            optionLayouts = ArrayList(options.size)
            for ((text, correct) in options) {
                optionLayouts.add(layout(text, if (correct) correctPaint else optionPaint, inner, 6))
            }
            hintLayout = if (hint.isNotEmpty()) layout(hint, hintPaint, inner, 8) else null
            var h = 0f
            stemLayout?.let { h += it.height + dp(5f) }
            for (l in optionLayouts) h += l.height + dp(2f)
            hintLayout?.let { h += it.height }
            bodyHeight = h.coerceAtLeast(dp(20f))
        }

        // 底部两个把手浮在正文上，正文末尾要给它们留出 32dp，否则最后一行
        // 会被左下收起 / 右下缩放的小圆底压住（收起从右下挪到左下后才暴露）。
        val bottomClearance = trayBox + handleInset
        val natural = headerH + cardPad * 2 + bodyHeight + bottomClearance
        lastNaturalHeight = natural
        val maxH = metrics.heightPixels - density * 60f
        val totalH = if (preferredHeightDp > 0f) {
            // 手动高度：允许矮于内容（正文被裁），也允许拉高留白。
            dp(preferredHeightDp).coerceIn(min(dp(96f), maxH), maxH)
        } else {
            min(natural, maxH)
        }
        setMeasuredDimension(w, totalH.toInt())

        // 正文比可视区高就允许滚动；窗口被拉高/拉矮后也要把偏移夹回范围内。
        // 内容高度带上底部的把手留白，滚到底时最后一行也能停在把手上面。
        val viewport = (totalH - headerH).coerceAtLeast(0f)
        val contentH = cardPad * 2 + bodyHeight + bottomClearance
        maxScroll = (contentH - viewport).coerceAtLeast(0f)
        scrollY = scrollY.coerceIn(0f, maxScroll)

        // 两个把手浮在正文底部两角，只占 26dp 见方，不再吃掉一整行高度。
        // 左下收起、右下缩放：缩放把手放右下，往右下拖变大，不能放左下
        // （那会要求窗口左边缘跟着移动，和 resizeBy 固定左上角的逻辑冲突）。
        val handleBottom = totalH - handleInset
        minRect.set(
            padH - dp(4f),
            handleBottom - trayBox,
            padH - dp(4f) + trayBox,
            handleBottom,
        )
        trayRect.set(
            w - padH - trayBox + dp(4f),
            handleBottom - trayBox,
            w - padH + dp(4f),
            handleBottom,
        )
    }

    private fun layout(text: String, paint: TextPaint, width: Int, maxLines: Int): StaticLayout =
        StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .setLineSpacing(0f, 1.14f)
            .setMaxLines(maxLines)
            .setEllipsize(TextUtils.TruncateAt.END)
            .build()

    // ---------- 绘制 ----------
    override fun onDraw(canvas: Canvas) {
        val panel = RectF(0f, 0f, width.toFloat(), height.toFloat())
        canvas.drawRoundRect(panel, dp(14f), dp(14f), panelPaint)

        drawHeader(canvas)
        val bodyTop = headerH
        val bodyBottom = height.toFloat()
        if (bodyBottom > bodyTop) {
            // 手动把窗口压矮时，正文只画能放下的部分，不越过底部托带。
            canvas.save()
            canvas.clipRect(0f, bodyTop, width.toFloat(), bodyBottom)
            if (scrollY != 0f) canvas.translate(0f, -scrollY)
            drawBody(canvas)
            canvas.restore()
            if (maxScroll > 0f) drawScrollBar(canvas, bodyTop, bodyBottom)
        }
        drawTray(canvas)
        drawMinimize(canvas)
    }

    /** 左下角：双下箭头，点一下缩成屏幕边上的小球。 */
    private fun drawMinimize(canvas: Canvas) {
        // 半透明圆底：正文可能画到这下面，垫一层才不会和字形糊在一起。
        canvas.drawCircle(
            minRect.centerX(),
            minRect.centerY(),
            minRect.width() / 2f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (pressedId == "min") colors.handleBgPressed else colors.handleBg
            },
        )
        val p = Paint(iconPaint).apply {
            color = if (pressedId == "min") colors.iconPressed else colors.icon
            strokeWidth = dp(1.8f)
        }
        OverlayGlyphs.drawCollapse(
            canvas,
            minRect.centerX(),
            minRect.centerY(),
            density,
            p,
        )
    }

    /** 右侧细指示条：只在正文放不下时出现，标出当前看到的是整段的哪一段。 */
    private fun drawScrollBar(canvas: Canvas, top: Float, bottom: Float) {
        val viewport = bottom - top
        if (viewport <= 0f || maxScroll <= 0f) return
        // 右下角是缩放把手，指示条别画到它下面去。
        val trackH = viewport - dp(6f) - trayBox
        if (trackH < dp(14f)) return
        val thumbH = (trackH * viewport / (viewport + maxScroll)).coerceIn(dp(14f), trackH)
        val t = (scrollY / maxScroll).coerceIn(0f, 1f)
        val y = top + dp(3f) + (trackH - thumbH) * t
        val cx = width - dp(5f)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = colors.scrollBar }
        canvas.drawRoundRect(
            RectF(cx - dp(1.4f), y, cx + dp(1.4f), y + thumbH),
            dp(1.4f),
            dp(1.4f),
            p,
        )
    }

    private fun drawHeader(canvas: Canvas) {
        // 左：框选按钮（四角取景框）
        val pcx = pickRect.centerX()
        val pcy = pickRect.centerY()
        val r = dp(7.8f)
        val arm = dp(3.8f)
        val p = Paint(iconPaint).apply {
            color = if (pressedId == "pick") colors.iconPressed else colors.icon
        }
        canvas.drawLine(pcx - r, pcy - r + arm, pcx - r, pcy - r, p)
        canvas.drawLine(pcx - r, pcy - r, pcx - r + arm, pcy - r, p)
        canvas.drawLine(pcx + r - arm, pcy - r, pcx + r, pcy - r, p)
        canvas.drawLine(pcx + r, pcy - r, pcx + r, pcy - r + arm, p)
        canvas.drawLine(pcx - r, pcy + r - arm, pcx - r, pcy + r, p)
        canvas.drawLine(pcx - r, pcy + r, pcx - r + arm, pcy + r, p)
        canvas.drawLine(pcx + r - arm, pcy + r, pcx + r, pcy + r, p)
        canvas.drawLine(pcx + r, pcy + r - arm, pcx + r, pcy + r, p)

        // 中：简要答案
        val avail = dragRect.width() - dp(8f)
        if (summary.isNotEmpty()) {
            val paint = if (busy) busyPaint else summaryPaint
            val text = TextUtils.ellipsize(summary, paint, avail, TextUtils.TruncateAt.END)
            val baseline = headerH / 2f - (paint.descent() + paint.ascent()) / 2f
            canvas.drawText(text, 0, text.length, dragRect.centerX(), baseline, paint)
        }

        // 右：关闭
        val ccx = closeRect.centerX()
        val ccy = closeRect.centerY()
        val cr = dp(6.2f)
        val c = Paint(iconPaint).apply {
            color = if (pressedId == "close") colors.iconPressed else colors.icon
        }
        canvas.drawLine(ccx - cr, ccy - cr, ccx + cr, ccy + cr, c)
        canvas.drawLine(ccx - cr, ccy + cr, ccx + cr, ccy - cr, c)
    }

    private fun drawBody(canvas: Canvas) {
        val left = padH + cardPad
        val innerW = (width - (padH + cardPad) * 2).toInt()
        var y = headerH + cardPad
        if (busy) {
            val text = statusText.ifEmpty { "正在识别框选区域…" }
            val l = layout(text, hintPaint, innerW, 2)
            canvas.save()
            canvas.translate(left, y + dp(6f))
            l.draw(canvas)
            canvas.restore()
            return
        }
        stemLayout?.let {
            canvas.save()
            canvas.translate(left, y)
            it.draw(canvas)
            canvas.restore()
            y += it.height + dp(5f)
        }
        for (l in optionLayouts) {
            canvas.save()
            canvas.translate(left, y)
            l.draw(canvas)
            canvas.restore()
            y += l.height + dp(2f)
        }
        hintLayout?.let {
            canvas.save()
            canvas.translate(left, y)
            it.draw(canvas)
            canvas.restore()
        }
    }

    /** 右下角的缩放把手：斜向双箭头，拖它改宽高。 */
    private fun drawTray(canvas: Canvas) {
        val r = trayRect
        canvas.drawCircle(
            r.centerX(),
            r.centerY(),
            r.width() / 2f,
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = if (pressedId == "tray") colors.handleBgPressed else colors.handleBg
            },
        )
        val p = Paint(iconPaint).apply {
            color = if (pressedId == "tray") colors.iconPressed else colors.icon
            strokeWidth = dp(1.8f)
        }
        OverlayGlyphs.drawResize(canvas, r.centerX(), r.centerY(), density, p)
    }

    // ---------- 触摸 ----------
    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressedId = hitAt(event.x, event.y)
                when (pressedId) {
                    "drag" -> {
                        dragging = true
                        lastRawX = event.rawX
                        lastRawY = event.rawY
                    }
                    "tray" -> {
                        resizing = true
                        lastRawX = event.rawX
                        lastRawY = event.rawY
                    }
                    null -> {
                        // 正文空白处按下：横向可能是切换候选，纵向可能是上下翻看长题。
                        bodyTouch = inBody(event.y)
                        if (bodyTouch) {
                            scrollCandidate = maxScroll > 0f
                            scrolling = false
                            scrollAccum = 0f
                            scrollLastRawY = event.rawY
                            swiping = false
                            swipeAccum = 0f
                            swipeLastRawX = event.rawX
                            swipeStartY = event.y
                        }
                    }
                }
                invalidate()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (dragging) {
                    val dx = event.rawX - lastRawX
                    val dy = event.rawY - lastRawY
                    lastRawX = event.rawX
                    lastRawY = event.rawY
                    if (dx != 0f || dy != 0f) host?.onDragBy(dx, dy)
                } else if (resizing) {
                    // 宽高各跟随手指：横拖只变宽、竖拖只变高、斜拖同时变，比例自由。
                    val dx = event.rawX - lastRawX
                    val dy = event.rawY - lastRawY
                    lastRawX = event.rawX
                    lastRawY = event.rawY
                    if (dx != 0f || dy != 0f) host?.onResizeBy(dx, dy)
                } else if (bodyTouch) {
                    val dx = event.rawX - swipeLastRawX
                    val dy = event.y - swipeStartY
                    swipeLastRawX = event.rawX
                    swipeAccum += dx
                    // 先定主轴：横向明显更大就切结果，竖向明显更大就滚动正文。
                    if (!swiping && !scrolling) {
                        if (abs(swipeAccum) > touchSlop && abs(swipeAccum) > abs(dy)) {
                            swiping = true
                        } else if (scrollCandidate && abs(dy) > touchSlop &&
                            abs(dy) > abs(swipeAccum)
                        ) {
                            scrolling = true
                            scrollLastRawY = event.rawY
                        }
                    }
                    if (scrolling) {
                        val ddy = event.rawY - scrollLastRawY
                        scrollLastRawY = event.rawY
                        applyScroll(-ddy)
                    }
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                val moved = dragging || resizing || scrolling || swiping
                val resized = resizing
                val swiped = swiping
                val swipedBy = swipeAccum
                dragging = false
                resizing = false
                scrollCandidate = false
                scrolling = false
                scrollAccum = 0f
                bodyTouch = false
                swiping = false
                swipeAccum = 0f
                val pressed = pressedId
                pressedId = null
                invalidate()
                if (resized) host?.onResizeFinished()
                if (!moved && pressed != null && pressed == hitAt(event.x, event.y)) {
                    when (pressed) {
                        "pick" -> host?.onPickRegion()
                        "close" -> host?.onClose()
                        "min" -> host?.onMinimize()
                    }
                } else if (swiped) {
                    // 左滑看下一条、右滑看上一条。
                    if (swipedBy <= -dp(36f)) {
                        host?.onSwipeResult(1)
                    } else if (swipedBy >= dp(36f)) {
                        host?.onSwipeResult(-1)
                    }
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                val resized = resizing
                dragging = false
                resizing = false
                scrollCandidate = false
                scrolling = false
                scrollAccum = 0f
                bodyTouch = false
                swiping = false
                swipeAccum = 0f
                pressedId = null
                invalidate()
                if (resized) host?.onResizeFinished()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    /** 正文可视区（不含顶部工具条）。 */
    private fun inBody(y: Float): Boolean = y > headerH && y < height

    private fun applyScroll(delta: Float) {
        if (maxScroll <= 0f) return
        val next = (scrollY + delta).coerceIn(0f, maxScroll)
        if (next == scrollY) return
        scrollY = next
        invalidate()
    }

    private fun hitAt(x: Float, y: Float): String? = when {
        trayRect.contains(x, y) -> "tray"
        minRect.contains(x, y) -> "min"
        pickRect.contains(x, y) -> "pick"
        closeRect.contains(x, y) -> "close"
        dragRect.contains(x, y) -> "drag"
        else -> null
    }

    override fun onDetachedFromWindow() {
        host = null
        super.onDetachedFromWindow()
    }
}
