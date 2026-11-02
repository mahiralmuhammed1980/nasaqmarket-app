import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../core/gs1.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../services/invoice_pdf.dart';
import 'common.dart';
import 'scanner.dart';

class SalesScreen extends StatefulWidget {
  const SalesScreen({super.key});
  @override
  State<SalesScreen> createState() => _SalesScreenState();
}

class _SalesScreenState extends State<SalesScreen> {
  String _q = '';
  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const NewInvoicePage())),
          icon: const Icon(Icons.add),
          label: const Text('فاتورة جديدة'),
        ),
        body: Column(children: [
          SearchBox(onChanged: (v) => setState(() => _q = v), hint: 'ابحث باسم المريض أو رقم الفاتورة أو الهاتف'),
          Expanded(
            child: StreamBuilder<List<Invoice>>(
              stream: context.repo.watchInvoices(query: _q),
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final list = snap.data!;
                if (list.isEmpty) return const EmptyState(Icons.receipt_long, 'لا توجد فواتير بعد');
                return Centered(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final inv = list[i];
                      return ListTile(
                        title: Text(inv.patientName),
                        subtitle: Text('${inv.number} • ${dateTimeFmt(inv.createdAt)}'),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(money(inv.total), style: const TextStyle(fontWeight: FontWeight.bold)),
                          if (inv.paymentStatus != 'paid')
                            Text(paymentStatusLabel(inv.paymentStatus), style: TextStyle(color: Colors.orange.shade800, fontSize: 12)),
                        ]),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => InvoiceDetailPage(invoiceId: inv.id))),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      );
}

// ═════════════ فاتورة جديدة ═════════════

class _Line {
  final Product product;
  final int stock;
  int qty;
  int price;
  _Line(this.product, this.stock) : qty = 1, price = product.salePrice;
}

class NewInvoicePage extends StatefulWidget {
  const NewInvoicePage({super.key});
  @override
  State<NewInvoicePage> createState() => _NewInvoicePageState();
}

class _NewInvoicePageState extends State<NewInvoicePage> {
  final _form = GlobalKey<FormState>();
  final name = TextEditingController();
  final phone = TextEditingController();
  final discount = TextEditingController(text: '0');
  final paid = TextEditingController();
  final notes = TextEditingController();
  final lines = <_Line>[];
  String method = 'cash';
  bool _saving = false;

  int get subtotal => lines.fold(0, (a, l) => a + l.qty * l.price);
  int get disc => parseInt(discount.text) ?? 0;
  int get total => subtotal - disc;

  Future<void> _addProduct(Product p) async {
    final i = lines.indexWhere((l) => l.product.id == p.id);
    final stock = await context.repo.stockOf(p.id);
    if (!mounted) return;
    setState(() {
      if (i >= 0) {
        lines[i].qty++;
      } else {
        lines.add(_Line(p, stock));
      }
    });
  }

