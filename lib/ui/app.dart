import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_state.dart';
import 'activation_screen.dart';
import 'pin_screen.dart';
import 'shell.dart';

class NasaqApp extends StatelessWidget {
  final AppController controller;
  const NasaqApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0E7C66);
    return AppScope(
      controller: controller,
      child: MaterialApp(
        title: 'نسق فارما',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: seed),
          useMaterial3: true,
          fontFamily: 'Cairo',
          inputDecorationTheme: const InputDecorationTheme(isDense: true),
        ),
        home: const _Gate(),
      ),
    );
  }
}

/// البوابة: تحميل ← تفعيل (مرة واحدة) ← PIN ← التطبيق.
class _Gate extends StatelessWidget {
  const _Gate();
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (!app.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!app.activated) return const ActivationScreen();
    if (!app.unlocked) return const PinEntryScreen();
    return Shell(key: ValueKey(app.db));
  }
}
