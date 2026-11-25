import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';

/// 刷题模块的仓库入口（进程内缓存，避免重复打开数据库）。
class QuizServices {
  static Future<QuizRepository>? _future;

  /// 测试注入用（Widget 测试里无法使用 sqflite 插件工厂）。
  static QuizRepository? testRepo;

  static Future<QuizRepository> repo() {
    final injected = testRepo;
    if (injected != null) return Future<QuizRepository>.value(injected);
    return _future ??= QuizDb.instance().then((db) => QuizRepository(db.db));
  }

  /// 测试用：重置缓存。
  static void reset() {
    _future = null;
    testRepo = null;
  }
}

/// 题型名称。
String typeLabel(QuestionType type) => switch (type) {
      QuestionType.single => tr('单选'),
      QuestionType.multiple => tr('多选'),
      QuestionType.trueFalse => tr('判断'),
      QuestionType.fill => tr('填空'),
      QuestionType.short => tr('简答'),
    };

/// 作答状态名称。
String stateLabel(AnswerState state) => switch (state) {
      AnswerState.correct => tr('正确'),
      AnswerState.wrong => tr('错误'),
      AnswerState.pending => tr('待自评'),
      AnswerState.unanswered => tr('未答'),
    };

Color stateColor(BuildContext context, AnswerState state) => switch (state) {
      AnswerState.correct => Colors.green,
      AnswerState.wrong => Colors.red,
      AnswerState.pending => Colors.orange,
      AnswerState.unanswered => Theme.of(context).colorScheme.outline,
    };

/// 毫秒 → mm:ss。
String clockText(int ms) {
  final total = ms < 0 ? 0 : ms ~/ 1000;
  final m = total ~/ 60;
  final s = total % 60;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

/// 通用空态（统一走 [EmptyState]）。
class QuizEmpty extends StatelessWidget {
  const QuizEmpty(this.text, {super.key, this.icon = Icons.inbox_outlined});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) => EmptyState(text: text, icon: icon);
}

// ---------------------------------------------------------------------------
// 刷题工具专用字号
// ---------------------------------------------------------------------------

/// 刷题模块整体字号的放大系数与增量。
///
/// 题干、选项、解析、题库列表、统计数字、按钮、标签等「各个不同内容」统一按
/// 同一比例放大，保留原有的层级关系；只作用于刷题工具内的页面，不影响全局
/// 字体大小设置，也不影响其他工具。
const double kQuizFontScale = 1.10;
const double kQuizFontDelta = 0.5;

double? _growSize(double? size) =>
    size == null ? null : size * kQuizFontScale + kQuizFontDelta;

TextStyle? _grow(TextStyle? style) =>
    style?.copyWith(fontSize: _growSize(style.fontSize));

/// 按钮/输入等组件的字号是按状态解析的 [WidgetStateProperty]，需要逐状态放大。
WidgetStateProperty<TextStyle?>? _growStateStyle(
  WidgetStateProperty<TextStyle?>? property,
) =>
    property == null
        ? null
        : WidgetStateProperty.resolveWith<TextStyle?>(
            (states) => _grow(property.resolve(states)),
          );