  Future<void> _pick() async {
    final p = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _ProductPicker(),
    );
    if (p != null) _addProduct(p);
  }

  Future<void> _scan() async {
    final raw = await scanBarcode(context);
    if (raw == null || !mounted) return;
    final code = parseGs1(raw).gtin ?? raw;
    final p = await context.repo.productByBarcode(code);
    if (!mounted) return;
    if (p == null) {
      snack(context, 'لا يوجد صنف بالباركود $code', error: true);
      return;
    }
    _addProduct(p);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    if (lines.isEmpty) {
      snack(context, 'أضف صنفاً واحداً على الأقل', error: true);
      return;
    }
    if (disc < 0 || disc > subtotal) {
      snack(context, 'قيمة الخصم غير صالحة', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final paidAmt = paid.text.trim().isEmpty ? total : (parseInt(paid.text) ?? total);
      final inv = await context.repo.createInvoice(
        patientName: name.text.trim(),
        patientPhone: phone.text.trim(),
        lines: [for (final l in lines) InvoiceLine(l.product.id, l.qty, l.price)],
        discount: disc,
        paymentMethod: method,
        paidAmount: paidAmt,
        notes: notes.text.trim(),
      );
      if (!mounted) return;
      Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => InvoiceDetailPage(invoiceId: inv.id)));
    } on InsufficientStock catch (e) {
      snack(context, e.toString(), error: true);
    } catch (e) {
      snack(context, 'تعذّر حفظ الفاتورة: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = isWide(context);
    final itemsPane = Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          Expanded(child: FilledButton.icon(onPressed: _pick, icon: const Icon(Icons.add), label: const Text('إضافة صنف'))),
          const SizedBox(width: 8),
          IconButton.filledTonal(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), tooltip: 'مسح باركود'),
        ]),
      ),
      Expanded(
        child: lines.isEmpty
            ? const EmptyState(Icons.shopping_cart_outlined, 'أضف الأصناف بالبحث أو بمسح الباركود')
            : ListView.separated(
                itemCount: lines.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final l = lines[i];
                  final over = l.qty > l.stock;
                  return ListTile(
                    title: Text(l.product.name),
                    subtitle: Text('${money(l.price)} × ${l.qty} = ${money(l.price * l.qty)}${over ? '\nالمتاح ${l.stock} فقط' : ''}',
                        style: TextStyle(color: over ? Theme.of(context).colorScheme.error : null)),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: l.qty > 1 ? () => setState(() => l.qty--) : null),
                      Text('${l.qty}', style: const TextStyle(fontWeight: FontWeight.bold)),
                      IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => setState(() => l.qty++)),
                      IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => lines.removeAt(i))),
                    ]),
                    onTap: () async {
                      final c = TextEditingController(text: '${l.price}');
                      final v = await showDialog<int>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: const Text('سعر الوحدة'),
                          content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true),
                          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')), FilledButton(onPressed: () => Navigator.pop(ctx, parseInt(c.text)), child: const Text('حفظ'))],
                        ),
                      );
                      if (v != null && v >= 0) setState(() => l.price = v);
                    },
                  );
                },
              ),
      ),
    ]);

    final side = Form(
      key: _form,
      child: ListView(padding: const EdgeInsets.all(12), children: [
        formField('اسم المريض *', name, required: true),
        formField('هاتف المريض', phone, type: TextInputType.phone),
        Row(children: [
          Expanded(child: formField('الخصم', discount, type: TextInputType.number, onChanged: (_) => setState(() {}))),
          const SizedBox(width: 8),
          Expanded(child: formField('المدفوع (اتركه فارغاً = كامل)', paid, type: TextInputType.number)),
        ]),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: DropdownButtonFormField<String>(
            initialValue: method,
            decoration: const InputDecoration(labelText: 'طريقة الدفع', border: OutlineInputBorder()),
            items: [for (final m in ['cash', 'card', 'transfer', 'credit']) DropdownMenuItem(value: m, child: Text(paymentMethodLabel(m)))],
            onChanged: (v) => setState(() => method = v ?? 'cash'),
          ),
        ),
        formField('ملاحظات', notes),
        const Divider(),
        _row('المجموع', money(subtotal)),
        _row('الخصم', money(disc)),
        _row('الإجمالي', money(total), bold: true),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _saving ? null : _save,
          icon: const Icon(Icons.check),
          label: const Text('حفظ الفاتورة'),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        ),
      ]),
    );

    return Scaffold(
      appBar: AppBar(title: const Text('فاتورة جديدة')),
      body: wide
          ? Row(children: [Expanded(flex: 3, child: itemsPane), const VerticalDivider(width: 1), Expanded(flex: 2, child: side)])
          : Column(children: [
              Expanded(flex: 4, child: itemsPane),
              const Divider(height: 1),
              Expanded(flex: 5, child: side),
            ]),
    );
  }

  Widget _row(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.bold : null, fontSize: bold ? 18 : null)),
          Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : null, fontSize: bold ? 18 : null)),
        ]),
      );
}

class _ProductPicker extends StatefulWidget {
  const _ProductPicker();
  @override
  State<_ProductPicker> createState() => _ProductPickerState();
}

