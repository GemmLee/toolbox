import 'package:flutter/material.dart';

import '../../../../core/settings/tool_texts.dart';
import '../../../../core/widgets/app_widgets.dart';
import '../data/quiz_models.dart';
import '../data/quiz_repository.dart';

/// 调整题库顺序：拖动右侧把手即可，改动立即保存；右上角可恢复默认顺序。
class QuizBankOrderPage extends StatefulWidget {
  const QuizBankOrderPage({super.key, required this.repo});

  final QuizRepository repo;

  @override
  State<QuizBankOrderPage> createState() => _QuizBankOrderPageState();
}

class _QuizBankOrderPageState extends State<QuizBankOrderPage> {
  List<Bank>? _items;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final banks = await widget.repo.listBanks();
    if (!mounted) return;
    setState(() => _items = banks);
  }

  void _reorder(int oldIndex, int newIndex) {
    final items = _items;
    if (items == null) return;
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final moved = items.removeAt(oldIndex);
      items.insert(newIndex, moved);
    });
    widget.repo.saveBankOrder(
      <String>[for (final bank in items) bank.id],
    );
  }

  Future<void> _reset() async {
    await widget.repo.resetBankOrder();
    await _load();
    if (!mounted) return;
    showToast(context, tr('已恢复默认顺序'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('题库顺序')),
        actions: <Widget>[
          InfoHint(text: tr('按住右侧把手拖动排序，改动立即保存')),
          TextButton(
            key: const ValueKey('bank-order-reset'),
            onPressed: _reset,
            child: Text(tr('重置顺序')),
          ),
        ],
      ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : ReorderableListView.builder(
              key: const ValueKey('bank-order-list'),
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              buildDefaultDragHandles: false,
              itemCount: items.length,
              onReorder: _reorder,
              itemBuilder: (context, index) {
                final bank = items[index];
                return Card(
                  key: ValueKey<String>('bank-order-${bank.id}'),
                  margin: const EdgeInsets.symmetric(vertical: 3),
                  clipBehavior: Clip.antiAlias,
                  child: ListTile(
                    dense: true,
                    minLeadingWidth: 24,
                    visualDensity: VisualDensity.compact,
                    leading: Icon(Icons.library_books_outlined,
                        color: theme.colorScheme.primary, size: 22),
                    title: Text(bank.name,
                        maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(trf('共 {n} 题', {'n': bank.questionCount})),
                    trailing: ReorderableDragStartListener(
                      index: index,
                      child: const Padding(
                        padding: EdgeInsets.all(8),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
