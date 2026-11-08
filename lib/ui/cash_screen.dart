import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/database.dart';
import '../data/repository.dart';
import 'common.dart';
import 'share_util.dart';

String cashKindLabel(String k) => switch (k) {
      'opening' => 'رصيد افتتاحي',
      'sale' => 'مبيعات',
      'sale_settlement' => 'سداد فاتورة',
      'supplier_payment' => 'دفع لمورد',
      'expense' => 'مصروف',
      'owner_in' => 'إيداع من المالك',
      'owner_out' => 'سحب للمالك',
      'adjustment' => 'تسوية',
      'void' => 'إلغاء فاتورة',
      _ => k,
    };

String methodLabel(String m) => switch (m) { 'card' => 'بطاقة', 'transfer' => 'حوالة', _ => 'نقداً' };

IconData cashKindIcon(String k) => switch (k) {
      'opening' => Icons.flag_outlined,
      'sale' || 'sale_settlement' => Icons.point_of_sale,
      'supplier_payment' => Icons.local_shipping_outlined,
      'expense' => Icons.receipt_long,
      'owner_in' => Icons.add_card,
      'owner_out' => Icons.logout,
      'adjustment' => Icons.balance,
      'void' => Icons.undo,
      _ => Icons.circle_outlined,
    };

class CashScreen extends StatefulWidget {
  const CashScreen({super.key});
  @override
  State<CashScreen> createState() => _CashScreenState();
}

