import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../services/statement_pdf.dart';
import 'cash_screen.dart';
import 'common.dart';

/// كشف حساب مورد: رصيد افتتاحي + مشتريات (أوامر مستلمة) - دفعات.
class SupplierStatementPage extends StatefulWidget {
  final int supplierId;
  const SupplierStatementPage({super.key, required this.supplierId});
  @override
  State<SupplierStatementPage> createState() => _SupplierStatementPageState();
}

class _SupplierStatementPageState extends State<SupplierStatementPage> {
  late Future<SupplierStatement> _f;

  @override
  void initState() {
    super.initState();
    _f = context.repoRead.supplierStatement(widget.supplierId);
  }

  void _reload() => setState(() => _f = context.repoRead.supplierStatement(widget.supplierId));

  Future<void> _editOpening(SupplierStatement st) async {
    final c = TextEditingController(text: '${st.openingBalance}');
    final v = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('الرصيد الافتتاحي'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('المبلغ المستحق للمورد قبل بدء استخدام التطبيق (ذمم سابقة). اتركه 0 إن لم يوجد. أدخل رقماً سالباً إن كان لك رصيد عند المورد.'),
          const SizedBox(height: 8),
          TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(signed: true), autofocus: true),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(onPressed: () => Navigator.pop(ctx, parseInt(c.text)), child: const Text('حفظ')),
        ],
      ),
    );
    if (v == null || !mounted) return;
    await context.repoRead.saveSupplier(SuppliersCompanion(id: Value(st.supplier.id), name: Value(st.supplier.name), openingBalance: Value(v)));
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SupplierStatement>(
      future: _f,
      builder: (ctx, snap) {
        if (snap.hasError) return Scaffold(appBar: AppBar(), body: Center(child: Text('تعذّر تحميل الكشف: ${snap.error}')));
        if (!snap.hasData) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
        final st = snap.data!;
        final bal = st.balance;
        final color = bal > 0 ? Colors.red.shade700 : (bal < 0 ? Colors.green.shade700 : null);
        return Scaffold(
          appBar: AppBar(title: Text('كشف حساب: ${st.supplier.name}'), actions: [
            IconButton(
                tooltip: 'مشاركة / تصدير PDF',
                icon: const Icon(Icons.picture_as_pdf),
                onPressed: () async {
                  final bytes = await buildSupplierStatementPdf(st, context.appRead.store);
                  await Printing.sharePdf(bytes: Uint8List.fromList(bytes), filename: 'statement_${st.supplier.name}.pdf');
                }),
            IconButton(tooltip: 'الرصيد الافتتاحي', icon: const Icon(Icons.edit_note), onPressed: () => _editOpening(st)),
          ]),
          floatingActionButton: FloatingActionButton.extended(
            icon: const Icon(Icons.payments),
            label: const Text('تسجيل دفعة'),
            onPressed: () async {
              final ok = await showCashEntryDialog(context, 'supplier_payment', supplierId: st.supplier.id);
              if (ok == true) _reload();
            },
          ),
          body: Centered(
            maxWidth: 800,
            child: ListView(padding: const EdgeInsets.only(bottom: 88), children: [
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(bal > 0 ? 'المستحق للمورد' : (bal < 0 ? 'رصيد لنا عند المورد' : 'الحساب مسدّد'), style: Theme.of(context).textTheme.bodySmall),
                    Text(money(bal.abs()), style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold, color: color)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 24, children: [
                      Text('إجمالي المشتريات: ${money(st.totalPurchases)}'),
                      Text('إجمالي الدفعات: ${money(st.totalPaid)}'),
                    ]),
                  ]),
                ),
              ),
              if (st.rows.isEmpty) const EmptyState(Icons.receipt_long, 'لا توجد حركات بعد.\nاستلم أمر شراء أو سجّل دفعة.'),
              for (final r in st.rows)
                ListTile(
                  dense: true,
                  leading: Icon(r.kind == 'payment' ? Icons.south_west : (r.kind == 'opening' ? Icons.flag_outlined : Icons.north_east),
                      color: r.kind == 'payment' ? Colors.green.shade700 : Colors.red.shade700),
                  title: Text(r.description),
                  subtitle: Text(r.kind == 'opening' ? 'ذمم سابقة' : dateTimeFmt(r.date)),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(r.debit > 0 ? '+ ${money(r.debit)}' : '− ${money(r.credit)}',
                        style: TextStyle(fontWeight: FontWeight.bold, color: r.debit > 0 ? Colors.red.shade700 : Colors.green.shade700)),
                    Text('الرصيد ${money(r.balance)}', style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
            ]),
          ),
        );
      },
    );
  }
}
