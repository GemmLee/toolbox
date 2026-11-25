package com.toolbox.app.smartsearch

import android.accessibilityservice.AccessibilityService
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Rect
import android.os.Build
import android.view.Display
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import kotlin.math.abs

/**
 * 智能搜题的截屏来源。
 *
 * 做三件事：上报「屏幕内容变了」、按需截一张全屏图、以及在**页面禁止截图**时
 * 改读无障碍节点里的文字（见 [collectTextInRect]）。真正的 OCR 与匹配在
 * [SmartSearchService] 里做，避免无障碍服务持有业务状态。
 *
 * 需要系统「无障碍」授权（本服务声明了 canTakeScreenshot），一旦被用户关掉
 * 就收不到事件，悬浮窗会显示「请先开启无障碍服务」。
 */
class SmartSearchAccessibilityService : AccessibilityService() {

    companion object {
        @Volatile
        var instance: SmartSearchAccessibilityService? = null

        val isConnected: Boolean get() = instance != null

        /** 节点树最多走这么多节点，避免极端页面（长列表 / 富文本）把主线程拖住。 */
        private const val NODE_LIMIT = 1200

        /** 上下相差不到这个高度就算同一行，拼接时用空格而不是换行。 */
        private const val LINE_TOLERANCE_DP = 10f
    }

    /** 屏幕内容变化回调（已过滤本应用自己的窗口，避免自激）。 */
    var onScreenChanged: (() -> Unit)? = null

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        val e = event ?: return
        // 自己的悬浮窗也会产生事件，忽略掉，否则「更新结果」会触发下一轮扫描。
        if (e.packageName == packageName) return
        when (e.eventType) {
            AccessibilityEvent.TYPE_WINDOW_CONTENT_CHANGED,
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED,
            AccessibilityEvent.TYPE_VIEW_SCROLLED,
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED,
            -> onScreenChanged?.invoke()
        }
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

    /**
     * 读当前前台窗口里的文字，不截图。
     *
     * 这是「页面禁止截图」的兜底：带 `FLAG_SECURE` 的窗口（银行、部分题库、DRM
     * 视频、开了防截屏的 App）截出来是纯黑，但无障碍节点树里**文字还在**。
     * 只要目标 App 用的是 TextView / WebView / 系统控件，这里就能拿到和 OCR
     * 几乎一样的文本，喂给同一套题库匹配即可。
     *
     * [region] 是屏幕坐标 `[x, y, w, h]`，只取与它相交的节点；传 null 或空矩形
     * 表示整屏。节点按上下、左右排序后拼成多行文本，形态尽量贴近 OCR 输出。
     *
     * 拿不到的情况：题目完全由 Canvas 自绘（没有可访问性节点）、App 主动把
     * 内容设为 `importantForAccessibility="no"`、或密码框。
     */
    fun collectTextInRect(region: IntArray?): String {
        val root = try {
            rootInActiveWindow
        } catch (_: Exception) {
            null
        } ?: return ""
        val filter = if (region != null && region.size >= 4 && region[2] > 0 && region[3] > 0) {
            Rect(region[0], region[1], region[0] + region[2], region[1] + region[3])
        } else {
            null
        }
        val blocks = ArrayList<Block>(64)
        val stack = ArrayList<AccessibilityNodeInfo>(64)
        stack.add(root)
        var visited = 0
        val bounds = Rect()
        while (stack.isNotEmpty() && visited < NODE_LIMIT) {
            val node = stack.removeAt(stack.size - 1)
            visited++
            // 自己悬浮窗里的「答案 / 题干」不算，否则会一直匹配回同一题。
            if (node.packageName?.toString() != packageName) {
                var text = node.text?.toString()?.trim().orEmpty()
                if (text.isEmpty()) {
                    text = node.contentDescription?.toString()?.trim().orEmpty()
                }
                if (text.isNotEmpty()) {
                    node.getBoundsInScreen(bounds)
                    if (bounds.width() > 0 && bounds.height() > 0 &&
                        (filter == null || Rect.intersects(bounds, filter))
                    ) {
                        blocks.add(Block(text, bounds.top, bounds.left))
                    }
                }
            }
            for (i in node.childCount - 1 downTo 0) {
                val child = try {
                    node.getChild(i)
                } catch (_: Exception) {
                    null
                }
                if (child != null) stack.add(child)
            }
        }
        if (blocks.isEmpty()) return ""
        blocks.sortWith(compareBy({ it.top }, { it.left }))
        val tolerance = (LINE_TOLERANCE_DP * resources.displayMetrics.density).toInt()
            .coerceAtLeast(1)
        val sb = StringBuilder(256)
        var lastTop = Int.MIN_VALUE
        for (block in blocks) {
            if (sb.isNotEmpty()) {
                if (lastTop != Int.MIN_VALUE && abs(block.top - lastTop) <= tolerance) {
                    sb.append(' ')
                } else {
                    sb.append('\n')
                }
            }
            sb.append(block.text)
            lastTop = block.top
        }
        return sb.toString()
    }

    private class Block(val text: String, val top: Int, val left: Int)

    /** 截当前整屏；Android 11 以下没有这个 API，直接回调 null。 */
    @Suppress("NewApi")
    fun captureScreen(onResult: (Bitmap?) -> Unit) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            onResult(null)
            return
        }
        try {
            takeScreenshot(
                Display.DEFAULT_DISPLAY,
                mainExecutor,
                object : TakeScreenshotCallback {
                    override fun onSuccess(result: ScreenshotResult) {
                        val bitmap = try {
                            Bitmap
                                .wrapHardwareBuffer(result.hardwareBuffer, result.colorSpace)
                                ?.copy(Bitmap.Config.ARGB_8888, false)
                        } catch (_: Exception) {
                            null
                        } finally {
                            try {
                                result.hardwareBuffer.close()
                            } catch (_: Exception) {
                            }
                        }
                        onResult(bitmap)
                    }

                    override fun onFailure(errorCode: Int) {
                        onResult(null)
                    }
                },
            )
        } catch (_: Exception) {
            onResult(null)
        }
    }
}
