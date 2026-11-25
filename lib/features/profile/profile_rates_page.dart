import 'package:flutter/material.dart';

import '../../core/formatters.dart';
import '../../core/insurance.dart';
import '../../core/settings/app_l10n.dart';
import '../../core/widgets/app_widgets.dart';
import '../../core/widgets/rate_table.dart';
import 'profile_model.dart';
import 'profile_repository.dart';

/// 五险一金比例：留空即忽略，计算时回退到城市默认值。
class ProfileRatesPage extends StatefulWidget {
  const ProfileRatesPage({super.key});

  @override
  State<ProfileRatesPage> createState() => _ProfileRatesPageState();
}

class _ProfileRatesPageState extends State<ProfileRatesPage> {
  final Map<String, TextEditingController> _personal =
      <String, TextEditingController>{
    for (final item in kInsuranceItems) item.id: TextEditingController(),
  };
  final Map<String, TextEditingController> _employer =
      <String, TextEditingController>{
    for (final item in kInsuranceItems) item.id: TextEditingController(),
  };

  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _personal.values) {
      controller.dispose();
    }
    for (final controller in _employer.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final profile = await ProfileRepository.load();
    if (!mounted) return;
    setState(() {
      for (final item in kInsuranceItems) {
        _personal[item.id]!.text = textOf(profile.personalRate(item.id));
        _employer[item.id]!.text = textOf(profile.employerRate(item.id));
      }
      _loading = false;
    });
  }

  Future<void> _save() async {
    final l10n = AppL10n.of();
    setState(() => _saving = true);
    final profile = await ProfileRepository.update((data) {
      for (final item in kInsuranceItems) {
        UserProfile.putNumber(
          data,
          UserProfile.personalRateKey(item.id),
          _personal[item.id]!.text,
        );
        UserProfile.putNumber(
          data,
          UserProfile.employerRateKey(item.id),
          _employer[item.id]!.text,
        );
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    FocusScope.of(context).unfocus();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          profile.isEmpty ? l10n.snackbarSavedEmpty : l10n.snackbarSaved,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppL10n.of();
    return Scaffold(
      appBar: AppBar(title: Text(l10n.insuranceRates)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              keyboardDismissBehavior:
                  ScrollViewKeyboardDismissBehavior.onDrag,
              children: [
                SectionCard(
                  title: l10n.insuranceRates,
                  children: [
                    RateTable(personal: _personal, employer: _employer),
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
                  label: Text(_saving ? l10n.savingProfile : l10n.save),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
              ],
            ),
    );
  }
}
