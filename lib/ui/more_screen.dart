import 'package:flutter/material.dart';

import 'common.dart';
import 'data_screen.dart';
import 'settings_screen.dart';

/// «المزيد»: البيانات والنسخ، الإعدادات.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  void _open(BuildContext c, String title, Widget body) =>
      Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: body)));

  @override
  Widget build(BuildContext context) => Centered(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(8), children: [
          _tile(Icons.storage_outlined, 'البيانات والنسخ الاحتياطي', 'استيراد وتصدير ونسخ Google Drive', () => _open(context, 'البيانات', const DataScreen())),
          _tile(Icons.settings_outlined, 'الإعدادات', 'بيانات المحل، الميزات، الأمان، الحساب', () => _open(context, 'الإعدادات', const SettingsScreen())),
        ]),
      );

  Widget _tile(IconData i, String t, String s, VoidCallback f) => Card(
        child: ListTile(leading: CircleAvatar(child: Icon(i)), title: Text(t), subtitle: Text(s), trailing: const Icon(Icons.chevron_left), onTap: f),
      );
}
