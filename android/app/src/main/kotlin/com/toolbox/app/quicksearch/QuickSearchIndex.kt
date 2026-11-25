package com.toolbox.app.quicksearch

import org.json.JSONObject
import java.io.File

/**
 * 悬浮窗里的题库索引。
 *
 * Flutter 侧把题目快照写成 JSON 文件（stem / options / answer），原生这里只做
 * 轻量关键词匹配：悬浮窗要能在宿主 App 前台时即时出结果，不适合再跨进程/跨引擎
 * 回调 Dart 搜索。打分口径与 Dart 侧 [relevanceOf] 保持同样的优先级：
 * 题干 > 选项，词项全覆盖加权，完全相等再加成。
 *
 * 每个悬浮窗服务各持一个实例：便捷搜题可以按题库裁剪索引，智能搜题要全量，
 * 共用一份会互相把对方的范围改掉。
 */
class QuickSearchIndex {

    data class QOption(
        val key: String,
        val text: String,
        /** Flutter 侧已经比对过答案，直接告诉原生这一项是不是正确的。 */
        val correct: Boolean = false,
    )

    data class QItem(
        val stem: String,
        val options: List<QOption>,
        val answer: List<String>,
        /** `single` / `multiple` / `true_false` / ...；旧索引文件可能为空。 */
        val type: String = "",
        /** 题目所属题库；旧索引文件可能为空，空值表示「不限题库时仍可命中」。 */
        val bankId: String = "",
        /** 已经翻译成中文的答案（判断题是「正确 / 错误」），旧索引文件可能为空。 */
        val answerText: String = "",
    ) {
        private val answerKeys: Set<String>
            get() = answer.map { it.trim().lowercase() }.toSet()

        private val judge: Boolean
            get() = type == "true_false" ||
                (options.isEmpty() && answerKeys.any { it == "true" || it == "false" })

        /**
         * 面板里要画的选项行。
         *
         * 判断题在 App 里选项是固定补的「正确 / 错误」，索引里没有选项，这里补出来；
         * 其余题型用 Flutter 传下来的 correct 标记，旧索引文件没有这个字段时按 key 兜底。
         */
        fun displayOptions(): List<Row> {
            if (options.isNotEmpty()) {
                val keys = answerKeys
                return options.map { o ->
                    val label = if (o.key.isEmpty()) o.text else "${o.key}. ${o.text}"
                    Row(label, o.correct || keys.contains(o.key.lowercase()))
                }
            }
            if (!judge) return emptyList()
            val keys = answerKeys
            return listOf(
                Row("正确", keys.contains("true")),
                Row("错误", keys.contains("false")),
            )
        }

        /** 顶部/底部的「答案：…」文本，判断题不能露出 true / false。 */
        fun displayAnswer(): String {
            if (answerText.isNotEmpty()) return answerText
            return answer.joinToString("、") {
                when (it.trim().lowercase()) {
                    "true" -> "正确"
                    "false" -> "错误"
                    else -> it
                }
            }
        }
    }

    /** 一行可展示的选项：文本 + 是否正确。 */
    data class Row(val text: String, val correct: Boolean)

    private var items: List<QItem> = emptyList()

    /** 一道题的二元组：题干、题干+选项、仅选项串、每个选项各自一份。 */
    private class ItemGrams(
        val stem: Set<String>,
        val all: Set<String>,
        val options: Set<String>,
        val optionList: List<Set<String>>,
    )

    /** 智能搜题用的二元组缓存，避免每次 OCR 都重新切词。 */
    private var gramCache: List<ItemGrams>? = null

    /**
     * 首字母索引，与 [items] 一一对应：题干一份、全部选项拼起来一份。
     *
     * 键盘只有英文字母，中文题靠首字母搜（`AQ` → 「安全」）。翻译成拼音要问系统
     * ICU，题库几千道题就是几十万次转换，不能在用户打字时同步做，所以在后台建；
     * 没建好之前 `scoreOf` 只是少一份加成，普通关键词匹配照常可用。
     */
    @Volatile
    private var stemInitials: List<String>? = null

