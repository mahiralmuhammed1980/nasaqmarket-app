import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'common.dart';

class _DashData {
  final int productCount, stockValue, todaySales, monthSales, cashBalance, supplierDebt;
  final List<BatchInfo> expiring;
  final List<ProductStock> low;
  final List<Invoice> recent;
  _DashData(this.productCount, this.stockValue, this.todaySales, this.monthSales, this.cashBalance, this.supplierDebt, this.expiring, this.low, this.recent);
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});
  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  late Future<_DashData> _f;
  @override
  void initState() {
    super.initState();
    _f = _load();
  }

  Future<_DashData> _load() async {
    final repo = context.repoRead;
    final now = DateTime.now();
    final products = await repo.watchProducts().first;
    return _DashData(
      products.length,
      await repo.inventoryValueAtCost(),
      await repo.salesTotalSince(DateTime(now.year, now.month, now.day)),
      await repo.salesTotalSince(DateTime(now.year, now.month)),
      (await repo.cashSummary()).totalBalance,
      (await repo.supplierBalances()).values.where((v) => v > 0).fold<int>(0, (a, b) => a + b),
      await repo.expiringBatches(withinDays: 90),
      await repo.lowStock(),
      await repo.watchInvoices().first,
    );
  }

  Future<void> _refresh() async {
    final f = _load();
    setState(() => _f = f);
    await f;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_DashData>(
      future: _f,
      builder: (ctx, snap) {
        if (snap.hasError) return Center(child: Text('تعذّر تحميل اللوحة: ${snap.error}'));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());
        final d = snap.data!;
        final wide = isWide(context);
        final cards = [
          StatCard('الأصناف', numFmt(d.productCount), Icons.medication),
          StatCard('قيمة المخزون', money(d.stockValue), Icons.account_balance_wallet),
          StatCard('مبيعات اليوم', money(d.todaySales), Icons.today, color: Colors.teal),
          StatCard('مبيعات الشهر', money(d.monthSales), Icons.calendar_month, color: Colors.indigo),
          StatCard('رصيد الصندوق', money(d.cashBalance), Icons.account_balance_wallet, color: d.cashBalance < 0 ? Colors.red : Colors.green.shade700),
          StatCard('مستحق للموردين', money(d.supplierDebt), Icons.local_shipping, color: Colors.deepOrange),
        ];
        final expired = d.expiring.where((b) => b.daysToExpiry < 0).toList();
        final soon = d.expiring.where((b) => b.daysToExpiry >= 0).toList();
        return RefreshIndicator(
          onRefresh: _refresh,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            Centered(
              maxWidth: 1100,
              child: Column(children: [
                GridView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: wide ? 3 : 2,
                    mainAxisExtent: 84,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  children: cards,
                ),
                const SizedBox(height: 8),
                if (wide)
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Expanded(child: _expiryCard(expired, soon)),
                    Expanded(child: Column(children: [_lowCard(d.low), _recentCard(d.recent)])),
                  ])
                else ...[_expiryCard(expired, soon), _lowCard(d.low), _recentCard(d.recent)],
              ]),
            ),
          ]),
        );
      },
    );
  }

  Widget _section(String title, IconData icon, Color color, int count, List<Widget> children, String empty) => Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ListTile(
              leading: Icon(icon, color: color),
              title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              trailing: count > 0 ? Chip(label: Text('$count'), visualDensity: VisualDensity.compact) : null,
            ),
            if (children.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 12), child: Text(empty)) else ...children,
          ]),
        ),
      );

  Widget _expiryCard(List<BatchInfo> expired, List<BatchInfo> soon) {
    Widget tile(BatchInfo b, Color c) => ListTile(
          dense: true,
          title: Text(b.product.name),
          subtitle: Text('دفعة ${b.batch.batchNo.isEmpty ? '—' : b.batch.batchNo} • الكمية ${b.batch.quantity}'),
          trailing: Text(b.daysToExpiry < 0 ? 'منتهية منذ ${-b.daysToExpiry} يوم' : 'بعد ${b.daysToExpiry} يوم',
              style: TextStyle(color: c, fontWeight: FontWeight.bold)),
        );
    return _section(
      'الدفعات المنتهية والقريبة من الانتهاء (90 يوماً)',
      Icons.event_busy,
      Colors.deepOrange,
      expired.length + soon.length,
      [for (final b in expired.take(10)) tile(b, Colors.red), for (final b in soon.take(15)) tile(b, Colors.orange.shade800)],
      'لا توجد دفعات قريبة من الانتهاء',
    );
  }

  Widget _lowCard(List<ProductStock> low) => _section(
        'أصناف منخفضة المخزون',
        Icons.warning_amber,
        Colors.amber.shade800,
        low.length,
        [
          for (final p in low.take(15))
            ListTile(
              dense: true,
              title: Text(p.product.name),
              trailing: Text('${p.stock} / ${p.product.minStock}', style: const TextStyle(fontWeight: FontWeight.bold)),
            )
        ],
        'المخزون جيد',
      );

  Widget _recentCard(List<Invoice> inv) => _section(
        'آخر الفواتير',
        Icons.receipt_long,
        Colors.teal,
        0,
        [
          for (final i in inv.take(6))
            ListTile(dense: true, title: Text(i.patientName), subtitle: Text('${i.number} • ${dateTimeFmt(i.createdAt)}'), trailing: Text(money(i.total))),
        ],
        'لا توجد فواتير بعد',
      );
}
