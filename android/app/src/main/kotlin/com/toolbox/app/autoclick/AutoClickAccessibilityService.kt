package com.toolbox.app.autoclick

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.GestureDescription
import android.content.Intent
import android.content.res.Resources
import android.graphics.Path
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.accessibility.AccessibilityEvent

/**
 * 自动点击的手势来源。
 *
 * Android 7.0（API 24）起无障碍服务可以 dispatchGesture，无需 root、无需
 * 录屏授权；返回键走 performGlobalAction。坐标按屏幕百分比换算，兼容不同
 * 分辨率与横竖屏。服务里不保存业务状态，调度全在 [AutoClickService]。
 */
class AutoClickAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: AutoClickAccessibilityService? = null

        val isConnected: Boolean get() = instance != null

        /** 系统是否支持手势注入（Android 6 只能用返回键）。 */
        val gesturesSupported: Boolean
            get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N

        private fun point(xPct: Double, yPct: Double): Pair<Float, Float> {
            val dm = Resources.getSystem().displayMetrics
            val x = (xPct / 100.0 * dm.widthPixels).toFloat()
            val y = (yPct / 100.0 * dm.heightPixels).toFloat()
            return Pair(x.coerceAtLeast(0f), y.coerceAtLeast(0f))
        }

        /** 提交一次点击；返回是否成功提交给系统（不是手势是否执行完）。 */
        fun tap(xPct: Double, yPct: Double, durationMs: Long): Boolean {
            val (x, y) = point(xPct, yPct)
            val path = Path().apply { moveTo(x, y) }
            return dispatch(path, durationMs)
        }

        fun swipe(
            x1Pct: Double,
            y1Pct: Double,
            x2Pct: Double,
            y2Pct: Double,
            durationMs: Long,
        ): Boolean {
            val (x1, y1) = point(x1Pct, y1Pct)
            val (x2, y2) = point(x2Pct, y2Pct)
            val path = Path().apply {
                moveTo(x1, y1)
                lineTo(x2, y2)
            }
            return dispatch(path, durationMs)
        }

        fun back(): Boolean = try {
            instance?.performGlobalAction(GLOBAL_ACTION_BACK) == true
        } catch (_: Exception) {
            false
        }

        private fun dispatch(path: Path, durationMs: Long): Boolean {
            val service = instance ?: return false
            if (!gesturesSupported) return false
            return try {
                val stroke = GestureDescription.StrokeDescription(
                    path,
                    0,
                    durationMs.coerceIn(10L, 60_000L),
                )
                val gesture = GestureDescription.Builder()
                    .addStroke(stroke)
                    .build()
                service.dispatchGesture(gesture, null, Handler(Looper.getMainLooper()))
            } catch (_: Exception) {
                false
            }
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        // 自动点击不需要监听界面变化；事件只用来满足服务声明。
    }

    override fun onInterrupt() {}

    override fun onUnbind(intent: Intent?): Boolean {
        instance = null
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }
}
