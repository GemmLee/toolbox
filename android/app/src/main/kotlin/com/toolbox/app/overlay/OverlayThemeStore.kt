package com.toolbox.app.overlay

import android.content.Context

/**
 * 悬浮窗背景色偏好的唯一存取口。
 *
 * 便捷 / 智能两个 Service 与 MainActivity 共用同一个 key：开启页改一次颜色，
 * 两个悬浮窗下次创建（或运行中收到 setTheme）都读这里，不会出现各记各的。
 */
object OverlayThemeStore {
    private const val PREFS = "overlay_state"
    private const val KEY_THEME = "overlay_theme"

    fun read(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_THEME, OverlayPalette.THEME_DARK) ?: OverlayPalette.THEME_DARK

    fun write(context: Context, theme: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_THEME, OverlayPalette.normalize(theme))
            .apply()
    }
}