/// 在全局主题基础上，把刷题工具内各类文字统一放大一档。
///
/// 除了 [TextTheme]（题干、选项、解析等正文），也同步放大按钮、标签、列表、
/// 输入框、弹窗等自带硬编码字号的组件主题，避免「正文变大了、控件没变」。
ThemeData quizThemeOf(BuildContext context) {
  final theme = Theme.of(context);
  return theme.copyWith(
    textTheme: theme.textTheme.apply(
      fontSizeFactor: kQuizFontScale,
      fontSizeDelta: kQuizFontDelta,
    ),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: _grow(theme.appBarTheme.titleTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style?.copyWith(
        textStyle: _growStateStyle(theme.filledButtonTheme.style?.textStyle),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: theme.outlinedButtonTheme.style?.copyWith(
        textStyle: _growStateStyle(theme.outlinedButtonTheme.style?.textStyle),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: theme.textButtonTheme.style?.copyWith(
        textStyle: _growStateStyle(theme.textButtonTheme.style?.textStyle),
      ),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: _grow(theme.chipTheme.labelStyle),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: _grow(theme.listTileTheme.titleTextStyle),
      subtitleTextStyle: _grow(theme.listTileTheme.subtitleTextStyle),
    ),
    inputDecorationTheme: theme.inputDecorationTheme.copyWith(
      hintStyle: _grow(theme.inputDecorationTheme.hintStyle),
      labelStyle: _grow(theme.inputDecorationTheme.labelStyle),
      floatingLabelStyle: _grow(theme.inputDecorationTheme.floatingLabelStyle),
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: _grow(theme.dialogTheme.titleTextStyle),
      contentTextStyle: _grow(theme.dialogTheme.contentTextStyle),
    ),
    popupMenuTheme: theme.popupMenuTheme.copyWith(
      textStyle: _grow(theme.popupMenuTheme.textStyle),
    ),
    snackBarTheme: theme.snackBarTheme.copyWith(
      contentTextStyle: _grow(theme.snackBarTheme.contentTextStyle),
    ),
    sliderTheme: theme.sliderTheme.copyWith(
      valueIndicatorTextStyle: _grow(theme.sliderTheme.valueIndicatorTextStyle),
    ),
  );
}

/// 标记当前子树已套用刷题字号，防止嵌套或路由继承主题时重复放大。
///
/// 继承 [InheritedTheme] 是为了让对话/底部弹层（会通过
/// `InheritedTheme.capture` 继承祖先主题）也能识别到标记。
class _QuizScopeMarker extends InheritedTheme {
  const _QuizScopeMarker({required super.child});

  static bool isActive(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_QuizScopeMarker>() != null;

  @override
  Widget wrap(BuildContext context, Widget child) =>
      _QuizScopeMarker(child: child);

  @override
  bool updateShouldNotify(covariant _QuizScopeMarker oldWidget) => false;
}

/// 刷题工具页面根：统一放大本工具内所有文字。
///
/// 对话、底部弹层会继承这里的 [Theme]，无需重复包裹；全屏子页面统一走
/// [quizRoute] 各自套一层，退出到别的工具后字号自动恢复。
class QuizScope extends StatelessWidget {
  const QuizScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (_QuizScopeMarker.isActive(context)) return child;
    return _QuizScopeMarker(
      child: Theme(data: quizThemeOf(context), child: child),
    );
  }
}

/// 刷题工具内所有全屏页面都走这里，自动套上 [QuizScope]。
MaterialPageRoute<T> quizRoute<T>({required WidgetBuilder builder}) =>
    MaterialPageRoute<T>(
      builder: (context) => QuizScope(child: Builder(builder: builder)),
    );

/// 题库多选弹层：勾选一个或多个题库作为搜索范围。
///
/// 一个都不勾 = 全部题库（首行「全部题库」勾上即清空选择）。返回勾选的
/// id 集合，空集合表示不限题库；用户直接关掉弹层返回 null。
class BankMultiSheet extends StatefulWidget {
  const BankMultiSheet({
    super.key,
    required this.banks,
    required this.selected,
  });

  final List<Bank> banks;

  /// 打开时的已选 id；空集合表示全部题库。
  final Set<String> selected;

  @override
  State<BankMultiSheet> createState() => _BankMultiSheetState();
}

class _BankMultiSheetState extends State<BankMultiSheet> {
  late final Set<String> _picked = <String>{...widget.selected};

  int get _total =>
      widget.banks.fold<int>(0, (sum, b) => sum + b.questionCount);

  int get _count {
    if (_picked.isEmpty) return _total;
    return widget.banks
        .where((b) => _picked.contains(b.id))
        .fold<int>(0, (sum, b) => sum + b.questionCount);
  }

  void _toggle(String id) {
    setState(() {
      if (!_picked.remove(id)) _picked.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    tr('选择题库'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                SmallHint(text: trf('共 {n} 题', {'n': _count})),
              ],
            ),
          ),
          // 题库多时列表自己滚动；Flexible 让标题和底部按钮始终留在弹层里。
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: <Widget>[
                CheckboxListTile(
                  key: const ValueKey('bank-sheet-all'),
                  dense: true,
                  value: _picked.isEmpty,
                  title: Text(tr('全部题库')),
                  subtitle: Text(trf('共 {n} 题', {'n': _total})),
                  onChanged: (_) => setState(_picked.clear),
                ),
                for (final bank in widget.banks)
                  CheckboxListTile(
                    key: ValueKey<String>('bank-sheet-${bank.id}'),
                    dense: true,
                    value: _picked.contains(bank.id),
                    title: Text(
                      bank.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(trf('共 {n} 题', {'n': bank.questionCount})),
                    onChanged: (_) => _toggle(bank.id),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 16, 6),
            child: Row(
              children: <Widget>[
                TextButton(
                  key: const ValueKey('bank-sheet-clear'),
                  onPressed:
                      _picked.isEmpty ? null : () => setState(_picked.clear),
                  child: Text(tr('清除')),
                ),
                const Spacer(),
                FilledButton(
                  key: const ValueKey('bank-sheet-ok'),
                  onPressed: () => Navigator.of(context).pop(_picked),
                  child: Text(tr('确定')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 毫秒时间戳 →「11月13日 12:05」；无效值返回「--」。
String dateLabelOf(int millis) {
  if (millis <= 0) return '--';
  final time = DateTime.fromMillisecondsSinceEpoch(millis);
  final hm = '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';
  return '${time.month}月${time.day}日 $hm';
}

/// 答题页主题色渐变背景：顶部淡淡一层主题色，向下过渡到页面底色。
///
/// 亮色模式混入约 9%、暗色模式约 16% 的主题色，换主题色 / 暗色模式自动跟随；
/// 不遮挡内容，也不需要处理叠字对比度。
class QuizBackdrop extends StatelessWidget {
  const QuizBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final top = Color.lerp(
      scheme.surface,
      scheme.primary,
      theme.brightness == Brightness.dark ? 0.16 : 0.09,
    )!;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: <Color>[top, scheme.surface],
        ),
      ),
      child: child,
    );
  }
}

/// 答题页顶部细进度条：已答 / 总题数，主题色填充。
class QuizProgressBar extends StatelessWidget {
  const QuizProgressBar({
    super.key,
    required this.answered,
    required this.total,
  });

  final int answered;
  final int total;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LinearProgressIndicator(
      value: total <= 0 ? 0 : (answered / total).clamp(0.0, 1.0),
      minHeight: 3,
      backgroundColor: scheme.primary.withOpacity(0.14),
      valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
    );
  }
}

/// 三步引导：圆形序号 + 说明 + 连接线，快捷搜题与智能搜题共用。
class QuizSteps extends StatelessWidget {
  const QuizSteps({super.key, required this.steps});

  final List<String> steps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (var i = 0; i < steps.length; i++) ...<Widget>[
          Expanded(
            child: Column(
              children: <Widget>[
                Container(
                  width: 24,
                  height: 24,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Text(
                    '${i + 1}',
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  steps[i],
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
          if (i < steps.length - 1)
            Padding(
              padding: const EdgeInsets.only(top: 11),
              child: SizedBox(
                width: 22,
                child: Divider(
                  height: 2,
                  thickness: 2,
                  color: scheme.primary.withOpacity(0.35),
                ),
              ),
            ),
        ],
      ],
    );
  }
}
