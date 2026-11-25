import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'core/app_theme.dart';
import 'core/settings/settings_controller.dart';
import 'features/shell/home_shell.dart';

class ToolboxApp extends StatelessWidget {
  const ToolboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = SettingsController.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final seed = settings.themeColor.color;
        return MaterialApp(
          title: 'XMtools',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.light(seed),
          darkTheme: AppTheme.dark(seed),
          themeMode: settings.themeMode,
          locale: settings.locale,
          supportedLocales: const <Locale>[
            Locale('zh'),
            Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
            Locale('en'),
          ],
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const HomeShell(),
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(
                textScaler: TextScaler.linear(settings.fontScale),
              ),
              child: child ?? const SizedBox.shrink(),
            );
          },
        );
      },
    );
  }
}