class _ProductPickerState extends State<_ProductPicker> {
  String _q = '';
  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(children: [
          SearchBox(onChanged: (v) => setState(() => _q = v), hint: 'ابحث عن صنف'),
          Expanded(
            child: StreamBuilder<List<ProductStock>>(
              stream: context.repo.watchProducts(query: _q),
              builder: (ctx, s) {
                final list = s.data ?? [];
                if (list.isEmpty) return const EmptyState(Icons.search_off, 'لا نتائج');
                return ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ListTile(
                    enabled: list[i].stock > 0,
                    title: Text(list[i].product.name),
                    subtitle: Text('المتاح ${list[i].stock} • ${money(list[i].product.salePrice)}'),
                    onTap: () => Navigator.pop(context, list[i].product),
                  ),
                );
              },
            ),
          ),
        ]),
      );
}

// ═════════════ تفاصيل الفاتورة ═════════════

class InvoiceDetailPage extends StatefulWidget {
  final int invoiceId;
  const InvoiceDetailPage({super.key, required this.invoiceId});
  @override
  State<InvoiceDetailPage> createState() => _InvoiceDetailPageState();
}

class _InvoiceDetailPageState extends State<InvoiceDetailPage> {
  Invoice? inv;
  List<InvoiceItem> items = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.appRead.db;
    final i = await (db.select(db.invoices)..where((t) => t.id.equals(widget.invoiceId))).getSingleOrNull();
    final it = i == null ? <InvoiceItem>[] : await context.repoRead.invoiceItems(i.id);
    if (mounted) setState(() {
      inv = i;
      items = it;
    });
  }

  Future<List<int>> _pdf() async => buildInvoicePdf(inv!, items, context.app.pharmacy);

  @override
  Widget build(BuildContext context) {
    final i = inv;
    if (i == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(i.number), actions: [
        IconButton(
            tooltip: 'مشاركة / تصدير PDF',
            icon: const Icon(Icons.share),
            onPressed: () async => Printing.sharePdf(bytes: Uint8List.fromList(await _pdf()), filename: '${i.number}.pdf')),
        IconButton(
            tooltip: 'طباعة',
            icon: const Icon(Icons.print),
            onPressed: () => Printing.layoutPdf(onLayout: (_) async => Uint8List.fromList(await _pdf()), name: i.number)),
        PopupMenuButton<String>(
          onSelected: (v) async {
            if (v == 'settle') {
              await context.repo.settleInvoice(i.id);
              _load();
            } else if (v == 'void') {
              if (await confirm(context, 'حذف الفاتورة؟', body: 'ستعود الكميات إلى المخزون ولا يمكن التراجع.', danger: true, ok: 'حذف')) {
                await context.repo.voidInvoice(i.id);
                if (context.mounted) Navigator.pop(context);
              }
            }
          },
          itemBuilder: (_) => [
            if (i.paymentStatus != 'paid') const PopupMenuItem(value: 'settle', child: Text('تسجيل السداد الكامل')),
            const PopupMenuItem(value: 'void', child: Text('حذف الفاتورة وإرجاع الكميات')),
          ],
        ),
      ]),
      body: Centered(
        maxWidth: 700,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text(context.app.pharmacy.name.isEmpty ? 'صيدلية' : context.app.pharmacy.name, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text('المريض: ${i.patientName}${i.patientPhone.isEmpty ? '' : ' • ${i.patientPhone}'}'),
          Text('التاريخ: ${dateTimeFmt(i.createdAt)}'),
          const Divider(height: 24),
          for (final it in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(it.productName),
              subtitle: Text('${money(it.unitPrice)} × ${it.quantity}'),
              trailing: Text(money(it.lineTotal), style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          const Divider(height: 24),
          _r('المجموع', money(i.subtotal)),
          if (i.discount > 0) _r('الخصم', money(i.discount)),
          _r('الإجمالي', money(i.total), bold: true),
          _r('طريقة الدفع', paymentMethodLabel(i.paymentMethod)),
          _r('حالة الدفع', paymentStatusLabel(i.paymentStatus)),
          if (i.paymentStatus != 'paid') _r('المتبقي', money(i.total - i.paidAmount)),
          if (i.notes.isNotEmpty) _r('ملاحظات', i.notes),
        ]),
      ),
    );
  }

  Widget _r(String k, String v, {bool bold = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(k, style: TextStyle(fontWeight: bold ? FontWeight.bold : null)),
          Flexible(child: Text(v, style: TextStyle(fontWeight: bold ? FontWeight.bold : null, fontSize: bold ? 18 : null))),
        ]),
      );
}
