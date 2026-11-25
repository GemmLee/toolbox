package com.toolbox.app.quicksearch

import android.icu.text.Transliterator
import android.os.Build

/**
 * 汉字 → 拼音首字母。
 *
 * 便捷搜题的悬浮窗刻意不用 EditText / 系统输入法（否则会抢走宿主 App 的焦点），
 * 所以键盘只有英文 26 个字母。中文题就靠首字母搜：`AQ` → 「安全」。
 *
 * 首字母来自系统 ICU 的「Han-Latin」转换器（Android 7.0 起可用），只取每个汉字
 * 音节的第一个字母。转换结果按字缓存——题库用到的字就那几千个，转一次就够，
 * 之后每次搜索都是纯查表。
 *
 * 只有汉字参与建首字母；数字、英文、标点一律跳过，所以 `AQ` 不会跨过一个数字
 * 拼出来，也不会把英文单词算进首字母串（本功能只服务中文题，英文题仍走原文匹配）。
 */
object PinyinInitials {

    private val lock = Any()

    private var transliterator: Transliterator? = null

    /** 已转好的字 → 首字母。 */
    private val initials = HashMap<Char, Char>(4096)

    /** 转不出拼音的字（生僻字、非汉字），记下来避免反复尝试。 */
    private val failed = HashSet<Char>(256)

    val supported: Boolean get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.N

    /** 首字母串：只保留汉字的首字母，其余字符跳过。 */
    fun initialsOf(text: String): String {
        if (text.isEmpty()) return ""
        val out = StringBuilder(text.length)
        for (c in text) {
            val initial = initialOf(c) ?: continue
            out.append(initial)
        }
        return out.toString()
    }

    /** 单个汉字的首字母（小写）；非汉字或无法转换返回 null。 */
    fun initialOf(c: Char): Char? {
        if (!isHan(c)) return null
        synchronized(lock) {
            initials[c]?.let { return it }
            if (failed.contains(c)) return null
            val trans = transliteratorLocked() ?: return null
            val first = try {
                trans.transliterate(c.toString()).firstOrNull { it.isLetter() }
            } catch (_: Throwable) {
                null
            }
            val letter = first?.let { baseOf(it) }
            if (letter == null) {
                failed.add(c)
                return null
            }
            initials[c] = letter
            return letter
        }
    }

    private fun isHan(c: Char): Boolean {
        val code = c.code
        return code in 0x3400..0x4DBF || // 扩展 A
            code in 0x4E00..0x9FFF || // 基本区
            code in 0xF900..0xFAFF // 兼容区
    }

    private fun transliteratorLocked(): Transliterator? {
        transliterator?.let { return it }
        if (!supported) return null
        val created = try {
            Transliterator.getInstance("Han-Latin")
        } catch (_: Throwable) {
            null
        }
        // 有些 ROM 裁掉了 ICU 数据：拿一个常用字试一下，转不出来就别用。
        if (created != null) {
            val ok = try {
                created.transliterate("中").any { it.isLetter() }
            } catch (_: Throwable) {
                false
            }
            if (!ok) return null
        }
        transliterator = created
        return created
    }

    /** 声调符号映射回基本字母（ü 记作 v），大写转小写。 */
    private fun baseOf(c: Char): Char? = when (c) {
        'a', 'ā', 'á', 'ǎ', 'à' -> 'a'
        'e', 'ē', 'é', 'ě', 'è' -> 'e'
        'i', 'ī', 'í', 'ǐ', 'ì' -> 'i'
        'o', 'ō', 'ó', 'ǒ', 'ò' -> 'o'
        'u', 'ū', 'ú', 'ǔ', 'ù' -> 'u'
        'ü', 'ǖ', 'ǘ', 'ǚ', 'ǜ' -> 'v'
        'v' -> 'v'
        in 'a'..'z' -> c
        in 'A'..'Z' -> c.lowercaseChar()
        else -> null
    }
}
