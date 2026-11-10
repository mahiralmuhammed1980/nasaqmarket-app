import 'package:flutter/material.dart';

import 'app_state.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = AppController();
  runApp(NasaqApp(controller: controller));
  await controller.init();
}