class _CashScreenState extends State<CashScreen> {
  String _filter = 'all';

  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  Future<void> _newEntry() async {
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final (k, sub) in [
            ('expense', 'إيجار، رواتب، كهرباء...'),
            ('supplier_payment', 'دفعة لمورد من الصندوق'),
            ('owner_out', 'مبلغ يأخذه المالك'),
            ('owner_in', 'مبلغ يضيفه المالك'),
            ('opening', 'رصيد البداية (مرة واحدة)'),
            ('closing', 'مطابقة النقد الفعلي مع النظام'),
          ])
            ListTile(
              leading: Icon(k == 'closing' ? Icons.lock_clock : cashKindIcon(k)),
              title: Text(k == 'closing' ? 'إغلاق اليوم' : cashKindLabel(k)),
              subtitle: Text(sub),
              onTap: () => Navigator.pop(ctx, k),
            ),
        ]),
      ),
    );
    if (kind == null || !mounted) return;
    if (kind == 'closing') {
      await showCloseDayDialog(context);
    } else {
      await showCashEntryDialog(context, kind);
    }
  }

  Future<void> _export() async {
    final all = await context.repoRead.watchCash(filter: _filter).first;
    final b = StringBuffer('﻿التاريخ,النوع,الوسيلة,المبلغ,التصنيف,ملاحظة\n');
    for (final e in all) {
      b.writeln([csvCell(dateTimeFmt(e.createdAt)), csvCell(cashKindLabel(e.kind)), csvCell(methodLabel(e.method)), e.amount, csvCell(e.category), csvCell(e.note)].join(','));
    }
    if (mounted) await shareText(context, b.toString(), 'cash_${dateFmt(DateTime.now())}.csv');
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.repo;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(onPressed: _newEntry, icon: const Icon(Icons.add), label: const Text('حركة جديدة')),
      body: Centered(
        maxWidth: 800,
        child: Column(children: [
          StreamBuilder<CashSummary>(
            stream: repo.watchCashSummary(from: _today, to: _today.add(const Duration(days: 1))),
            builder: (ctx, snap) {
              final s = snap.data;
              if (s == null) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
              return Card(
                margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('إجمالي الرصيد', style: Theme.of(context).textTheme.bodySmall),
                    Text(money(s.totalBalance), style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: s.totalBalance < 0 ? Colors.red.shade700 : null)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 4, children: [
                      for (final m in ['cash', 'card', 'transfer'])
                        Chip(visualDensity: VisualDensity.compact, label: Text('${methodLabel(m)}: ${money(s.balanceByMethod[m] ?? 0)}')),
                    ]),
                    const Divider(),
                    Row(children: [
                      Expanded(child: Text('دخل اليوم: ${money(s.totalIn)}', style: TextStyle(color: Colors.green.shade800, fontWeight: FontWeight.bold))),
                      Expanded(child: Text('خرج اليوم: ${money(s.totalOut)}', style: TextStyle(color: Colors.red.shade800, fontWeight: FontWeight.bold))),
                    ]),
                  ]),
                ),
              );
            },
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(children: [
              for (final (k, l) in [('all', 'الكل'), ('in', 'دخل'), ('out', 'خرج')])
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 8),
                  child: ChoiceChip(label: Text(l), selected: _filter == k, onSelected: (_) => setState(() => _filter = k)),
                ),
              const Spacer(),
              IconButton(tooltip: 'تصدير CSV', icon: const Icon(Icons.file_download_outlined), onPressed: _export),
            ]),
          ),
          Expanded(
            child: StreamBuilder<List<CashEntry>>(
              stream: repo.watchCash(filter: _filter),
              builder: (ctx, snap) {
                final list = snap.data ?? [];
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                if (list.isEmpty) return const EmptyState(Icons.account_balance_wallet_outlined, 'لا توجد حركات.\nابدأ بإدخال الرصيد الافتتاحي من «حركة جديدة».');
                return ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: list.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final e = list[i];
                    final inflow = e.amount > 0;
                    return ListTile(
                      dense: true,
                      leading: CircleAvatar(
                          radius: 18,
                          backgroundColor: (inflow ? Colors.green : Colors.red).withValues(alpha: .12),
                          child: Icon(cashKindIcon(e.kind), size: 18, color: inflow ? Colors.green.shade800 : Colors.red.shade800)),
                      title: Text([cashKindLabel(e.kind), if (e.category.isNotEmpty && e.category != cashKindLabel(e.kind)) e.category].join(' • ')),
                      subtitle: Text([dateTimeFmt(e.createdAt), methodLabel(e.method), if (e.note.isNotEmpty) e.note].join(' • ')),
                      trailing: Text('${inflow ? '+' : '−'} ${money(e.amount.abs())}',
                          style: TextStyle(fontWeight: FontWeight.bold, color: inflow ? Colors.green.shade800 : Colors.red.shade800)),
                    );
                  },
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}

/// حوار إدخال حركة يدوية أو دفعة لمورد. يعيد true عند الحفظ.
Future<bool?> showCashEntryDialog(BuildContext context, String kind, {int? supplierId}) async {
  final amount = TextEditingController();
  final note = TextEditingController();
  var method = 'cash';
  var category = kExpenseCategories.first;
  int? supplier = supplierId;
  final repo = context.repoRead;
  final form = GlobalKey<FormState>();
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(cashKindLabel(kind)),
        content: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              formField('المبلغ *', amount, type: TextInputType.number, validator: (v) {
                final n = parseInt(v);
                return (n == null || n <= 0) ? 'أدخل مبلغاً أكبر من صفر' : null;
              }),
              DropdownButtonFormField<String>(
                initialValue: method,
                decoration: const InputDecoration(labelText: 'الوسيلة', border: OutlineInputBorder()),
                items: [for (final m in ['cash', 'card', 'transfer']) DropdownMenuItem(value: m, child: Text(methodLabel(m)))],
                onChanged: (v) => setS(() => method = v ?? 'cash'),
              ),
              if (kind == 'expense') ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: 'التصنيف', border: OutlineInputBorder()),
                  items: [for (final c in kExpenseCategories) DropdownMenuItem(value: c, child: Text(c))],
                  onChanged: (v) => setS(() => category = v ?? category),
                ),
              ],
              if (kind == 'supplier_payment' && supplierId == null) ...[
                const SizedBox(height: 8),
                StreamBuilder<List<Supplier>>(
                  stream: repo.watchSuppliers(),
                  builder: (c, s) => DropdownButtonFormField<int>(
                    initialValue: supplier,
                    decoration: const InputDecoration(labelText: 'المورد *', border: OutlineInputBorder()),
                    items: [for (final x in s.data ?? <Supplier>[]) DropdownMenuItem(value: x.id, child: Text(x.name))],
                    onChanged: (v) => setS(() => supplier = v),
                  ),
                ),
              ],
              formField('ملاحظة', note),
            ]),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              if (kind == 'supplier_payment' && supplier == null) {
                snack(ctx, 'اختر المورد', error: true);
                return;
              }
              final amt = parseInt(amount.text)!;
              try {
                if (kind == 'supplier_payment') {
                  await repo.addSupplierPayment(supplierId: supplier!, amount: amt, method: method, note: note.text.trim());
                } else {
                  await repo.addManualEntry(kind: kind, amount: amt, method: method, category: kind == 'expense' ? category : '', note: note.text.trim());
                }
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) snack(ctx, 'تعذّر الحفظ: $e', error: true);
              }
            },
            child: const Text('حفظ'),
          ),
        ],
      ),
    ),
  );
}

/// إغلاق اليوم: يعرض رصيد النقد في النظام ويطلب المبلغ الفعلي.
Future<void> showCloseDayDialog(BuildContext context) async {
  final repo = context.repoRead;
  final system = (await repo.cashSummary()).cashBalance;
  if (!context.mounted) return;
  final counted = TextEditingController();
  final note = TextEditingController();
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('إغلاق اليوم'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('الرصيد النقدي في النظام: ${money(system)}', style: const TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        const Text('عُدّ النقد الموجود فعلاً في الدرج وأدخله. إن اختلف عن النظام تُسجَّل تسوية بالفرق.'),
        formField('النقد الفعلي *', counted, type: TextInputType.number),
        formField('ملاحظة', note),
      ]),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () {
              final n = parseInt(counted.text);
              if (n == null || n < 0) {
                snack(ctx, 'أدخل مبلغاً صحيحاً', error: true);
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: const Text('إغلاق')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return;
  final c = await repo.closeDay(parseInt(counted.text)!, note: note.text.trim());
  if (!context.mounted) return;
  snack(context, c.difference == 0 ? 'تم الإغلاق: الرصيد مطابق' : 'تم الإغلاق مع فرق ${c.difference > 0 ? 'زيادة' : 'نقص'} ${money(c.difference.abs())}');
}
