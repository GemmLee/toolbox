package com.toolbox.app.overlay

import android.graphics.Color

/**
 * 两个搜题悬浮窗（便捷 / 智能）共用的配色表。
 *
 * 以前颜色硬编码在各自的 View 里，改一次主题要翻几十行 Paint；现在三套主题
 * （深色 / 浅色 / 透明）各是一份 [Colors]，View 只在 setTheme 时按表重设画笔。
 *
 * 透明主题只用黑、白两色，靠透明度拉开层次：底板压到很淡（几乎看不到底色），
 * 文字用不透明的白，保证压在任意 App 上都清晰。原来的绿/蓝强调色全部去掉，
 * 选中态改用「更深的黑底 + 白字」区分，避免白底白字看不清。
 */
object OverlayPalette {
    const val THEME_DARK = "dark"
    const val THEME_LIGHT = "light"
    const val THEME_TRANSPARENT = "transparent"

    /** 兼容 Dart 下发的英文 key 与旧的中文别名。 */
    fun normalize(theme: String?): String = when (theme) {
        THEME_LIGHT, "light", "白色", "白" -> THEME_LIGHT
        THEME_TRANSPARENT, "transparent", "透明色", "透明" -> THEME_TRANSPARENT
        else -> THEME_DARK
    }

    data class Colors(
        val panelBg: Int,
        val searchBg: Int,
        val searchText: Int,
        val placeholder: Int,
        val cardBg: Int,
        val keyBg: Int,
        val keyPressedBg: Int,
        val keyText: Int,
        val actionText: Int,
        val stemText: Int,
        val optionText: Int,
        val correctText: Int,
        val smartAccent: Int,
        val pageText: Int,
        val hintText: Int,
        val icon: Int,
        val iconPressed: Int,
        val grip: Int,
        val clearBg: Int,
        val clearX: Int,
        val chipBg: Int,
        val chipText: Int,
        val chipSelectedText: Int,
        val accent: Int,
        val accentPressed: Int,
        val handleBg: Int,
        val handleBgPressed: Int,
        val scrollBar: Int,
        val cursor: Int,
        /** 文字描边阴影色；仅透明主题用深色描边保证白字在浅色 App 上也清晰。 */
        val textShadow: Int = Color.TRANSPARENT,
    )

    private val dark = Colors(
        panelBg = 0xE62B2B31.toInt(),
        searchBg = 0xFFF1F2F4.toInt(),
        searchText = 0xFF202124.toInt(),
        placeholder = 0xFF8A8F98.toInt(),
        cardBg = 0x1AFFFFFF,
        keyBg = 0x26FFFFFF,
        keyPressedBg = 0x59FFFFFF,
        keyText = Color.WHITE,
        actionText = Color.WHITE,
        stemText = Color.WHITE,
        optionText = 0xE6FFFFFF.toInt(),
        correctText = 0xFF8AB4F8.toInt(),
        smartAccent = 0xFF5BE08A.toInt(),
        pageText = 0xB3FFFFFF.toInt(),
        hintText = 0x99FFFFFF.toInt(),
        icon = 0xE6FFFFFF.toInt(),
        iconPressed = Color.WHITE,
        grip = 0x77FFFFFF,
        clearBg = 0x1F000000,
        clearX = 0xFF6B7076.toInt(),
        chipBg = 0x26FFFFFF,
        chipText = 0xCCFFFFFF.toInt(),
        chipSelectedText = Color.WHITE,
        accent = 0xFF34C759.toInt(),
        accentPressed = 0xFF2AA84A.toInt(),
        handleBg = 0x26000000,
        handleBgPressed = 0x40FFFFFF,
        scrollBar = 0x59FFFFFF,
        cursor = 0xFF34C759.toInt(),
    )

    private val light = Colors(
        panelBg = 0xF5FAFAFA.toInt(),
        searchBg = 0xFFE8EAED.toInt(),
        searchText = 0xFF202124.toInt(),
        placeholder = 0xFF9AA0A6.toInt(),
        cardBg = 0x0D000000,
        keyBg = 0x19000000,
        keyPressedBg = 0x33000000,
        keyText = 0xFF202124.toInt(),
        actionText = 0xFF202124.toInt(),
        stemText = 0xFF202124.toInt(),
        optionText = 0xFF3C4043.toInt(),
        correctText = 0xFF1967D2.toInt(),
        smartAccent = 0xFF1B8E3A.toInt(),
        pageText = 0xFF5F6368.toInt(),
        hintText = 0xFF5F6368.toInt(),
        icon = 0xFF5F6368.toInt(),
        iconPressed = 0xFF202124.toInt(),
        grip = 0xFF9AA0A6.toInt(),
        clearBg = 0x1F000000,
        clearX = 0xFF5F6368.toInt(),
        chipBg = 0x19000000,
        chipText = 0xFF3C4043.toInt(),
        chipSelectedText = Color.WHITE,
        accent = 0xFF1B8E3A.toInt(),
        accentPressed = 0xFF156C2C.toInt(),
        handleBg = 0x14000000,
        handleBgPressed = 0x33000000,
        scrollBar = 0x59000000,
        cursor = 0xFF1B8E3A.toInt(),
    )

    private val transparent = Colors(
        // 底板压到 8% 黑，几乎看不到底色；文字用不透明白压在任意 App 上都清晰。
        panelBg = 0x14000000,
        searchBg = 0xF2FFFFFF.toInt(),
        searchText = Color.BLACK,
        placeholder = 0x99000000.toInt(),
        cardBg = 0x0DFFFFFF,
        keyBg = 0x1FFFFFFF,
        keyPressedBg = 0x4DFFFFFF,
        keyText = Color.WHITE,
        actionText = Color.WHITE,
        stemText = Color.WHITE,
        optionText = 0xE6FFFFFF.toInt(),
        // 正确项不再用蓝色，靠不透明 + 粗体突出；智能搜题高亮同理改纯白。
        correctText = Color.WHITE,
        smartAccent = Color.WHITE,
        pageText = 0xB3FFFFFF.toInt(),
        hintText = 0xCCFFFFFF.toInt(),
        icon = 0xE6FFFFFF.toInt(),
        iconPressed = Color.WHITE,
        grip = 0x99FFFFFF.toInt(),
        clearBg = 0x33000000,
        clearX = Color.BLACK,
        chipBg = 0x1FFFFFFF,
        chipText = 0xCCFFFFFF.toInt(),
        // 选中筛选/搜索键用深黑底 + 白字，仍是黑白两色但对比更强。
        chipSelectedText = Color.WHITE,
        accent = 0xB3000000.toInt(),
        accentPressed = 0xE6000000.toInt(),
        handleBg = 0x26000000,
        handleBgPressed = 0x4DFFFFFF,
        scrollBar = 0x59FFFFFF,
        cursor = Color.BLACK,
        // 淡底 + 黑描边：字在浅色 App 上有轮廓、在深色 App 上照样清楚。
        textShadow = 0x99000000.toInt(),
    )

    fun of(theme: String?): Colors = when (normalize(theme)) {
        THEME_LIGHT -> light
        THEME_TRANSPARENT -> transparent
        else -> dark
    }
}
