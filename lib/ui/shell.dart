import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/updater.dart';
import 'common.dart';
import 'dashboard_screen.dart';
import 'data_screen.dart';
import 'inventory_screen.dart';
import 'purchases_screen.dart';
import 'sales_screen.dart';
import 'settings_screen.dart';

class _Dest {
  final String label;
  final IconData icon, selected;
  final Widget Function() page;
  const _Dest(this.label, this.icon, this.selected, this.page);
}

/// الهيكل المتجاوب: شريط جانبي على التابلت، وشريط سفلي على الهاتف.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  int _i = 0;
  final _tabs = <_Dest>[
    _Dest('الرئيسية', Icons.dashboard_outlined, Icons.dashboard, () => const DashboardScreen()),
    _Dest('المخزون', Icons.inventory_2_outlined, Icons.inventory_2, () => const InventoryScreen()),
    _Dest('المبيعات', Icons.receipt_long_outlined, Icons.receipt_long, () => const SalesScreen()),
    _Dest('المشتريات', Icons.local_shipping_outlined, Icons.local_shipping, () => const PurchasesScreen()),
    _Dest('البيانات', Icons.storage_outlined, Icons.storage, () => const DataScreen()),
    _Dest('الإعدادات', Icons.settings_outlined, Icons.settings, () => const SettingsScreen()),
  ];
  DateTime? _pausedAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkUpdate());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// قفل التطبيق إن غاب في الخلفية أكثر من دقيقة.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) _pausedAt = DateTime.now();
    if (s == AppLifecycleState.resumed && _pausedAt != null) {
      if (DateTime.now().difference(_pausedAt!) > const Duration(minutes: 1)) context.app.lock();
      _pausedAt = null;
    }
  }

  Future<void> _checkUpdate() async {
    final info = await UpdateService().check();
    if (info == null || !mounted) return;
    showUpdateDialog(context, info);
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final page = KeyedSubtree(key: ValueKey(_i), child: _tabs[_i].page());
    return Scaffold(
      appBar: AppBar(
        title: Text(_tabs[_i].label),
        actions: [
          if (context.app.pinRequired)
            IconButton(tooltip: 'قفل', icon: const Icon(Icons.lock_outline), onPressed: context.app.lock),
        ],
      ),
      body: wide
          ? Row(children: [
              NavigationRail(
                selectedIndex: _i,
                onDestinationSelected: (v) => setState(() => _i = v),
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final t in _tabs)
                    NavigationRailDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selected), label: Text(t.label)),
                ],
              ),
              const VerticalDivider(width: 1),
              Expanded(child: page),
            ])
          : page,
      bottomNavigationBar: wide
          ? null
          : NavigationBar(
              selectedIndex: _i,
              onDestinationSelected: (v) => setState(() => _i = v),
              labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
              height: 64,
              destinations: [
                for (final t in _tabs)
                  NavigationDestination(icon: Icon(t.icon), selectedIcon: Icon(t.selected), label: t.label),
              ],
            ),
    );
  }
}

Future<void> showUpdateDialog(BuildContext context, UpdateInfo info) async {
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: !info.mandatory,
    builder: (ctx) => AlertDialog(
      title: Text('تحديث جديد ${info.versionName}'),
      content: Text(info.notes.isEmpty ? 'يتوفر إصدار أحدث من التطبيق.' : info.notes),
      actions: [
        if (!info.mandatory) TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('لاحقاً')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تحديث الآن')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;
  // نسخة أمان قبل التحديث. بياناتك تبقى كما هي بعد التثبيت.
  await context.app.safetyBackup('before_update');
  if (!context.mounted) return;
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _UpdateProgress(info),
  );
}

class _UpdateProgress extends StatelessWidget {
  final UpdateInfo info;
  const _UpdateProgress(this.info);
  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('جارٍ التحديث'),
        content: StreamBuilder(
          stream: UpdateService().install(info),
          builder: (ctx, snap) {
            final e = snap.data;
            if (snap.hasError) return Text('فشل التحديث: ${snap.error}');
            if (e == null) return const LinearProgressIndicator();
            final status = e.status.name;
            if (status.contains('ERROR') || status.contains('CHECKSUM') || status.contains('PERMISSION') || status.contains('INTERNAL') || status.contains('ALREADY')) {
              return Text('تعذّر التحديث ($status). تأكد من السماح بتثبيت التطبيقات من هذا المصدر.');
            }
            final p = int.tryParse(e.value ?? '');
            return Column(mainAxisSize: MainAxisSize.min, children: [
              LinearProgressIndicator(value: p == null ? null : p / 100),
              const SizedBox(height: 8),
              Text(status.contains('INSTALLING') ? 'جارٍ التثبيت...' : 'جارٍ التنزيل ${p ?? ''}%'),
            ]);
          },
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('إغلاق'))],
      );
}
