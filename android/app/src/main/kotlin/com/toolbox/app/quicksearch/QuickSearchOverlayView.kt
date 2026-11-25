package com.toolbox.app.quicksearch

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.graphics.Typeface
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import android.text.TextUtils
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import com.toolbox.app.overlay.OverlayGlyphs
import com.toolbox.app.overlay.OverlayPalette
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

/**
 * 便捷搜题的悬浮窗内容：搜索框 + 自绘轻键盘 + 结果面板，同一个 View 按状态切换。
 *
 * 关键约束：
 * - 键盘自绘，不使用 EditText，也就不需要输入法 → 悬浮窗能保持
 *   `FLAG_NOT_FOCUSABLE` 且不会改写宿主 App 的输入焦点。键盘只有 26 个英文字母，
 *   中文题用**拼音首字母**搜（`AQ` → 「安全」，见 [QuickSearchIndex]）。
 * - 顶部整条可拖动窗口，右端是关闭；底部两角是固定把手：
 *   左下双下箭头收起、右下斜箭头缩放（横拖改宽、竖拖改高）。
 *   缩放放右下角，和「左上角固定、尺寸向右下长」的缩放逻辑一致。
 * - 尺寸变化时由宿主按「搜索框锚点」反算窗口位置，面板展开收起不会左右跳。
 */
