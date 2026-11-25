package com.toolbox.app.overlay

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.RectF
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.hypot

/**
 * 悬浮窗收起后贴在屏幕边缘的小球。
 *
 * 轻点展开回原窗口，按住拖动可以换高度，松手由宿主吸附到最近的左边或右边。
 * 图形区分是哪个悬浮窗收起来的（搜题 / 键盘）。
 */
class OverlayBallView(context: Context) : View(context) {

    enum class Glyph { SEARCH, KEYBOARD }

    interface Host {
        /** 拖动：屏幕像素增量。 */
        fun onBallDragBy(dx: Float, dy: Float)

        /** 松手：宿主吸附到边缘并落盘。 */
        fun onBallReleased()

        /** 轻点：展开原来的悬浮窗。 */
        fun onBallTap()
    }

    var host: Host? = null

    var glyph: Glyph = Glyph.SEARCH
        set(value) {
            if (field == value) return
            field = value
            invalidate()
        }

    private val density = resources.displayMetrics.density

    private fun dp(v: Float) = v * density

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private val sizePx = dp(42f)

    private val circlePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xF22B2B31.toInt() }
    private val ringPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1f)
        color = 0x33FFFFFF
    }
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xE6FFFFFF.toInt()
        style = Paint.Style.STROKE
        strokeWidth = dp(1.8f)
        strokeCap = Paint.Cap.ROUND
    }
    private val solidPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xE6FFFFFF.toInt()
        style = Paint.Style.FILL
    }

    private var downRawX = 0f
    private var downRawY = 0f
    private var lastRawX = 0f
    private var lastRawY = 0f
    private var dragging = false
    private var pressed = false

    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val s = sizePx.toInt()
        setMeasuredDimension(s, s)
    }

    override fun onDraw(canvas: Canvas) {
        val cx = width / 2f
        val cy = height / 2f
        val r = minOf(width, height) / 2f - dp(1f)
        canvas.drawCircle(cx, cy, r, circlePaint)
        canvas.drawCircle(cx, cy, r, ringPaint)

        val lit = if (pressed) 0xFFFFFFFF.toInt() else 0xE6FFFFFF.toInt()
        val icon = Paint(iconPaint).apply { color = lit }
        val solid = Paint(solidPaint).apply { color = lit }
        when (glyph) {
            Glyph.SEARCH -> {
                canvas.drawCircle(cx - dp(0.8f), cy - dp(1.4f), dp(5.4f), icon)
                canvas.drawLine(
                    cx + dp(3.4f), cy + dp(2.8f),
                    cx + dp(7.2f), cy + dp(6.6f), icon,
                )
            }
            Glyph.KEYBOARD -> {
                val w = dp(14.5f)
                val h = dp(9.5f)
                canvas.drawRoundRect(
                    RectF(cx - w / 2f, cy - h / 2f, cx + w / 2f, cy + h / 2f),
                    dp(2.4f),
                    dp(2.4f),
                    icon,
                )
                for (i in -1..1) {
                    canvas.drawCircle(cx + i * dp(3.5f), cy - dp(1.6f), dp(0.9f), solid)
                }
                canvas.drawRect(
                    cx - dp(2.8f),
                    cy + dp(2.2f),
                    cx + dp(2.8f),
                    cy + dp(3.4f),
                    solid,
                )
            }
        }
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                pressed = true
                dragging = false
                downRawX = event.rawX
                downRawY = event.rawY
                lastRawX = event.rawX
                lastRawY = event.rawY
                invalidate()
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = event.rawX - lastRawX
                val dy = event.rawY - lastRawY
                lastRawX = event.rawX
                lastRawY = event.rawY
                if (!dragging &&
                    hypot(event.rawX - downRawX, event.rawY - downRawY) > touchSlop
                ) {
                    dragging = true
                }
                if (dragging && (dx != 0f || dy != 0f)) host?.onBallDragBy(dx, dy)
                return true
            }
            MotionEvent.ACTION_UP -> {
                val dragged = dragging
                pressed = false
                dragging = false
                invalidate()
                if (dragged) {
                    host?.onBallReleased()
                } else {
                    host?.onBallTap()
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                pressed = false
                dragging = false
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    override fun onDetachedFromWindow() {
        host = null
        super.onDetachedFromWindow()
    }
}
