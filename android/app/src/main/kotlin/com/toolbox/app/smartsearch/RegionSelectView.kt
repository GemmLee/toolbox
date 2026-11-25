package com.toolbox.app.smartsearch

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 智能搜题的框选窗。
 *
 * 上方是操作条（左边返回、中间提示可拖动），下方绿框就是 OCR 取词区域，
 * 右下角托盘拖动可改框的大小。窗口尺寸即选区尺寸，所以这里不用缩放系数。
 */
class RegionSelectView(context: Context) : View(context) {

    interface Host {
        fun onMoveBy(dx: Float, dy: Float)
        fun onResizeTo(width: Int, height: Int)
        fun onBack()
    }

    var host: Host? = null

    private val density = resources.displayMetrics.density
    private fun dp(v: Float) = v * density

    private val headerH = dp(38f)
    private val frameStroke = dp(2.5f)

    /** 右下角缩放托盘：44dp 的方块 + 40dp 的可见底盘，手指够得着，浅色题目上也看得清。 */
    private val trayBox = dp(40f)
    private val trayMargin = dp(12f)

    private val headerPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xB31FA96B.toInt() }
    private val frameStrokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF34C759.toInt()
        style = Paint.Style.STROKE
        strokeWidth = frameStroke
    }
    private val frameFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0x1434C759 }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        style = Paint.Style.STROKE
        strokeWidth = dp(2f)
        strokeCap = Paint.Cap.ROUND
    }
    private val hintPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFFFFFFFF.toInt()
        textSize = (13f * resources.displayMetrics.scaledDensity)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }

    /** 托盘底盘：深色实底（不是半透明白），叠在白色题目上也够对比。 */
    private val trayBgPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xF2238A4E.toInt() }
    private val trayBgPressedPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xF21C6E3F.toInt() }
    private val trayRingPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xCCFFFFFF.toInt()
        style = Paint.Style.STROKE
        strokeWidth = dp(1.5f)
    }

    private val backRect = RectF()
    private val dragRect = RectF()
    private val trayRect = RectF()

    /** 托盘的可点范围：比可见方块再宽一点，手指偏一点也能拖。 */
    private val trayHitRect = RectF()
    private val frameRect = RectF()

    private var pressedId: String? = null
    private var dragging = false
    private var resizing = false
    private var lastRawX = 0f
    private var lastRawY = 0f
    private var startW = 0
    private var startH = 0

    /** 取词区域在窗口内的垂直起点（操作条高度）。 */
    fun regionTopInWindow(): Int = headerH.roundToInt()

    /** 取词区域在窗口内的左边距（避开描边与圆角）。 */
    fun regionInset(): Int = max(dp(3f).roundToInt(), (frameStroke).roundToInt())

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val w = MeasureSpec.getSize(widthMeasureSpec)
        val h = MeasureSpec.getSize(heightMeasureSpec)
        setMeasuredDimension(w, h)
        backRect.set(0f, 0f, dp(46f), headerH)
        dragRect.set(backRect.right, 0f, w - dp(8f), headerH)
        frameRect.set(0f, headerH, w.toFloat(), h.toFloat())
        trayRect.set(
            w - trayMargin - trayBox,
            h - trayMargin - trayBox,
            w - trayMargin,
            h - trayMargin,
        )
        trayHitRect.set(
            trayRect.left - dp(6f),
            trayRect.top - dp(6f),
            trayRect.right + dp(6f),
            trayRect.bottom + dp(6f),
        )
    }

    override fun onDraw(canvas: Canvas) {
        // 操作条
        val header = RectF(0f, 0f, width.toFloat(), headerH + dp(4f))
        canvas.drawRoundRect(header, dp(10f), dp(10f), headerPaint)

        val hint = TextUtils.ellipsize(
            "请选取题目选项区域", hintPaint,
            dragRect.width() - dp(12f), TextUtils.TruncateAt.END,
        )
        val baseline = headerH / 2f - (hintPaint.descent() + hintPaint.ascent()) / 2f
        canvas.drawText(hint, 0, hint.length, dragRect.centerX(), baseline, hintPaint)

        // 返回箭头
        val bx = dp(20f)
        val by = headerH / 2f
        val r = dp(7.5f)
        val p = Paint(iconPaint).apply {
            color = if (pressedId == "back") 0xCCFFFFFF.toInt() else 0xFFFFFFFF.toInt()
        }
        canvas.drawLine(bx - r * 0.4f, by, bx + r * 0.6f, by, p)
        val head = Path()
        head.moveTo(bx - r * 0.4f, by)
        head.lineTo(bx + r * 0.1f, by - r * 0.55f)
        head.moveTo(bx - r * 0.4f, by)
        head.lineTo(bx + r * 0.1f, by + r * 0.55f)
        canvas.drawPath(head, p)

        // 选区
        canvas.drawRoundRect(frameRect, dp(10f), dp(10f), frameFillPaint)
        canvas.drawRoundRect(frameRect, dp(10f), dp(10f), frameStrokePaint)

        // 右下角缩放托盘：一块深绿底盘 + 白色双向斜箭头，压在浅色题目上也看得清。
        canvas.drawRoundRect(
            trayRect,
            dp(11f),
            dp(11f),
            if (pressedId == "tray") trayBgPressedPaint else trayBgPaint,
        )
        canvas.drawRoundRect(trayRect, dp(11f), dp(11f), trayRingPaint)
        val t = Paint(iconPaint).apply {
            color = 0xFFFFFFFF.toInt()
            strokeWidth = dp(2.4f)
            strokeCap = Paint.Cap.ROUND
        }
        val inner = dp(12f)
        val x0 = trayRect.left + inner
        val y0 = trayRect.bottom - inner
        val x1 = trayRect.right - inner
        val y1 = trayRect.top + inner
        canvas.drawLine(x0, y0, x1, y1, t)
        // 两端各一个箭头，读起来就是「沿对角拖动能改大小」。
        val headLen = dp(6.5f)
        val arrow = Path()
        arrow.moveTo(x1, y1)
        arrow.lineTo(x1 - headLen, y1)
        arrow.moveTo(x1, y1)
        arrow.lineTo(x1, y1 + headLen)
        arrow.moveTo(x0, y0)
        arrow.lineTo(x0 + headLen, y0)
        arrow.moveTo(x0, y0)
        arrow.lineTo(x0, y0 - headLen)
        canvas.drawPath(arrow, t)
    }

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
                        startW = width
                        startH = height
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
                    if (dx != 0f || dy != 0f) host?.onMoveBy(dx, dy)
                } else if (resizing) {
                    val dw = (event.rawX - lastRawX).roundToInt()
                    val dh = (event.rawY - lastRawY).roundToInt()
                    host?.onResizeTo(startW + dw, startH + dh)
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                val moved = dragging || resizing
                dragging = false
                resizing = false
                val pressed = pressedId
                pressedId = null
                invalidate()
                if (!moved && pressed == "back") host?.onBack()
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                dragging = false
                resizing = false
                pressedId = null
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun hitAt(x: Float, y: Float): String? = when {
        trayHitRect.contains(x, y) -> "tray"
        backRect.contains(x, y) -> "back"
        dragRect.contains(x, y) -> "drag"
        else -> null
    }

    override fun onDetachedFromWindow() {
        host = null
        super.onDetachedFromWindow()
    }
}
