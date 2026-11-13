import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import 'common.dart';
import 'dashboard_screen.dart';
import 'cash_screen.dart';
import 'inventory_screen.dart';
import 'purchases_screen.dart';
import 'more_screen.dart';
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

/// شريط الحالة: يذكّر بنهاية الفترة المجانية، وبعدها يوضّح أن التطبيق للقراءة فقط.
class _AccessBanner extends StatelessWidget {
  final AppController app;
  const _AccessBanner({required this.app});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (app.readOnly) {
      return Material(
        color: cs.errorContainer,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Icon(Icons.lock_clock, size: 20, color: cs.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text('انتهت الفترة المجانية: التطبيق للقراءة والتصدير فقط. بياناتك محفوظة والاشتراك قريباً.',
                  style: TextStyle(color: cs.onErrorContainer, fontSize: 13)),
            ),
          ]),
        ),
      );
    }
    final d = app.freeDaysLeft;
    final until = dateFmt(app.policy.freeUntil);
    return Material(
      color: d <= 14 ? cs.tertiaryContainer : cs.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(children: [
          Icon(Icons.card_giftcard, size: 18, color: d <= 14 ? cs.onTertiaryContainer : cs.onPrimaryContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              d == 0 ? 'آخر يوم مجاني ($until) ثم يصبح التطبيق باشتراك' : 'مجاني حتى $until (باقي $d يوم) ثم يصبح التطبيق باشتراك',
              style: TextStyle(color: d <= 14 ? cs.onTertiaryContainer : cs.onPrimaryContainer, fontSize: 12.5),
            ),
          ),
        ]),
      ),
    );
  }
}
