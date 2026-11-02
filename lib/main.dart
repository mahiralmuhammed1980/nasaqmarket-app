import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // يعمل فقط عند وجود google-services.json؛ بدونه يبقى التطبيق قابلاً للتشغيل.
    await Firebase.initializeApp();
  } catch (_) {}
  final controller = AppController();
  runApp(NasaqApp(controller: controller));
  await controller.init();
}