    @Volatile
    private var optionInitials: List<String>? = null

    @Volatile
    private var initialsBuilding = false

    /**
     * 首字母表建好后回调（主线程）。
     *
     * 换题库会重建索引，首字母表要重新算；这段时间里纯首字母查询会暂时搜不到，
     * 宿主收到回调后补搜一次，用户就不会先看到「没有匹配到题目」再手动重搜。
     */
    @Volatile
    var onInitialsReady: (() -> Unit)? = null

    /** 「题干 + 选项」口径的两道门槛：两边都要过线才算同一道题。 */
    private companion object {
        const val STRUCT_STEM_MIN = 0.42
        const val STRUCT_OPTION_MIN = 0.40
    }

    val size: Int get() = items.size

    /** 从 Flutter 写好的 JSON 读取索引；文件缺失/损坏时清空，不抛异常。 */
    fun load(file: File): Int {
        items = try {
            parse(file.readText(Charsets.UTF_8))
        } catch (_: Exception) {
            emptyList()
        }
        gramCache = null
        stemInitials = null
        optionInitials = null
        initialsBuilding = false
        buildInitialsAsync()
        return items.size
    }

    fun parse(raw: String): List<QItem> {
        val root = JSONObject(raw)
        val array = root.optJSONArray("questions") ?: return emptyList()
        val out = ArrayList<QItem>(array.length())
        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val stem = obj.optString("stem").trim()
            if (stem.isEmpty()) continue
            val options = ArrayList<QOption>()
            val optArray = obj.optJSONArray("options")
            if (optArray != null) {
                for (j in 0 until optArray.length()) {
                    val o = optArray.optJSONObject(j) ?: continue
                    options.add(
                        QOption(
                            key = o.optString("key"),
                            text = o.optString("text"),
                            correct = o.optBoolean("correct", false),
                        )
                    )
                }
            }
            val answer = ArrayList<String>()
            val ansArray = obj.optJSONArray("answer")
            if (ansArray != null) {
                for (j in 0 until ansArray.length()) {
                    val v = ansArray.optString(j)
                    if (v.isNotEmpty()) answer.add(v)
                }
            }
            out.add(
                QItem(
                    stem = stem,
                    options = options,
                    answer = answer,
                    type = obj.optString("type"),
                    bankId = obj.optString("bankId"),
                    answerText = obj.optString("answerText"),
                )
            )
        }
        return out
    }

    /**
     * 前 [limit] 个匹配结果，按相关度从高到低；无命中返回空列表。
     *
     * 悬浮窗一次显示几道题、左右滑动切换，都从这里取。同分时短题干优先：
     * 同样的命中落在更短的题上，更像用户想找的那一道。
     *
     * [type] / [bankIds] 是便捷搜题的筛选范围：传 null / 空集合表示不限。旧索引里
     * bankId 可能为空串，此时只要筛了题库就跳过——宁可少搜，也不要把别的题库的题混进来。
     */
    fun top(
        query: String,
        limit: Int = 3,
        minScore: Double = 0.0,
        type: String? = null,
        bankIds: Set<String>? = null,
    ): List<Pair<QItem, Double>> {
        val terms = splitTerms(query)
        if (terms.isEmpty() || items.isEmpty() || limit <= 0) return emptyList()
        buildInitialsAsync()
        val stems = stemInitials
        val options = optionInitials
        val hits = ArrayList<Pair<QItem, Double>>()
        for (i in items.indices) {
            val item = items[i]
            if (type != null && item.type != type) continue
            if (bankIds != null && bankIds.isNotEmpty() && item.bankId !in bankIds) continue
            val score = scoreOf(
                item,
                terms,
                stems?.getOrNull(i).orEmpty(),
                options?.getOrNull(i).orEmpty(),
            )
            if (score <= minScore) continue
            hits.add(item to score)
        }
        if (hits.isEmpty()) return emptyList()
        hits.sortWith(
            compareByDescending<Pair<QItem, Double>> { it.second }
                .thenBy { it.first.stem.length }
        )
        return if (hits.size > limit) hits.subList(0, limit) else hits
    }

    /** 匹配度最高的一题；没有任何词项命中时返回 null。 */
    fun best(
        query: String,
        minScore: Double = 0.0,
        type: String? = null,
        bankIds: Set<String>? = null,
    ): Pair<QItem, Double>? = top(query, 1, minScore, type, bankIds).firstOrNull()

    /** 后台建首字母索引；已建好或正在建时直接返回。 */
    private fun buildInitialsAsync() {
        if (initialsBuilding || stemInitials != null) return
        val snapshot = items
        if (snapshot.isEmpty() || !PinyinInitials.supported) return
        initialsBuilding = true
        Thread({
            val stems = ArrayList<String>(snapshot.size)
            val options = ArrayList<String>(snapshot.size)
            for (item in snapshot) {
                stems.add(PinyinInitials.initialsOf(item.stem))
                options.add(PinyinInitials.initialsOf(item.options.joinToString("") { it.text }))
            }
            // 建的过程中索引可能被重载过，旧结果直接丢掉。
            if (items === snapshot) {
                stemInitials = stems
                optionInitials = options
                initialsBuilding = false
                val listener = onInitialsReady
                if (listener != null) {
                    android.os.Handler(android.os.Looper.getMainLooper())
                        .post { listener.invoke() }
                }
            } else {
                initialsBuilding = false
            }
        }, "quick-initials").apply { isDaemon = true }.start()
    }

    private fun splitTerms(query: String): List<String> {
        val lowered = query.lowercase()
        val parts = lowered.split(Regex("[\\s,，、;；/\\\\|]+"))
        val seen = LinkedHashSet<String>()
        for (p in parts) {
            val t = p.trim().trim('"', '“', '”', '「', '」', '『', '』')
            if (t.isNotEmpty() && t.length <= 64) seen.add(t)
        }
        return seen.toList()
    }

    /**
     * 单题打分。
     *
     * [stemInitial] / [optionInitial] 是这道题的题干、选项首字母串；索引还没建好时
     * 传空串，只是少了首字母这一份加成。
     */
    private fun scoreOf(
        item: QItem,
        terms: List<String>,
        stemInitial: String,
        optionInitial: String,
    ): Double {
        val stem = item.stem.lowercase()
        val optionText = item.options.joinToString(" ") { it.text }.lowercase()
        var score = 0.0
        var matched = 0
        for (term in terms) {
            var hit = false
            if (stem.contains(term)) {
                score += 3.0
                hit = true
            }
            if (optionText.contains(term)) {
                score += 1.2
                hit = true
            }
            // 拼音首字母：`AQ` → 「安全」。单字母不作为首字母用，否则半屏题都会命中。
            if (term.length >= 2 && term.all { it in 'a'..'z' }) {
                if (stemInitial.contains(term)) {
                    score += 2.6
                    hit = true
                    // 从题干开头起的首字母最像「按题目开头记的搜法」。
                    if (stemInitial.startsWith(term)) score += 1.2
                }
                if (optionInitial.contains(term)) {
                    score += 1.0
                    hit = true
                }
            }
            if (hit) matched++
        }
        if (matched == 0) return 0.0
        val coverage = matched.toDouble() / terms.size
        score *= 0.6 + 0.4 * coverage
        score += 4.0 * coverage
        // 整串原样出现在题干里，几乎就是用户想找的那道题。
        val whole = terms.joinToString(" ")
        if (terms.size > 1 && stem.contains(whole)) score += 5.0
        return score
    }

    // ---------- 智能搜题：整段 OCR 文本比对 ----------

    /**
     * 用 OCR 识别出的整段文字取前 [limit] 个最像的题，按相关度从高到低。
     *
     * 分两种口径：
     *
     * **A. 框到「题干 + 多个选项」**（能从文本里解析出 >= 2 个选项标记）：
     * 题干与选项各自算分，**两边都要过线**才算匹配，最终分取均值。
     * 这样只有题干像、选项完全对不上的题不会被当成答案；选项按内容逐项比，
     * 与顺序无关（A/B 被 OCR 打乱也不影响）。
     *
     * **B. 只框到题干、或只框到选项**：题干、题干+选项、仅选项三路取最高。
     *
     * 两种口径都按覆盖率轻微补正，让「只框住一部分」的题不被长度差压死。
     */
    fun topForOcr(
        raw: String,
        limit: Int = 3,
        minScore: Double = 0.30,
    ): List<Pair<QItem, Double>> {
        if (items.isEmpty() || limit <= 0) return emptyList()
        val query = normalize(raw)
        if (query.length < 8) return emptyList()
        val queryGrams = grams(query)
        if (queryGrams.isEmpty()) return emptyList()
        val cache = gramCache ?: buildGramCache().also { gramCache = it }

        // A. 题干 + 选项：两边都得对得上。解析出选项就以此为准，不再退回只比题干。
        val structured = structuredTop(raw, cache, limit)
        if (structured != null) return structured

        // B. 只有一侧：三路证据取最高。
        // 太短的 OCR 文本（比如只认出一个选项）不参与选项口径，避免乱配。
        val optionsUsable = query.length >= 8
        val hits = ArrayList<Pair<QItem, Double>>()
        for (i in items.indices) {
            val g = cache[i]
            var base = dice(queryGrams, g.stem)
            if (optionsUsable && g.options.isNotEmpty()) {
                val whole = dice(queryGrams, g.all) * 0.97
                if (whole > base) base = whole
                val optionOnly = dice(queryGrams, g.options) * 0.88
                if (optionOnly > base) base = optionOnly
            }
            if (base <= 0.0) continue
            val score = base * (0.92 + 0.08 * coverageOf(queryGrams, g.all))
            if (score < minScore) continue
            hits.add(items[i] to score)
        }
        if (hits.isEmpty()) return emptyList()
        hits.sortWith(compareByDescending<Pair<QItem, Double>> { it.second })
        return if (hits.size > limit) hits.subList(0, limit) else hits
    }

    /** 匹配度最高的一题；没有任何命中时返回 null。 */
    fun bestForOcr(raw: String, minScore: Double = 0.30): Pair<QItem, Double>? =
        topForOcr(raw, 1, minScore).firstOrNull()

    /**
     * 「题干 + 选项」口径取前 [limit] 个。
     *
     * 返回 null 表示文本里没有成形的选项列表（没解析出 >= 2 个选项标记），
     * 调用方应退回三路证据口径；返回空列表表示 handled 但没有题过线。
     * 这样只有题干像、选项完全对不上的题不会被当成答案。
     */
    private fun structuredTop(
        raw: String,
        cache: List<ItemGrams>,
        limit: Int,
    ): List<Pair<QItem, Double>>? {
        val parsed = parseQuery(raw)
        if (parsed.options.size < 2) return null
        val stemNorm = normalize(parsed.stem)
        // 题干太短（比如只框到「下列说法正确的是」）就不拿来当约束。
        if (stemNorm.length < 6) return null
        val stemGrams = grams(stemNorm)
        val optionGrams = parsed.options
            .map { grams(normalize(it)) }
            .filter { it.isNotEmpty() }
        if (stemGrams.isEmpty() || optionGrams.size < 2) return null

        val hits = ArrayList<Pair<QItem, Double>>()
        for (i in items.indices) {
            val g = cache[i]
            if (g.stem.isEmpty() || g.optionList.size < 2) continue
            val stemScore = dice(stemGrams, g.stem)
            if (stemScore < STRUCT_STEM_MIN) continue
            val optionScore = optionScoreOf(optionGrams, g.optionList)
            if (optionScore < STRUCT_OPTION_MIN) continue
            // 两边都过线才排高低；用均值，避免只看单边。
            hits.add(items[i] to (stemScore + optionScore) / 2.0)
        }
        if (hits.isEmpty()) return emptyList()
        hits.sortWith(compareByDescending<Pair<QItem, Double>> { it.second })
        return if (hits.size > limit) hits.subList(0, limit) else hits
    }

    /** OCR 文本里解析出来的题干与各个选项（选项顺序按识别顺序，比对时与顺序无关）。 */
    private class ParsedQuery(val stem: String, val options: List<String>)

    /**
     * 选项标记：`A.` / `A、` / `A．` / `A)` / `A）` / `A:`，前面不能紧跟字母。
     *
     * OCR 有时把多个选项挤在同一行，所以这里按标记切，而不是按行切。
     */
    private val optionMark = Regex("""(?<![A-Za-z])([A-Ha-hＡ-Ｈａ-ｈ])\s*[.．、)）:：]\s*""")

    /** 全角字母转半角：中文 OCR 常把 `A.` 识成 `Ａ．`。 */
    private fun halfWidthLetter(c: Char): Char {
        val code = c.code
        return when (code) {
            in 0xFF21..0xFF3A, in 0xFF41..0xFF5A -> (code - 0xFEE0).toChar()
            else -> c
        }
    }

    private fun parseQuery(raw: String): ParsedQuery {
        val text = raw.replace("\r\n", "\n").replace('\r', '\n')
        val marks = ArrayList<MatchResult>()
        val seen = HashSet<Char>()
        for (m in optionMark.findAll(text)) {
            val c = halfWidthLetter(m.groupValues[1].first()).uppercaseChar()
            // 同一个字母只认第一次，防止题干里的括号把 A/B 重复算进去。
            if (!seen.add(c)) continue
            marks.add(m)
        }
        if (marks.size < 2) return ParsedQuery(text, emptyList())
        val options = ArrayList<String>(marks.size)
        for (i in marks.indices) {
            val start = marks[i].range.last + 1
            val end = if (i + 1 < marks.size) marks[i + 1].range.first else text.length
            if (end <= start) continue
            val body = text.substring(start, end).trim()
            if (body.isNotEmpty()) options.add(body)
        }
        if (options.size < 2) return ParsedQuery(text, emptyList())
        val stem = text.substring(0, marks.first().range.first).trim()
        return ParsedQuery(stem, options)
    }

    /** 每个查询选项与题库选项逐个比，取各自最高分再平均（顺序无关）。 */
    private fun optionScoreOf(
        queryOptions: List<Set<String>>,
        itemOptions: List<Set<String>>,
    ): Double {
        if (queryOptions.isEmpty() || itemOptions.isEmpty()) return 0.0
        var sum = 0.0
        for (q in queryOptions) {
            var best = 0.0
            for (o in itemOptions) {
                val d = dice(q, o)
                if (d > best) best = d
            }
            sum += best
        }
        return sum / queryOptions.size
    }

    /** 查询二元组被某道题覆盖的比例：衡量「框到的字有多少是这条的内容」。 */
    private fun coverageOf(query: Set<String>, target: Set<String>): Double {
        if (query.isEmpty() || target.isEmpty()) return 0.0
        var hit = 0
        for (g in query) if (target.contains(g)) hit++
        return hit.toDouble() / query.size
    }

    private fun buildGramCache(): List<ItemGrams> = items.map { item ->
        val options = item.options.joinToString("") { it.text }
        ItemGrams(
            stem = grams(normalize(item.stem)),
            all = grams(normalize(item.stem + options)),
            options = grams(normalize(options)),
            optionList = item.options
                .map { grams(normalize(it.text)) }
                .filter { it.isNotEmpty() },
        )
    }

    /** 只保留汉字、字母与数字：OCR 的标点、空格、题号都会干扰比对。 */
    private fun normalize(text: String): String {
        val sb = StringBuilder(text.length)
        for (c in text) {
            if (c.isLetterOrDigit()) sb.append(c.lowercaseChar())
        }
        return sb.toString()
    }

    private fun grams(text: String): Set<String> {
        if (text.isEmpty()) return emptySet()
        if (text.length == 1) return setOf(text)
        val out = HashSet<String>(text.length)
        for (i in 0 until text.length - 1) out.add(text.substring(i, i + 2))
        return out
    }

    private fun dice(a: Set<String>, b: Set<String>): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        val small = if (a.size <= b.size) a else b
        val big = if (a.size <= b.size) b else a
        var inter = 0
        for (g in small) if (big.contains(g)) inter++
        return 2.0 * inter / (a.size + b.size)
    }
}
