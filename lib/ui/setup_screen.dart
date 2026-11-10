import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/business.dart';
import '../services/store_info.dart';
import 'common.dart';

/// الإعداد الأول: نوع النشاط يحدد الميزات (مقاس/لون، كميات عشرية، صلاحية).
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  BusinessType _type = BusinessType.supermarket;
  final _name = TextEditingController();
  final _currency = TextEditingController(text: 'ل.س');
  bool _saving = false;

  Future<void> _done() async {
    setState(() => _saving = true);
    final app = context.app;
    final cur = _currency.text.trim().isEmpty ? 'ل.س' : _currency.text.trim();
    await app.saveStore(StoreInfo(name: _name.text.trim()));
    await app.saveConfig(StoreConfig.forType(_type, currency: cur));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('إعداد المحل')),
        body: Centered(
          maxWidth: 560,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            Text('ما نوع نشاطك؟', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('نضبط التطبيق حسب نوع المحل، ويمكنك تغيير الخيارات لاحقاً من الإعدادات.'),
            const SizedBox(height: 12),
            for (final t in BusinessType.values)
              Card(
                color: _type == t ? Theme.of(context).colorScheme.primaryContainer : null,
                child: ListTile(
                  leading: Icon(t.icon),
                  title: Text(t.label),
                  subtitle: Text([
                    if (t.variants) 'مقاس ولون',
                    if (t.decimal) 'بيع بالوزن',
                    if (t.expiry) 'تاريخ صلاحية',
                  ].join(' • ')),
                  trailing: _type == t ? const Icon(Icons.check_circle) : null,
                  onTap: () => setState(() => _type = t),
                ),
              ),
            const SizedBox(height: 12),
            formField('اسم المحل (يظهر في الفواتير)', _name),
            formField('رمز العملة', _currency),
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _saving ? null : _done,
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              child: const Text('ابدأ'),
            ),
          ]),
        ),
      );
}
