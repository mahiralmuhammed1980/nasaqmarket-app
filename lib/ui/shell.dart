import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../services/updater.dart';
import 'common.dart';
import 'dashboard_screen.dart';
import 'cash_screen.dart';
import 'inventory_screen.dart';
import 'purchases_screen.dart';
import 'more_screen.dart';
import 'redeem_screen.dart';
import 'sales_screen.dart';

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
    _Dest('الصندوق', Icons.account_balance_wallet_outlined, Icons.account_balance_wallet, () => const CashScreen()),
    _Dest('المزيد', Icons.more_horiz, Icons.more_horiz, () => const MoreScreen()),
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
    if (s == AppLifecycleState.resumed) context.app.touchClock();
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
    final banner = _AccessBanner(app: context.app);
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
              Expanded(child: Column(children: [banner, Expanded(child: page)])),
            ])
          : Column(children: [banner, Expanded(child: page)]),
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

/// شريط الحالة: فترة مجانية، أو اقتراب انتهاء الاشتراك، أو قراءة فقط مع زر إدخال الكود.
class _AccessBanner extends StatelessWidget {
  final AppController app;
  const _AccessBanner({required this.app});

  void _redeem(BuildContext c) => Navigator.push(c, MaterialPageRoute(builder: (_) => const RedeemScreen()));

  Widget _bar(BuildContext context, Color bg, Color fg, IconData icon, String text, {String? action}) => Material(
        color: bg,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(child: Text(text, style: TextStyle(color: fg, fontSize: 12.5))),
            if (action != null)
              TextButton(
                onPressed: () => _redeem(context),
                style: TextButton.styleFrom(foregroundColor: fg, visualDensity: VisualDensity.compact),
                child: Text(action),
              ),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final now = app.effectiveNow;
    final p = app.policy;
    if (app.readOnly) {
      return _bar(context, cs.errorContainer, cs.onErrorContainer, Icons.lock_clock,
          'انتهت الفترة المجانية: للقراءة والتصدير فقط. بياناتك محفوظة.', action: 'أدخل كود');
    }
    if (p.isPaid(now)) {
      final left = p.paidDaysLeft(now);
      if (left != null && left <= 30) {
        return _bar(context, cs.tertiaryContainer, cs.onTertiaryContainer, Icons.event_repeat,
            'ينتهي اشتراكك بعد $left يوم (${dateFmt(p.paidUntil)}). جدّد بكود من مندوبك.', action: 'تجديد');
      }
      return const SizedBox.shrink();
    }
    final d = app.freeDaysLeft;
    final until = dateFmt(p.freeUntil);
    final soon = d <= 14;
    return _bar(
      context,
      soon ? cs.tertiaryContainer : cs.primaryContainer,
      soon ? cs.onTertiaryContainer : cs.onPrimaryContainer,
      Icons.card_giftcard,
      d == 0 ? 'آخر يوم مجاني ($until) ثم يصبح التطبيق باشتراك' : 'مجاني حتى $until (باقي $d يوم) ثم يصبح التطبيق باشتراك',
      action: soon ? 'أدخل كود' : null,
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
