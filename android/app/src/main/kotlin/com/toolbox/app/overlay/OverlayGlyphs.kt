package com.toolbox.app.overlay

import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path

/**
 * 两个搜题悬浮窗共用的控件小图标。
 *
 * 这两处都是自绘，图标必须「撑满把手格子」才看得清：早期「收起」是一条横线加
 * 一个小箭头，实际只占了格子下半部分，看着像个小点点；现在改用双下箭头，
 * 上下都填满，语义也更直白。
 */
object OverlayGlyphs {

    /**
     * 收起：上下两层向下箭头。
     *
     * [unit] 传屏幕密度（dp → px），[cx]/[cy] 是格子中心。
     */
    fun drawCollapse(canvas: Canvas, cx: Float, cy: Float, unit: Float, paint: Paint) {
        val half = 6.4f * unit
        val rise = 5f * unit
        val offset = 5.4f * unit
        chevronDown(canvas, cx, cy - offset, half, rise, paint)
        chevronDown(canvas, cx, cy + offset, half, rise, paint)
    }

    /**
     * 缩放：右下角把手用的斜向双箭头（左上 ↔ 右下）。
     *
     * 箭头方向和「往右下拖变大、往左上拖变小」的手势一致；早期画的是
     * 右上 ↔ 左下，放在右下角会把人往错误方向带。
     */
    fun drawResize(canvas: Canvas, cx: Float, cy: Float, unit: Float, paint: Paint) {
        val half = 6.6f * unit
        canvas.drawLine(cx - half, cy - half, cx + half, cy + half, paint)
        val head = 4.4f * unit
        val arrow = Path()
        // 右下箭头
        arrow.moveTo(cx + half - head, cy + half)
        arrow.lineTo(cx + half, cy + half)
        arrow.moveTo(cx + half, cy + half)
        arrow.lineTo(cx + half, cy + half - head)
        // 左上箭头
        arrow.moveTo(cx - half + head, cy - half)
        arrow.lineTo(cx - half, cy - half)
        arrow.moveTo(cx - half, cy - half)
        arrow.lineTo(cx - half, cy - half + head)
        canvas.drawPath(arrow, paint)
    }

    /** 单个向下箭头：从 (cx-half, centerY-rise/2) 折到 (cx, centerY+rise/2)。 */
    private fun chevronDown(
        canvas: Canvas,
        cx: Float,
        centerY: Float,
        half: Float,
        rise: Float,
        paint: Paint,
    ) {
        val path = Path()
        path.moveTo(cx - half, centerY - rise / 2f)
        path.lineTo(cx, centerY + rise / 2f)
        path.lineTo(cx + half, centerY - rise / 2f)
        canvas.drawPath(path, paint)
    }
}
