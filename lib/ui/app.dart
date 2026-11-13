import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../app_state.dart';
import 'contact_screen.dart';
import 'pin_screen.dart';
import 'setup_screen.dart';
import 'shell.dart';
import 'sign_in_screen.dart';

class NasaqApp extends StatelessWidget {
  final AppController controller;
  const NasaqApp({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    const seed = Color(0xFF0D2B5E);
    return AppScope(
      controller: controller,
      child: MaterialApp(
        title: 'نسق ماركت',
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

/// البوابة: تحميل ← تسجيل Google (إلزامي) ← إعداد المحل (مرة واحدة) ← PIN ← التطبيق.
class _Gate extends StatelessWidget {
  const _Gate();
  @override
  Widget build(BuildContext context) {
    final app = context.app;
    if (!app.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!app.signedIn) return const SignInScreen();
    if (app.needsContactPrompt) return const ContactScreen(firstRun: true);
    if (!app.onboarded) return const SetupScreen();
    if (!app.unlocked) return const PinEntryScreen();
    return Shell(key: ValueKey(app.db));
  }
}
