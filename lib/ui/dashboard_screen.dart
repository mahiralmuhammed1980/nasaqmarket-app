import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'common.dart';

class _DashData {
  final int productCount, stockValue, todaySales, monthSales, monthProfit, cashBalance, supplierDebt, customerDebt;
  final List<BatchInfo> expiring;
  final List<ProductStock> low;
  final List<Invoice> recent;
  _DashData(this.productCount, this.stockValue, this.todaySales, this.monthSales, this.monthProfit, this.cashBalance, this.supplierDebt, this.customerDebt, this.expiring, this.low, this.recent);
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
    final cfg = context.appRead.cfg;
    final now = DateTime.now();
    final products = await repo.watchProducts().first;
    return _DashData(
      products.length,
      await repo.inventoryValueAtCost(),
      await repo.salesTotalSince(DateTime(now.year, now.month, now.day)),
      await repo.salesTotalSince(DateTime(now.year, now.month)),
      await repo.profitSince(DateTime(now.year, now.month)),
      (await repo.cashSummary()).totalBalance,
      (await repo.supplierBalances()).values.where((v) => v > 0).fold<int>(0, (a, b) => a + b),
      await repo.customerReceivables(),
      cfg.expiry ? await repo.expiringBatches(withinDays: 90) : <BatchInfo>[],
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
          StatCard('الأصناف', numFmt(d.productCount), Icons.inventory_2),
          StatCard('قيمة المخزون', money(d.stockValue), Icons.account_balance_wallet),
          StatCard('مبيعات اليوم', money(d.todaySales), Icons.today, color: Colors.teal),
          StatCard('مبيعات الشهر', money(d.monthSales), Icons.calendar_month, color: Colors.indigo),
          StatCard('رصيد الصندوق', money(d.cashBalance), Icons.account_balance_wallet, color: d.cashBalance < 0 ? Colors.red : Colors.green.shade700),
          StatCard('ربح الشهر', money(d.monthProfit), Icons.trending_up, color: d.monthProfit < 0 ? Colors.red : Colors.green.shade700),
          StatCard('مستحق للموردين', money(d.supplierDebt), Icons.local_shipping, color: Colors.deepOrange),
          StatCard('ديون الزبائن', money(d.customerDebt), Icons.people_outline, color: Colors.brown),
        ];
        final showExpiry = context.app.cfg.expiry;
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
                    Expanded(child: Column(children: [if (showExpiry) _expiryCard(expired, soon), _lowCard(d.low)])),
                    Expanded(child: _recentCard(d.recent)),
                  ])
                else ...[if (showExpiry) _expiryCard(expired, soon), _lowCard(d.low), _recentCard(d.recent)],
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
          title: Text(b.product.displayName),
          subtitle: Text('${b.batch.batchNo.isEmpty ? '' : 'دفعة ${b.batch.batchNo} • '}الكمية ${qtyFmt(b.batch.quantity)}'),
          trailing: Text(b.daysToExpiry < 0 ? 'منتهية منذ ${-b.daysToExpiry} يوم' : 'بعد ${b.daysToExpiry} يوم',
              style: TextStyle(color: c, fontWeight: FontWeight.bold)),
        );
    return _section(
      'المنتهية والقريبة من الانتهاء (90 يوماً)',
      Icons.event_busy,
      Colors.deepOrange,
      expired.length + soon.length,
      [for (final b in expired.take(10)) tile(b, Colors.red), for (final b in soon.take(15)) tile(b, Colors.orange.shade800)],
      'لا توجد أصناف قريبة من الانتهاء',
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
              title: Text(p.product.displayName),
              trailing: Text('${qtyFmt(p.stock)} / ${qtyFmt(p.product.minStock)}', style: const TextStyle(fontWeight: FontWeight.bold)),
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
            ListTile(dense: true, title: Text(i.customerName.isEmpty ? 'زبون نقدي' : i.customerName), subtitle: Text('${i.number} • ${dateTimeFmt(i.createdAt)}'), trailing: Text(money(i.total))),
        ],
        'لا توجد فواتير بعد',
      );
}
