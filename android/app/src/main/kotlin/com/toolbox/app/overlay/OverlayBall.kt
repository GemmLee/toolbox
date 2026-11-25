package com.toolbox.app.overlay

import android.content.Context
import android.content.SharedPreferences
import android.graphics.PixelFormat
import android.os.Build
import android.view.Gravity
import android.view.WindowManager
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * 「小球」这个独立悬浮窗的宿主。
 *
 * 悬浮窗收起时用它顶替：贴左边或右边、纵向停在收起前窗口所在的高度；
 * 拖动能换高度，松手吸附到最近的一条边。位置（哪条边 + 纵向坐标）落盘，
 * 下次收起还在原地，不会每次乱跳。
 *
 * 窗口类型/flag 与主悬浮窗保持一致，宿主服务只需调用 [show] / [hide]。
 */
class OverlayBall(
    private val context: Context,
    private val wm: WindowManager,
    private val prefs: SharedPreferences,
    private val keySide: String,
    private val keyY: String,
) {

    companion object {
        const val LEFT = 0
        const val RIGHT = 1

        private const val BALL_DP = 42f
    }

    /** 轻点小球：展开原来的悬浮窗。 */
    var onTap: (() -> Unit)? = null

    private var view: OverlayBallView? = null
    private var lp: WindowManager.LayoutParams? = null
    private var side = RIGHT

    val isShowing: Boolean get() = view != null

    private val density = context.resources.displayMetrics.density

    private fun dp(v: Float) = (v * density).roundToInt()

    /**
     * 显示小球；[nearCenterX] / [nearCenterY] 是收起前窗口的中心，用来就近选边与定高度。
     *
     * 返回 false 表示系统没让挂上（个别 ROM 会拦），调用方据此决定要不要收起原窗口。
     */
    fun show(glyph: OverlayBallView.Glyph, nearCenterX: Int, nearCenterY: Int): Boolean {
        hide()
        val v = OverlayBallView(context).apply {
            this.glyph = glyph
            host = object : OverlayBallView.Host {
                override fun onBallDragBy(dx: Float, dy: Float) = dragBy(dx, dy)
                override fun onBallReleased() = snapToEdge()
                override fun onBallTap() {
                    onTap?.invoke()
                }
            }
        }
        val size = dp(BALL_DP)
        val p = baseParams(size)
        val savedSide = prefs.getInt(keySide, -1)
        side = when {
            savedSide == LEFT || savedSide == RIGHT -> savedSide
            nearCenterX < screenW() / 2 -> LEFT
            else -> RIGHT
        }
        val savedY = prefs.getInt(keyY, -1)
        p.x = if (side == RIGHT) screenW() - size else 0
        p.y = clampY(if (savedY >= 0) savedY else nearCenterY - size / 2, size)
        try {
            wm.addView(v, p)
        } catch (_: Exception) {
            return false
        }
        view = v
        lp = p
        return true
    }

    fun hide() {
        val v = view ?: return
        view = null
        lp = null
        try {
            wm.removeView(v)
        } catch (_: Exception) {
        }
    }

    private fun dragBy(dx: Float, dy: Float) {
        val v = view ?: return
        val p = lp ?: return
        p.x = (p.x + dx).roundToInt().coerceIn(0, max(0, screenW() - v.width))
        p.y = clampY((p.y + dy).roundToInt(), v.height)
        safeUpdate(v, p)
    }

    /** 松手吸附到最近的一条边，并记住高度。 */
    private fun snapToEdge() {
        val v = view ?: return
        val p = lp ?: return
        side = if (p.x + v.width / 2 < screenW() / 2) LEFT else RIGHT
        p.x = if (side == RIGHT) screenW() - v.width else 0
        p.y = clampY(p.y, v.height)
        safeUpdate(v, p)
        prefs.edit().putInt(keySide, side).putInt(keyY, p.y).apply()
    }

    private fun safeUpdate(view: OverlayBallView, p: WindowManager.LayoutParams) {
        try {
            wm.updateViewLayout(view, p)
        } catch (_: Exception) {
        }
    }

    private fun baseParams(size: Int): WindowManager.LayoutParams {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
        } else {
            @Suppress("DEPRECATION")
            WindowManager.LayoutParams.TYPE_PHONE
        }
        return WindowManager.LayoutParams(
            size,
            size,
            type,
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
        }
    }

    private fun clampY(y: Int, size: Int): Int {
        val top = statusBarHeight()
        val bottom = screenH() - navBarHeight() - size
        return y.coerceIn(top, max(top, bottom))
    }

    private fun screenW(): Int = context.resources.displayMetrics.widthPixels

    private fun screenH(): Int = context.resources.displayMetrics.heightPixels

    private fun statusBarHeight(): Int = systemRes("status_bar_height", 0)

    private fun navBarHeight(): Int = systemRes("navigation_bar_height", 0)

    private fun systemRes(name: String, fallback: Int): Int = try {
        val id = context.resources.getIdentifier(name, "dimen", "android")
        if (id > 0) context.resources.getDimensionPixelSize(id) else fallback
    } catch (_: Exception) {
        fallback
    }
}
