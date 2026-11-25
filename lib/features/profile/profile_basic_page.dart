import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/settings/tool_texts.dart';
import '../../core/widgets/app_widgets.dart';
import '../tools/salary/city_rules.dart';
import 'profile_model.dart';
import 'profile_repository.dart';

/// 基本信息：城市与工资/缴费基数，全部选填。
class ProfileBasicPage extends StatefulWidget {
  const ProfileBasicPage({super.key});

  @override
  State<ProfileBasicPage> createState() => _ProfileBasicPageState();
}

class _ProfileBasicPageState extends State<ProfileBasicPage> {
  final TextEditingController _gross = TextEditingController();
  final TextEditingController _socialBase = TextEditingController();
  final TextEditingController _fundBase = TextEditingController();
  final TextEditingController _specialDeduction = TextEditingController();

  UserProfile _profile = UserProfile();
  String _cityId = CityRules.defaultCityId;
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _gross.dispose();
    _socialBase.dispose();
    _fundBase.dispose();
    _specialDeduction.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final profile = await ProfileRepository.load();
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _cityId = profile.cityId;
      _gross.text = textOf(profile.gross);
      _socialBase.text = textOf(profile.socialBase);
      _fundBase.text = textOf(profile.fundBase);
      _specialDeduction.text = textOf(profile.specialDeduction);
      _loading = false;
    });
  }

  Future<void> _save() async {
    final l10n = AppL10n.of();
    setState(() => _saving = true);
    final profile = await ProfileRepository.update((data) {
      UserProfile.putCity(data, _cityId);
      UserProfile.putNumber(data, 'gross', _gross.text);
      UserProfile.putNumber(data, 'socialBase', _socialBase.text);
      UserProfile.putNumber(data, 'fundBase', _fundBase.text);
      UserProfile.putNumber(
        data,
        UserProfile.specialDeductionKey,
        _specialDeduction.text,
      );
    });
    if (!mounted) return;
    setState(() {
      _profile = profile;
      _saving = false;
    });
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          profile.isEmpty ? l10n.snackbarSavedEmpty : l10n.snackbarSaved,
        ),
      ),
    );
  }

  Future<void> _clear() async {
    final l10n = AppL10n.of();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.clearDialogTitle),
        content: Text(l10n.clearDialogContent),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.confirmClear),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ProfileRepository.clear();
    if (!mounted) return;
    setState(() {
      _profile = UserProfile();
      _cityId = CityRules.defaultCityId;
      _gross.clear();
      _socialBase.clear();
      _fundBase.clear();
      _specialDeduction.clear();
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(l10n.snackbarCleared)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppL10n.of();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.basicInfo)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                SectionCard(
                  title: l10n.basicInfo,
                  children: [
                    DropdownButtonFormField<String>(
                      value: _cityId,
                      isExpanded: true,
                      decoration: InputDecoration(labelText: l10n.cityLabel),
                      items: CityRules.all
                          .map(
                            (city) => DropdownMenuItem<String>(
                              value: city.id,
                              child: Text(tr(city.name)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _cityId = value);
                      },
                    ),
                    const SizedBox(height: 12),
                    NumberField(
                      controller: _gross,
                      label: l10n.grossLabel,
                      suffix: l10n.currencySuffix,
                      hint: l10n.grossHint,
                    ),
                    NumberField(
                      controller: _socialBase,
                      label: l10n.socialBaseLabel,
                      suffix: l10n.currencySuffix,
                    ),
                    NumberField(
                      controller: _fundBase,
                      label: l10n.fundBaseLabel,
                      suffix: l10n.currencySuffix,
                    ),
                    NumberField(
                      controller: _specialDeduction,
                      label: tr('每月专项附加扣除'),
                      suffix: tr('元/月'),
                      outerPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined),
                  label: Text(_saving ? l10n.savingProfile : l10n.saveProfile),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                TextButton.icon(
                  onPressed: _saving ? null : _clear,
                  icon: const Icon(Icons.delete_outline),
                  label: Text(l10n.clearProfile),
                ),
                const SizedBox(height: 4),
                Center(
                  child: Text(
                    _profile.isEmpty
                        ? l10n.filledNone
                        : l10n.filledCount(_profile.filledCount),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Center(
                  child: SmallHint(
                    text: tr('保存后会写入「存储空间 › 个人信息」，可在用户页统一管理'),
                  ),
                ),
              ],
            ),
    );
  }
}