class QuickSearchOverlayView(
    context: Context,
    /** 这个窗口自己的索引（便捷搜题按题库裁剪过），不与智能搜题共用。 */
    private val index: QuickSearchIndex,
) : View(context) {

    interface Host {
        /** 顶部拖动：dx/dy 为屏幕像素增量。 */
        fun onDragBy(dx: Float, dy: Float)

        /** 右上角关闭。 */
        fun onClose()

        /** 左下角的收起：把窗口收成屏幕边上的小球。 */
        fun onMinimize()

        /** 右下角缩放把手：横竖两个方向各自 0.7 ~ 1.8 的独立缩放。 */
        fun onScaleChanged(zoomX: Float, zoomY: Float)

        /** 缩放松手：宿主在这里落盘并夹回屏幕内。 */
        fun onScaleFinished()

        /** 题型筛选变了（null = 全部题型），宿主负责落盘，下次开启沿用。 */
        fun onTypeFilterChanged(type: String?)
    }

    enum class Mode { KEYBOARD, RESULT }

    var host: Host? = null

    /**
     * 横竖两个方向的缩放。
     *
     * 内部一律按「逻辑尺寸」排版（dp/sp 不乘缩放），测量时把逻辑宽高分别乘
     * [zoomX] / [zoomY]，绘制时整体 canvas.scale，触摸时再把坐标除回去。
     * 这样两个方向可以独立拉伸：拉宽只变宽、拉高只变高，不用改一堆布局常量。
     */
    var zoomX: Float = 1f
        private set
    var zoomY: Float = 1f
        private set

    private val density = resources.displayMetrics.density
    private val scaled = resources.displayMetrics.scaledDensity
    private fun dp(v: Float) = v * density
    private fun sp(v: Float) = v * scaled

    /** 逻辑宽度 / 高度（未乘缩放），所有命中矩形都用它算。 */
    private var logicalWidth = 0f
    private var logicalHeight = 0f

    // ---------- 尺寸常量 ----------
    private val panelRadius get() = dp(12f)
    private val padH get() = dp(8f)
    private val headerH get() = dp(30f)
    private val traySize get() = dp(30f)
    private val searchH get() = dp(33f)
    private val gap get() = dp(4f)
    private val keyH get() = dp(31f)
    private val keyGap get() = dp(3f)
    private val cardPad get() = dp(8f)
    private val filterH get() = dp(26f)

    /** 搜索框下面那行题型筛选的顶边（结果卡片也从这里往下排）。 */
    private val filtersTop get() = headerH + searchH + gap
    private val cardTopY get() = filtersTop + filterH + gap

    // ---------- 画笔 ----------
    /** 当前主题配色；setTheme 时整表替换并重设所有画笔颜色。 */
    private var colors = OverlayPalette.of(null)

    private val panelPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val searchBgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val cardPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val keyPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val keyPressedPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val greenPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val greenPressedPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val iconPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1.5f)
        strokeCap = Paint.Cap.ROUND
    }

    private val searchTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = sp(14f) }
    private val placeholderPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = sp(14f) }
    private val keyTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(14.5f)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }
    private val actionTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(13f)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }
    private val stemPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(14.5f)
        typeface = Typeface.DEFAULT_BOLD
    }
    private val optionPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = sp(13f) }
    // 正确选项与答案行统一用蓝色高亮，绿色只留给搜索/收起按钮，
    // 避免「答案 = 绿色」和按钮撞色；页码用弱化灰放在同一行右端。
    private val correctPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(13f)
        typeface = Typeface.DEFAULT_BOLD
    }
    private val answerPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(13f)
        typeface = Typeface.DEFAULT_BOLD
    }
    private val pagePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(12f)
        textAlign = Paint.Align.RIGHT
    }
    private val hintPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply { textSize = sp(13f) }
    /** 搜索框右侧的清除按钮：浅底上的淡灰圆 + 深灰叉（搜索框本身是白底）。 */
    private val clearBgPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val clearXStroke = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeWidth = dp(1.6f)
    }
    /** 题型筛选条：未选中 / 选中（绿底白字）。 */
    private val chipPaint = Paint(Paint.ANTI_ALIAS_FLAG)
    private val chipTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(12.5f)
        textAlign = Paint.Align.CENTER
    }
    private val chipSelectedTextPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = sp(12.5f)
        typeface = Typeface.DEFAULT_BOLD
        textAlign = Paint.Align.CENTER
    }

    init {
        applyColors()
    }

    /** 由宿主下发的主题切换（dark / light / transparent）。 */
    fun setTheme(theme: String?) {
        val next = OverlayPalette.of(theme)
        if (next === colors) return
        colors = next
        applyColors()
        requestLayout()
        invalidate()
    }

    private fun applyColors() {
        panelPaint.color = colors.panelBg
        searchBgPaint.color = colors.searchBg
        cardPaint.color = colors.cardBg
        keyPaint.color = colors.keyBg
        keyPressedPaint.color = colors.keyPressedBg
        greenPaint.color = colors.accent
        greenPressedPaint.color = colors.accentPressed
        iconPaint.color = colors.icon
        searchTextPaint.color = colors.searchText
        placeholderPaint.color = colors.placeholder
        keyTextPaint.color = colors.keyText
        actionTextPaint.color = colors.actionText
        stemPaint.color = colors.stemText
        optionPaint.color = colors.optionText
        correctPaint.color = colors.correctText
        answerPaint.color = colors.correctText
        pagePaint.color = colors.pageText
        hintPaint.color = colors.hintText
        clearBgPaint.color = colors.clearBg
        clearXStroke.color = colors.clearX
        chipPaint.color = colors.chipBg
        chipTextPaint.color = colors.chipText
        chipSelectedTextPaint.color = colors.chipSelectedText
        // 透明底色上给面板文字加描边（搜索框是白底深字，不加）。
        for (p in arrayOf(
            keyTextPaint, actionTextPaint, stemPaint, optionPaint,
            correctPaint, answerPaint, pagePaint, hintPaint,
            chipTextPaint, chipSelectedTextPaint,
        )) {
            p.setShadowLayer(
                if (colors.textShadow == Color.TRANSPARENT) 0f else dp(1.4f),
                0f, 0f, colors.textShadow,
            )
        }
    }

    // ---------- 状态 ----------
    private val input = StringBuilder()

    /** 只在这些题库里搜（null / 空 = 全部题库）；由开启页决定，窗口里不切换。 */
    var bankIds: Set<String>? = null
        private set

    /** 只搜这个题型（null = 全部题型），由筛选条切换。 */
    private var typeFilter: String? = null

    private var mode = Mode.KEYBOARD

    /** 一次搜索的多条结果（相关度从高到低）与当前查看的下标。 */
    private var resultItems: List<QuickSearchIndex.QItem> = emptyList()
    private var resultIndex = 0
    private val hit: QuickSearchIndex.QItem? get() = resultItems.getOrNull(resultIndex)

    /** 每次最多返回几道题，由开启页下发（默认 3）。 */
    private var maxResults = 3

    private var pressedId: String? = null
    private var dragging = false
    private var resizing = false
    private var lastRawX = 0f
    private var lastRawY = 0f
    private var scaleAnchorX = 1f
    private var scaleAnchorY = 1f

    /** 本次缩放手势累计的位移。只按「每帧增量」算的话，缩放永远停在锚点附近。 */
    private var scaleDragX = 0f
    private var scaleDragY = 0f

    /** 结果卡片上左右滑动切换多条结果。 */
    private var swipeCandidate = false
    private var swiping = false
    private var swipeAccum = 0f
    private var swipeLastX = 0f
    private var swipeStartY = 0f
    private val touchSlop =
        ViewConfiguration.get(context).scaledTouchSlop.toFloat()

    private var panelWidth = 0

    private val dragRect = RectF()
    /** 右下角缩放把手：键盘态在末行最右，结果态在卡片右下角。 */
    private val trayRect = RectF()
    private val closeRect = RectF()
    private val searchRect = RectF()
    private val filterRect = RectF()

    /** 搜索框右端的清除按钮热区（有内容才生效）。 */
    private val clearRect = RectF()

    /** 左下角收起标记：键盘态在末行最左，结果态在卡片左下角。 */
    private val hideRect = RectF()
    private val hideW get() = dp(32f)
    private val hideH get() = dp(28f)

    /** 底部两角把手各占的宽度：正文最后一行左右各让这么多，免得压在图标上。 */
    private val handleInset get() = hideW + dp(4f)

    private class Hit(val id: String, val rect: RectF)

    private val hits = ArrayList<Hit>(48)

    private var stemLayout: StaticLayout? = null
    private val optionLayouts = ArrayList<Pair<StaticLayout, Boolean>>()
    private var answerLabel = ""
    private var pageLabel = ""
    private var answerWidth = 0
    private var emptyHint: String? = null
    private var resultHeight = 0f

    // ---------- 对外 ----------
    /** 搜索框左上角在 View 内的偏移，宿主用它换算窗口位置。 */
    fun searchOffsetX(): Int = (searchRect.left * zoomX).toInt()
    fun searchOffsetY(): Int = (searchRect.top * zoomY).toInt()

    fun showResults(items: List<QuickSearchIndex.QItem>) {
        resultItems = items
        resultIndex = 0
        mode = Mode.RESULT
        pressedId = null
        requestLayout()
        invalidate()
    }

    fun showResult(item: QuickSearchIndex.QItem?) {
        showResults(if (item == null) emptyList() else listOf(item))
    }

    /** 每次最多显示几道题：设置变化时宿主重新下发，停在结果页就按新上限重搜。 */
    fun setMaxResults(value: Int) {
        val next = value.coerceIn(1, 9)
        if (next == maxResults) return
        maxResults = next
        refreshIfShowing()
    }

    fun showKeyboard() {
        mode = Mode.KEYBOARD
        pressedId = null
        requestLayout()
        invalidate()
    }

    fun currentQuery(): String = input.toString()

    /**
     * 设定搜索题库集合（null / 空集合 = 全部题库）。
     *
     * 开启页换了题库后会重新下发一次，这时如果已经停在结果页，就按新范围重搜一遍，
     * 不能让旧题库的答案留在窗口上。
     */
    fun setBankFilter(ids: Set<String>?) {
        val next = ids?.filter { it.isNotEmpty() }?.toSet()?.takeIf { it.isNotEmpty() }
        if (next == bankIds) return
        bankIds = next
        refreshIfShowing()
    }

    /** 恢复上次选的题型（不回调宿主、不重搜）。 */
    fun restoreTypeFilter(type: String?) {
        typeFilter = type?.takeIf { it.isNotEmpty() }
        requestLayout()
        invalidate()
    }

    private fun selectType(type: String?) {
        if (type == typeFilter) return
        typeFilter = type
        host?.onTypeFilterChanged(type)
        refreshIfShowing()
    }

    /** 首字母表刚重建好：按当前关键词补搜一次（换题库后不用用户再点一次搜索）。 */
    fun refreshResult() = refreshIfShowing()

    /** 停在结果页且有词时，按当前范围重搜；否则只重绘筛选条。 */
    private fun refreshIfShowing() {
        requestLayout()
        invalidate()
        if (mode != Mode.RESULT || input.isBlank()) return
        showResults(
            index.top(input.toString(), maxResults, type = typeFilter, bankIds = bankIds)
                .map { it.first },
        )
    }

    /** 回填搜索词并直接出结果（App 内降级浮窗复用这一条）。 */
    fun setQuery(text: String) {
        input.setLength(0)
        input.append(text)
        mode = Mode.RESULT
        showResults(
            index.top(text, maxResults, type = typeFilter, bankIds = bankIds)
                .map { it.first },
        )
    }

    /** 横竖分别缩放；两个方向都夹在 [MIN_SCALE] ~ [MAX_SCALE] 之间。 */
    fun applyScale(x: Float, y: Float) {
        val nx = x.coerceIn(MIN_SCALE, MAX_SCALE)
        val ny = y.coerceIn(MIN_SCALE, MAX_SCALE)
        if (nx == zoomX && ny == zoomY) return
        zoomX = nx
        zoomY = ny
        requestLayout()
        invalidate()
    }

    // ---------- 测量与布局 ----------
    override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
        val screenW = resources.displayMetrics.widthPixels
        val maxW = (screenW - density * 16f).toInt()
        // 拉宽后窗口不能超出屏幕：先把可用宽度按 zoomX 折回逻辑宽度再排版。
        val limit = (maxW / zoomX).toInt()
        val w = min(dp(320f).toInt(), limit).coerceAtLeast(min(dp(230f).toInt(), limit))
        panelWidth = w
        logicalWidth = w.toFloat()

        val contentW = w - padH * 2
        searchRect.set(padH, headerH, w - padH, headerH + searchH)
        // 清除按钮贴在搜索框右端，热区 26dp 见方（比视觉上的圆更大一点，好点）。
        clearRect.set(
            searchRect.right - dp(30f),
            searchRect.centerY() - dp(15f),
            searchRect.right,
            searchRect.centerY() + dp(15f),
        )
        filterRect.set(padH, filtersTop, w - padH, filtersTop + filterH)
        closeRect.set(w - traySize, 0f, w.toFloat(), headerH)
        // 顶部只留拖动区与关闭：收起、缩放都在底部两角，顶栏不再挤按钮。
        dragRect.set(traySize * 0.2f, 0f, closeRect.left, headerH)

        buildResultLayouts(contentW.toInt())
        val h = if (mode == Mode.KEYBOARD) keyboardHeight() else cardTopY + resultHeight + dp(8f)
        logicalHeight = h
        // 窗口尺寸按两个方向的缩放放大，内部排版仍是逻辑尺寸。
        setMeasuredDimension(
            (w * zoomX).toInt().coerceAtLeast(1),
            (h * zoomY).toInt().coerceAtLeast(1),
        )

        // 两个把手固定占底部两角：左下收起、右下缩放。缩放放右下后，
        // 手指往右下拖就是「变大」，和左上角固定、尺寸向右下长的逻辑一致。
        if (mode == Mode.KEYBOARD) {
            val lastRowTop = cardTopY + 4 * (keyH + keyGap)
            hideRect.set(padH, lastRowTop, padH + hideW, lastRowTop + keyH)
            trayRect.set(w - padH - hideW, lastRowTop, w - padH, lastRowTop + keyH)
        } else {
            val cardBottom = cardTopY + resultHeight
            val top = cardBottom - cardPad - hideH
            val left = padH + cardPad
            val right = w - padH - cardPad
            hideRect.set(left, top, left + hideW, cardBottom - cardPad)
            trayRect.set(right - hideW, top, right, cardBottom - cardPad)
        }
    }

    private fun keyboardRows(): List<List<String>> = listOf(
        listOf("1", "2", "3", "4", "5", "6", "7", "8", "9", "0"),
        listOf("Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"),
        listOf("A", "S", "D", "F", "G", "H", "J", "K", "L"),
        listOf("Z", "X", "C", "V", "B", "N", "M"),
    )

    /** 数字 + 3 行字母 + 1 行功能键。 */
    private fun keyboardHeight(): Float =
        cardTopY + 5 * (keyH + keyGap) + dp(6f)

    private fun buildResultLayouts(contentW: Int) {
        val inner = (contentW - (cardPad * 2).toInt()).coerceAtLeast(dp(80f).toInt())
        val item = hit
        optionLayouts.clear()
        if (item == null) {
            stemLayout = null
            answerLabel = ""
            pageLabel = ""
            answerWidth = (inner - handleInset * 2).toInt().coerceAtLeast(dp(60f).toInt())
            emptyHint = if (!bankIds.isNullOrEmpty() || typeFilter != null) {
                "当前筛选范围内没有匹配到题目"
            } else {
                "没有匹配到题目"
            }
            resultHeight = cardPad * 2 + dp(28f)
            return
        }
        emptyHint = null
        stemLayout = staticLayout(item.stem, stemPaint, inner, maxLines = 5)
        // 选项与答案都由索引预先转好文案：判断题是「正确 / 错误」，不会露出 true。
        for (row in item.displayOptions().take(8)) {
            val paint = if (row.correct) correctPaint else optionPaint
            optionLayouts.add(staticLayout(row.text, paint, inner, maxLines = 3) to row.correct)
        }
        val answer = item.displayAnswer()
        // 答案在左、页码在右，同一行内各自排版；页码不再拼进答案文本，
        // 免得「答案：B  1/3」看起来像一个整体。
        answerLabel = if (answer.isNotEmpty()) "答案：$answer" else ""
        pageLabel = if (resultItems.size > 1) {
            "${resultIndex + 1}/${resultItems.size}"
        } else {
            ""
        }
        val pageW = if (pageLabel.isNotEmpty()) {
            pagePaint.measureText(pageLabel) + dp(12f)
        } else {
            0f
        }
        // 最后一行左右两个把手都要避开：答案从左侧让位后开始，页码整体左移。
        answerWidth = (inner - pageW - handleInset * 2).toInt()
            .coerceAtLeast(dp(80f).toInt())
        var h = cardPad * 2 + stemLayout!!.height.toFloat() + dp(5f)
        for ((layout, _) in optionLayouts) {
            h += layout.height.toFloat() + dp(2f)
        }
        if (answerLabel.isNotEmpty() || pageLabel.isNotEmpty()) {
            val rowH = if (answerLabel.isNotEmpty()) {
                staticLayout(answerLabel, answerPaint, answerWidth, 2).height.toFloat()
            } else {
                answerPaint.textSize * 1.4f
            }
            h += rowH + dp(3f)
        }
        resultHeight = h
    }

    private fun staticLayout(
        text: String,
        paint: TextPaint,
        width: Int,
        maxLines: Int,
    ): StaticLayout {
        val builder = StaticLayout.Builder.obtain(text, 0, text.length, paint, width)
            .setAlignment(Layout.Alignment.ALIGN_NORMAL)
            .setIncludePad(false)
            .setLineSpacing(0f, 1.12f)
        if (maxLines > 0) {
            builder.setMaxLines(maxLines).setEllipsize(TextUtils.TruncateAt.END)
        }
        return builder.build()
    }

    // ---------- 绘制 ----------
    override fun onDraw(canvas: Canvas) {
        hits.clear()
        // 之后所有绘制都按逻辑坐标走，横竖缩放交给画布。
        canvas.save()
        canvas.scale(zoomX, zoomY)
        val panel = RectF(0f, 0f, logicalWidth, logicalHeight)
        canvas.drawRoundRect(panel, panelRadius, panelRadius, panelPaint)

        drawHeader(canvas)
        drawSearchBox(canvas)
        drawFilterBar(canvas)

        if (mode == Mode.KEYBOARD) {
            drawKeyboard(canvas)
        } else {
            drawResult(canvas)
        }
        // 两个把手最后画：命中表按后加入的优先，压住重叠的按键 / 卡片区域。
        drawHideHandle(canvas)
        drawResizeHandle(canvas)
        canvas.restore()
    }

    /** 左下角的收起：双下箭头，点一下缩成屏幕边上的小球。 */
    private fun drawHideHandle(canvas: Canvas) {
        hits.add(Hit("hide", hideRect))
        val p = Paint(iconPaint).apply {
            color = if (pressedId == "hide") colors.iconPressed else colors.icon
            strokeWidth = dp(1.8f)
        }
        OverlayGlyphs.drawCollapse(
            canvas,
            hideRect.centerX(),
            hideRect.centerY(),
            density,
            p,
        )
    }

    /** 右下角的缩放把手：斜向双箭头，拖它横竖分别改宽高。 */
    private fun drawResizeHandle(canvas: Canvas) {
        hits.add(Hit("scale", trayRect))
        val p = Paint(iconPaint).apply {
            color = if (pressedId == "scale") colors.iconPressed else colors.icon
            strokeWidth = dp(1.7f)
        }
        OverlayGlyphs.drawResize(
            canvas,
            trayRect.centerX(),
            trayRect.centerY(),
            density,
            p,
        )
    }

    /** 顶部：整条拖动区，右端关闭。 */
    private fun drawHeader(canvas: Canvas) {
        hits.add(Hit("drag", dragRect))
        val grip = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = if (pressedId == "drag") colors.iconPressed else colors.grip
            style = Paint.Style.FILL
        }
        val cy = headerH / 2f
        val cx = dragRect.left + dp(10f)
        for (i in 0..1) {
            val x = cx + i * dp(4f)
            canvas.drawCircle(x, cy, dp(1.4f), grip)
        }

        // 关闭
        hits.add(Hit("close", closeRect))
        val ccx = closeRect.centerX()
        val ccy = closeRect.centerY()
        val r = dp(5.8f)
        val cPaint = Paint(iconPaint).apply {
            color = if (pressedId == "close") colors.iconPressed else colors.icon
            strokeWidth = dp(1.7f)
        }
        canvas.drawLine(ccx - r, ccy - r, ccx + r, ccy + r, cPaint)
        canvas.drawLine(ccx - r, ccy + r, ccx + r, ccy - r, cPaint)
    }

    /**
     * 搜索框下面一行题型筛选：等宽小胶囊，选中是绿底白字。
     *
     * 题库由开启页决定，这里只切题型；切换后如果已经出过结果，会按新范围重搜。
     */
    private fun drawFilterBar(canvas: Canvas) {
        val labels = TYPE_LABELS
        val count = labels.size
        val gap = dp(3f)
        val cell = (filterRect.width() - gap * (count - 1)) / count
        for (i in 0 until count) {
            val left = filterRect.left + i * (cell + gap)
            val rect = RectF(left, filterRect.top, left + cell, filterRect.bottom)
            val selected = typeFilter == TYPE_KEYS[i]
            canvas.drawRoundRect(
                rect,
                filterH / 2f,
                filterH / 2f,
                if (selected) greenPaint else chipPaint,
            )
            val paint = if (selected) chipSelectedTextPaint else chipTextPaint
            val baseline = rect.centerY() - (paint.descent() + paint.ascent()) / 2f
            canvas.drawText(labels[i], rect.centerX(), baseline, paint)
            hits.add(Hit("type:$i", rect))
        }
    }

    private fun drawSearchBox(canvas: Canvas) {
        canvas.drawRoundRect(searchRect, searchH / 2f, searchH / 2f, searchBgPaint)
        val iconCx = searchRect.left + dp(14f)
        val iconCy = searchRect.centerY()
        val icon = Paint(iconPaint).apply {
            color = colors.placeholder
            strokeWidth = dp(1.4f)
        }
        canvas.drawCircle(iconCx, iconCy - dp(1f), dp(4.6f), icon)
        canvas.drawLine(
            iconCx + dp(3.4f), iconCy + dp(2.4f),
            iconCx + dp(6.2f), iconCy + dp(5.2f), icon
        )

        val text = input.toString()
        val textLeft = searchRect.left + dp(25f)
        // 有内容时右端给清除按钮让出位置，长词滚动时也不会压到叉上。
        val textRight = searchRect.right - (if (text.isEmpty()) dp(8f) else dp(30f))
        val baseline = searchRect.centerY() - (searchTextPaint.descent() + searchTextPaint.ascent()) / 2f
        canvas.save()
        canvas.clipRect(textLeft, searchRect.top, textRight, searchRect.bottom)
        if (text.isEmpty()) {
            canvas.drawText(PLACEHOLDER, textLeft, baseline, placeholderPaint)
        } else {
            val textW = searchTextPaint.measureText(text)
            val shift = max(0f, textW - (textRight - textLeft))
            canvas.translate(-shift, 0f)
            canvas.drawText(text, textLeft, baseline, searchTextPaint)
            // 简易光标：细竖线跟在文字后面，不做闪烁（避免持续重绘耗电）。
            canvas.drawRect(
                textLeft + textW + dp(1f), searchRect.centerY() - dp(6.5f),
                textLeft + textW + dp(2f), searchRect.centerY() + dp(6.5f),
                Paint(Paint.ANTI_ALIAS_FLAG).apply { color = colors.cursor }
            )
        }
        canvas.restore()
        hits.add(Hit("search", searchRect))
        // 没有输入时不画叉，免得空框里挂个没用的按钮。
        if (text.isNotEmpty()) drawClearButton(canvas)
    }

    /** 搜索框右端的清除按钮：点一下清空整个输入（不逐字删）。 */
    private fun drawClearButton(canvas: Canvas) {
        val cx = clearRect.centerX()
        val cy = clearRect.centerY()
        canvas.drawCircle(cx, cy, dp(10f), clearBgPaint)
        val r = dp(4.8f)
        canvas.drawLine(cx - r, cy - r, cx + r, cy + r, clearXStroke)
        canvas.drawLine(cx + r, cy - r, cx - r, cy + r, clearXStroke)
        hits.add(Hit("clear", clearRect))
    }

    /**
     * 键盘：1 行数字 + 3 行字母 + 1 行功能键。
     * 字母末行左端是「撤销」，最末行两端是收起 / 缩放把手，中间是空格 / 搜索。
     */
    private fun drawKeyboard(canvas: Canvas) {
        var top = cardTopY
        val contentLeft = padH
        val contentW = logicalWidth.toInt() - padH * 2
        val rows = keyboardRows()
        for ((rowIndex, row) in rows.withIndex()) {
            if (rowIndex < rows.lastIndex) {
                val unit = (contentW - keyGap * (row.size - 1)) / row.size
                var x = contentLeft
                for (key in row) {
                    val rect = RectF(x, top, x + unit, top + keyH)
                    drawKey(canvas, rect, key, "key:$key", false)
                    x += unit + keyGap
                }
            } else {
                val wide = 1.25f
                val units = row.size + wide
                val unit = (contentW - keyGap * (units - 1)) / units
                val undoW = unit * wide
                var x = contentLeft
                drawKey(canvas, RectF(x, top, x + undoW, top + keyH), "撤销", "undo", false)
                x += undoW + keyGap
                for (key in row) {
                    val rect = RectF(x, top, x + unit, top + keyH)
                    drawKey(canvas, rect, key, "key:$key", false)
                    x += unit + keyGap
                }
            }
            top += keyH + keyGap
        }
        // 末行两端留给左下收起 / 右下缩放，中间按 1.1 : 2.1 分给空格与搜索。
        val middleLeft = contentLeft + hideW + keyGap
        val middleRight = logicalWidth - padH - hideW - keyGap
        val units = 1.1f + 2.1f
        val unit = (middleRight - middleLeft - keyGap) / units
        val space = RectF(middleLeft, top, middleLeft + unit * 1.1f, top + keyH)
        drawKey(canvas, space, "空格", "space", false)
        drawKey(
            canvas,
            RectF(space.right + keyGap, top, middleRight, top + keyH),
            "搜索", "go", true,
        )
    }

    private fun drawKey(canvas: Canvas, rect: RectF, label: String, id: String, green: Boolean) {
        hits.add(Hit(id, rect))
        val pressed = pressedId == id
        val bg = when {
            green && pressed -> greenPressedPaint
            green -> greenPaint
            pressed -> keyPressedPaint
            else -> keyPaint
        }
        canvas.drawRoundRect(rect, dp(6f), dp(6f), bg)
        val paint = if (id.startsWith("key:")) keyTextPaint else actionTextPaint
        val baseline = rect.centerY() - (paint.descent() + paint.ascent()) / 2f
        canvas.drawText(label, rect.centerX(), baseline, paint)
    }

    private fun drawResult(canvas: Canvas) {
        val cardTop = cardTopY
        val card = RectF(padH, cardTop, logicalWidth - padH, cardTop + resultHeight)
        canvas.drawRoundRect(card, dp(9f), dp(9f), cardPaint)
        val left = card.left + cardPad
        val innerW = (card.width() - cardPad * 2).toInt()

        if (hit == null) {
            val hint = emptyHint ?: "没有匹配到题目"
            val hintW = (innerW - handleInset * 2).toInt().coerceAtLeast(dp(60f).toInt())
            val layout = staticLayout(hint, hintPaint, hintW, 2)
            canvas.save()
            canvas.translate(left + handleInset, card.top + cardPad)
            layout.draw(canvas)
            canvas.restore()
            return
        }

        var y = card.top + cardPad
        stemLayout?.let {
            canvas.save()
            canvas.translate(left, y)
            it.draw(canvas)
            canvas.restore()
            y += it.height + dp(5f)
        }
        // 选项（正确项蓝色高亮），答案行放最后。
        for ((layout, _) in optionLayouts) {
            canvas.save()
            canvas.translate(left, y)
            layout.draw(canvas)
            canvas.restore()
            y += layout.height + dp(2f)
        }
        if (answerLabel.isNotEmpty() || pageLabel.isNotEmpty()) {
            val rowTop = y + dp(3f)
            if (answerLabel.isNotEmpty()) {
                val answerLayout =
                    staticLayout(answerLabel, answerPaint, answerWidth, 2)
                canvas.save()
                canvas.translate(left + handleInset, rowTop)
                answerLayout.draw(canvas)
                canvas.restore()
            }
            if (pageLabel.isNotEmpty()) {
                // 与答案首行基线对齐，右端让开右下角的缩放把手。
                val baseline = rowTop - answerPaint.ascent()
                canvas.drawText(
                    pageLabel,
                    card.right - cardPad - handleInset,
                    baseline,
                    pagePaint,
                )
            }
        }

        // 早期这里有一个「改词」按钮，点搜索框本来就能回键盘，删掉省一行高度。
    }

    // ---------- 触摸 ----------
    override fun onTouchEvent(event: MotionEvent): Boolean {
        // 窗口按缩放放大过，命中测试用逻辑坐标，缩放比要除回去。
        val x = event.x / zoomX
        val y = event.y / zoomY
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val found = hitAt(x, y)
                pressedId = found?.id
                when (found?.id) {
                    "drag" -> {
                        dragging = true
                        lastRawX = event.rawX
                        lastRawY = event.rawY
                    }
                    "scale" -> {
                        resizing = true
                        lastRawX = event.rawX
                        lastRawY = event.rawY
                        scaleAnchorX = zoomX
                        scaleAnchorY = zoomY
                        scaleDragX = 0f
                        scaleDragY = 0f
                    }
                }
                // 结果卡片空白处按下：可能是要左右滑动切换多条结果。
                swipeCandidate = found == null &&
                    mode == Mode.RESULT &&
                    resultItems.size > 1 &&
                    y >= cardTopY &&
                    y <= cardTopY + resultHeight
                if (swipeCandidate) {
                    swiping = false
                    swipeAccum = 0f
                    swipeLastX = event.rawX
                    swipeStartY = y
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
                    if (dx != 0f || dy != 0f) host?.onDragBy(dx, dy)
                } else if (resizing) {
                    // 横拖只改宽度、竖拖只改高度，斜着拖两个方向一起变。
                    // 位移必须累加：拿「锚点 + 本帧增量」会把前面拖的全丢掉，
                    // 表现就是窗口原地抖一下、尺寸始终不变。
                    scaleDragX += event.rawX - lastRawX
                    scaleDragY += event.rawY - lastRawY
                    lastRawX = event.rawX
                    lastRawY = event.rawY
                    host?.onScaleChanged(
                        scaleAnchorX + scaleDragX / (density * 200f),
                        scaleAnchorY + scaleDragY / (density * 200f),
                    )
                } else if (swipeCandidate) {
                    val dx = event.rawX - swipeLastX
                    val dy = y - swipeStartY
                    swipeLastX = event.rawX
                    swipeAccum += dx
                    // 横向位移明显大于竖向才算滑动，避免上下看长题时误切结果。
                    if (!swiping && abs(swipeAccum) > touchSlop && abs(swipeAccum) > abs(dy)) {
                        swiping = true
                    }
                }
                return true
            }
            MotionEvent.ACTION_UP -> {
                val moved = dragging || resizing || swiping
                val resized = resizing
                val swiped = swiping
                val swipedBy = swipeAccum
                dragging = false
                resizing = false
                swipeCandidate = false
                swiping = false
                swipeAccum = 0f
                if (resized) host?.onScaleFinished()
                val found = hitAt(x, y)
                val pressed = pressedId
                pressedId = null
                invalidate()
                if (!moved && found != null && found.id == pressed) {
                    perform(found.id)
                } else if (swiped) {
                    // 左滑看下一条、右滑看上一条。
                    if (swipedBy <= -dp(36f)) {
                        stepResult(1)
                    } else if (swipedBy >= dp(36f)) {
                        stepResult(-1)
                    }
                }
                return true
            }
            MotionEvent.ACTION_CANCEL -> {
                if (resizing) host?.onScaleFinished()
                dragging = false
                resizing = false
                swipeCandidate = false
                swiping = false
                swipeAccum = 0f
                pressedId = null
                invalidate()
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    private fun hitAt(x: Float, y: Float): Hit? =
        hits.lastOrNull { it.rect.contains(x, y) }

    /** 切换当前查看的结果条目：左滑看下一条（+1），右滑看上一条（-1）。 */
    private fun stepResult(delta: Int) {
        if (resultItems.size <= 1) return
        val next = (resultIndex + delta).coerceIn(0, resultItems.size - 1)
        if (next == resultIndex) return
        resultIndex = next
        requestLayout()
        invalidate()
    }

    private fun perform(id: String) {
        when {
            id == "close" -> host?.onClose()
            id == "hide" -> host?.onMinimize()
            id == "search" -> if (mode == Mode.RESULT) showKeyboard()
            id == "clear" -> clearInput()
            id == "undo" -> undo()
            id == "space" -> space()
            id == "go" -> search()
            id.startsWith("type:") -> {
                val index = id.removePrefix("type:").toIntOrNull() ?: return
                if (index in TYPE_KEYS.indices) selectType(TYPE_KEYS[index])
            }
            id.startsWith("key:") -> typeChar(id.removePrefix("key:").lowercase())
        }
    }

    private fun typeChar(ch: String) {
        if (input.length < 60) input.append(ch)
        invalidate()
    }

    private fun undo() {
        if (input.isNotEmpty()) input.deleteCharAt(input.length - 1)
        invalidate()
    }

    /**
     * 一键清空输入。
     *
     * 停在结果页时顺手退回键盘：词都清空了还挂着上一轮的答案，看着像是「空框也能搜到题」。
     */
    private fun clearInput() {
        if (input.isEmpty()) return
        input.setLength(0)
        if (mode == Mode.RESULT) {
            showKeyboard()
        } else {
            requestLayout()
            invalidate()
        }
    }

    private fun space() {
        if (input.isNotEmpty() && input.length < 60) input.append(' ')
        invalidate()
    }

    private fun search() {
        if (input.isBlank()) return
        showResults(
            index.top(input.toString(), maxResults, type = typeFilter, bankIds = bankIds)
                .map { it.first },
        )
    }

    override fun onDetachedFromWindow() {
        host = null
        super.onDetachedFromWindow()
    }

    companion object {
        private const val PLACEHOLDER = "输首字母或数字，如 aq"
        const val MIN_SCALE = 0.7f
        const val MAX_SCALE = 1.8f

        /** 题型筛选条：与 QuestionType.key 对齐，第一位是「全部」。 */
        private val TYPE_LABELS = arrayOf("全部", "单选", "多选", "判断", "填空", "简答")
        private val TYPE_KEYS = arrayOf<String?>(
            null, "single", "multiple", "true_false", "fill", "short",
        )
    }
}
