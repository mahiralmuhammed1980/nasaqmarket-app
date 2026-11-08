import 'package:flutter/material.dart';

import 'common.dart';
import 'companies_screen.dart';
import 'data_screen.dart';
import 'restricted_screen.dart';
import 'settings_screen.dart';

/// «المزيد»: الشركات، سجل المقيّدة، البيانات والنسخ، الإعدادات.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  void _open(BuildContext c, String title, Widget body) =>
      Navigator.push(c, MaterialPageRoute(builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: body)));

  @override
  Widget build(BuildContext context) => Centered(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(8), children: [
          _tile(Icons.factory_outlined, 'الشركات', 'الشركات المصنّعة التي تُنسب إليها الأدوية', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const CompaniesScreen()))),
          _tile(Icons.lock_outline, 'سجل الأدوية المقيّدة', 'مبيعات الأدوية بوصفة: الوصفة والطبيب والمريض', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const RestrictedScreen()))),
          _tile(Icons.storage_outlined, 'البيانات والنسخ الاحتياطي', 'استيراد وتصدير ونسخ Google Drive', () => _open(context, 'البيانات', const DataScreen())),
          _tile(Icons.settings_outlined, 'الإعدادات', 'بيانات الصيدلية، الأمان، التحديثات', () => _open(context, 'الإعدادات', const SettingsScreen())),
        ]),
      );

  Widget _tile(IconData i, String t, String s, VoidCallback f) => Card(
        child: ListTile(leading: CircleAvatar(child: Icon(i)), title: Text(t), subtitle: Text(s), trailing: const Icon(Icons.chevron_left), onTap: f),
      );
}
