import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/database.dart';
import 'cash_screen.dart';
import 'common.dart';
import 'supplier_statement_page.dart';

class PurchasesScreen extends StatelessWidget {
  const PurchasesScreen({super.key});
  @override
  Widget build(BuildContext context) => DefaultTabController(
        length: 2,
        child: Column(children: [
          const TabBar(tabs: [Tab(text: 'أوامر الشراء'), Tab(text: 'الموردون')]),
          const Expanded(child: TabBarView(children: [_OrdersTab(), _SuppliersTab()])),
        ]),
      );
}

String orderStatusLabel(String s) => switch (s) {
      'draft' => 'مسودة',
      'ordered' => 'تم الطلب',
      'received' => 'مستلم',
      'cancelled' => 'ملغى',
      _ => s,
    };

// ═════════════ الموردون ═════════════

class _SuppliersTab extends StatelessWidget {
  const _SuppliersTab();
  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showSupplierDialog(context), icon: const Icon(Icons.add), label: const Text('مورد جديد')),
        body: StreamBuilder<List<Supplier>>(
          stream: context.repo.watchSuppliers(),
          builder: (ctx, snap) {
            final list = snap.data ?? [];
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            if (list.isEmpty) return const EmptyState(Icons.store_outlined, 'لا يوجد موردون بعد');
            return FutureBuilder<Map<int, int>>(
              future: context.repo.supplierBalances(),
              builder: (ctx, bs) {
                final bal = bs.data ?? {};
                return Centered(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final b = bal[list[i].id] ?? 0;
                      return ListTile(
                        leading: const CircleAvatar(child: Icon(Icons.store)),
                        title: Text(list[i].name),
                        subtitle: Text([list[i].phone, list[i].city, list[i].paymentTerms].where((e) => e.isNotEmpty).join(' • ')),
                        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                          Text(b == 0 ? 'مسدّد' : money(b.abs()), style: TextStyle(fontWeight: FontWeight.bold, color: b > 0 ? Colors.red.shade700 : (b < 0 ? Colors.green.shade700 : null))),
                          Text(b > 0 ? 'مستحق له' : (b < 0 ? 'رصيد لنا' : ''), style: Theme.of(context).textTheme.bodySmall),
                        ]),
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SupplierStatementPage(supplierId: list[i].id))),
                        onLongPress: () => showSupplierDialog(context, supplier: list[i]),
                      );
                    },
                  ),
                );
              },
            );
          },
        ),
      );
}

Future<void> showSupplierDialog(BuildContext context, {Supplier? supplier}) async {
  final f = {
    'name': TextEditingController(text: supplier?.name),
    'contact': TextEditingController(text: supplier?.contact),
    'phone': TextEditingController(text: supplier?.phone),
    'email': TextEditingController(text: supplier?.email),
    'city': TextEditingController(text: supplier?.city),
    'address': TextEditingController(text: supplier?.address),
    'terms': TextEditingController(text: supplier?.paymentTerms),
    'opening': TextEditingController(text: supplier == null ? '' : '${supplier.openingBalance}'),
    'notes': TextEditingController(text: supplier?.notes),
  };
  final form = GlobalKey<FormState>();
  final repo = context.repo;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(supplier == null ? 'مورد جديد' : 'تعديل المورد'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              formField('اسم المورد *', f['name']!, required: true),
              formField('مسؤول التواصل', f['contact']!),
              formField('الهاتف', f['phone']!, type: TextInputType.phone),
              formField('البريد', f['email']!, type: TextInputType.emailAddress),
              formField('المدينة', f['city']!),
              formField('العنوان', f['address']!),
              formField('شروط الدفع', f['terms']!),
              formField('رصيد افتتاحي (ذمم سابقة للمورد)', f['opening']!, type: const TextInputType.numberWithOptions(signed: true)),
              formField('ملاحظات', f['notes']!, maxLines: 2),
            ]),
          ),
        ),
      ),
      actions: [
        if (supplier != null)
          TextButton(
              onPressed: () async {
                if (!await confirm(ctx, 'حذف المورد؟', danger: true, ok: 'حذف')) return;
                try {
                  await repo.deleteSupplier(supplier.id);
                  if (ctx.mounted) Navigator.pop(ctx);
                } on StateError catch (e) {
                  if (ctx.mounted) snack(ctx, e.message, error: true);
                }
              },
              child: const Text('حذف')),
        if (supplier != null)
          TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                Navigator.push(context, MaterialPageRoute(builder: (_) => SupplierStatementPage(supplierId: supplier.id)));
              },
              child: const Text('كشف الحساب')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              await repo.saveSupplier(SuppliersCompanion(
                id: supplier == null ? const Value.absent() : Value(supplier.id),
                name: Value(f['name']!.text.trim()),
                contact: Value(f['contact']!.text.trim()),
                phone: Value(f['phone']!.text.trim()),
                email: Value(f['email']!.text.trim()),
                city: Value(f['city']!.text.trim()),
                address: Value(f['address']!.text.trim()),
                paymentTerms: Value(f['terms']!.text.trim()),
                openingBalance: Value(parseInt(f['opening']!.text) ?? 0),
                notes: Value(f['notes']!.text.trim()),
              ));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('حفظ')),
      ],
    ),
  );
}

// ═════════════ أوامر الشراء ═════════════

class _OrdersTab extends StatelessWidget {
  const _OrdersTab();
  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrderFormPage())),
          icon: const Icon(Icons.add),
          label: const Text('أمر شراء'),
        ),
        body: StreamBuilder<List<PurchaseOrder>>(
          stream: context.repo.watchOrders(),
          builder: (ctx, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) return const EmptyState(Icons.local_shipping_outlined, 'لا توجد أوامر شراء');
            return StreamBuilder<List<Supplier>>(
              stream: context.repo.watchSuppliers(),
              builder: (ctx, sup) {
                final names = {for (final s in sup.data ?? <Supplier>[]) s.id: s.name};
                return Centered(
                  child: ListView.separated(
                    padding: const EdgeInsets.only(bottom: 88),
                    itemCount: list.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => ListTile(
                      title: Text('أمر #${list[i].id} • ${names[list[i].supplierId] ?? ''}'),
                      subtitle: Text(dateFmt(list[i].createdAt)),
                      trailing: Chip(label: Text(orderStatusLabel(list[i].status)), visualDensity: VisualDensity.compact),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => OrderDetailPage(orderId: list[i].id))),
                    ),
                  ),
                );
              },
            );
          },
        ),
      );
}

class _OLine {
  Product product;
  final TextEditingController qty, cost, batch, expiry;
  _OLine(this.product)
      : qty = TextEditingController(text: '1'),
        cost = TextEditingController(text: '${product.costPrice}'),
        batch = TextEditingController(),
        expiry = TextEditingController();
}

class OrderFormPage extends StatefulWidget {
  const OrderFormPage({super.key});
  @override
  State<OrderFormPage> createState() => _OrderFormPageState();
}

class _OrderFormPageState extends State<OrderFormPage> {
  int? supplierId;
  final lines = <_OLine>[];
  final notes = TextEditingController();

  Future<void> _addProduct() async {
    final db = context.app.db;
    final products = await (db.select(db.products)..where((t) => t.archived.equals(false))).get();
    if (!mounted) return;
    final p = await showModalBottomSheet<Product>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SimplePicker(products: products),
    );
    if (p != null) setState(() => lines.add(_OLine(p)));
  }

  Future<void> _save(String status) async {
    if (supplierId == null) return snack(context, 'اختر المورد', error: true);
    if (lines.isEmpty) return snack(context, 'أضف صنفاً واحداً على الأقل', error: true);
    for (final l in lines) {
      final q = parseInt(l.qty.text);
      if (q == null || q <= 0) return snack(context, 'كمية غير صالحة للصنف ${l.product.name}', error: true);
      if (l.expiry.text.trim().isNotEmpty && parseDate(l.expiry.text) == null) {
        return snack(context, 'تاريخ انتهاء غير صالح للصنف ${l.product.name}', error: true);
      }
    }
    await context.repo.createOrder(
      supplierId: supplierId!,
      status: status,
      notes: notes.text.trim(),
      items: [
        for (final l in lines)
          (oid) => PurchaseOrderItemsCompanion.insert(
                orderId: oid,
                productId: l.product.id,
                quantity: parseInt(l.qty.text)!,
                unitCost: parseInt(l.cost.text) ?? 0,
                batchNo: Value(l.batch.text.trim()),
                expiry: Value(parseDate(l.expiry.text)),
              )
      ],
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('أمر شراء جديد')),
        body: Centered(
          maxWidth: 800,
          child: ListView(padding: const EdgeInsets.all(12), children: [
            StreamBuilder<List<Supplier>>(
              stream: context.repo.watchSuppliers(),
              builder: (ctx, s) => DropdownButtonFormField<int>(
                initialValue: supplierId,
                decoration: const InputDecoration(labelText: 'المورد *', border: OutlineInputBorder()),
                items: [for (final x in s.data ?? <Supplier>[]) DropdownMenuItem(value: x.id, child: Text(x.name))],
                onChanged: (v) => setState(() => supplierId = v),
              ),
            ),
            const SizedBox(height: 8),
            for (var i = 0; i < lines.length; i++)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Column(children: [
                    Row(children: [
                      Expanded(child: Text(lines[i].product.name, style: const TextStyle(fontWeight: FontWeight.bold))),
                      IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => lines.removeAt(i))),
                    ]),
                    Row(children: [
                      Expanded(child: formField('الكمية', lines[i].qty, type: TextInputType.number)),
                      const SizedBox(width: 8),
                      Expanded(child: formField('تكلفة الوحدة', lines[i].cost, type: TextInputType.number)),
                    ]),
                    Row(children: [
                      Expanded(child: formField('رقم الدفعة', lines[i].batch)),
                      const SizedBox(width: 8),
                      Expanded(child: formField('الانتهاء', lines[i].expiry)),
                    ]),
                  ]),
                ),
              ),
            OutlinedButton.icon(onPressed: _addProduct, icon: const Icon(Icons.add), label: const Text('إضافة صنف')),
            formField('ملاحظات', notes),
            const SizedBox(height: 12),
            Row(children: [
              Expanded(child: OutlinedButton(onPressed: () => _save('draft'), child: const Text('حفظ كمسودة'))),
              const SizedBox(width: 8),
              Expanded(child: FilledButton(onPressed: () => _save('ordered'), child: const Text('حفظ كمطلوب'))),
            ]),
          ]),
        ),
      );
}

class _SimplePicker extends StatefulWidget {
  final List<Product> products;
  const _SimplePicker({required this.products});
  @override
  State<_SimplePicker> createState() => _SimplePickerState();
}

class _SimplePickerState extends State<_SimplePicker> {
  String q = '';
  @override
  Widget build(BuildContext context) {
    final list = widget.products.where((p) => normKey(p.name).contains(normKey(q)) || (p.barcode ?? '').contains(q)).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .8,
      child: Column(children: [
        SearchBox(onChanged: (v) => setState(() => q = v)),
        Expanded(
          child: list.isEmpty
              ? const EmptyState(Icons.search_off, 'لا نتائج. أضف الصنف أولاً من تبويب المخزون.')
              : ListView.builder(
                  itemCount: list.length,
                  itemBuilder: (_, i) => ListTile(title: Text(list[i].name), onTap: () => Navigator.pop(context, list[i])),
                ),
        ),
      ]),
    );
  }
}

class OrderDetailPage extends StatefulWidget {
  final int orderId;
  const OrderDetailPage({super.key, required this.orderId});
  @override
  State<OrderDetailPage> createState() => _OrderDetailPageState();
}

class _OrderDetailPageState extends State<OrderDetailPage> {
  PurchaseOrder? order;
  List<PurchaseOrderItem> items = [];
  Map<int, String> names = {};
  String supplier = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = context.appRead.db;
    final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(widget.orderId))).getSingleOrNull();
    if (o == null) return;
    final it = await context.repoRead.orderItems(o.id);
    final ps = await db.select(db.products).get();
    final s = await (db.select(db.suppliers)..where((t) => t.id.equals(o.supplierId))).getSingleOrNull();
    if (mounted) setState(() {
      order = o;
      items = it;
      names = {for (final p in ps) p.id: p.name};
      supplier = s?.name ?? '';
    });
  }

  Future<void> _do(Future<void> Function() f, String ok) async {
    try {
      await f();
      if (mounted) snack(context, ok);
      await _load();
    } on StateError catch (e) {
      if (mounted) snack(context, e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final o = order;
    if (o == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final repo = context.repo;
    final open = o.status == 'draft' || o.status == 'ordered';
    return Scaffold(
      appBar: AppBar(title: Text('أمر #${o.id}'), actions: [
        if (o.status != 'received')
          IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                if (await confirm(context, 'حذف الأمر؟', danger: true, ok: 'حذف')) {
                  await repo.deleteOrder(o.id);
                  if (context.mounted) Navigator.pop(context);
                }
              }),
      ]),
      body: Centered(
        maxWidth: 700,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          Text('المورد: $supplier', style: Theme.of(context).textTheme.titleMedium),
          Text('الحالة: ${orderStatusLabel(o.status)} • ${dateFmt(o.createdAt)}'),
          if (o.receivedAt != null) Text('تاريخ الاستلام: ${dateFmt(o.receivedAt)}'),
          const Divider(height: 24),
          for (final it in items)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(names[it.productId] ?? '—'),
              subtitle: Text('${it.quantity} × ${money(it.unitCost)}${it.batchNo.isEmpty ? '' : ' • دفعة ${it.batchNo}'}${it.expiry == null ? '' : ' • ${dateFmt(it.expiry)}'}'),
              trailing: Text(money(it.quantity * it.unitCost)),
            ),
          const Divider(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('الإجمالي', style: TextStyle(fontWeight: FontWeight.bold)),
            Text(money(repo.orderTotal(items)), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ]),
          const SizedBox(height: 16),
          if (open) ...[
            if (o.status == 'draft')
              OutlinedButton(onPressed: () => _do(() => repo.setOrderStatus(o.id, 'ordered'), 'تم تعليم الأمر كمطلوب'), child: const Text('تعليم كمطلوب')),
            FilledButton.icon(
              style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
              onPressed: () async {
                final total = repo.orderTotal(items);
                final r = await _askPayment(context, total);
                if (r == null) return;
                await _do(() => repo.receiveOrder(o.id, paid: r.$1, method: r.$2), 'تم الاستلام وإضافة الدفعات إلى المخزون');
              },
              icon: const Icon(Icons.inventory),
              label: const Text('استلام الأمر وإضافته للمخزون'),
            ),
            TextButton(onPressed: () => _do(() => repo.setOrderStatus(o.id, 'cancelled'), 'تم إلغاء الأمر'), child: const Text('إلغاء الأمر')),
          ],
        ]),
      ),
    );
  }
}


/// حوار الاستلام: المبلغ المدفوع الآن (0 = آجل بالكامل) ووسيلة الدفع.
Future<(int, String)?> _askPayment(BuildContext context, int total) async {
  final c = TextEditingController(text: '$total');
  var method = 'cash';
  String? err;
  return showDialog<(int, String)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('استلام الأمر'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('إجمالي الأمر: ${money(total)}', style: const TextStyle(fontWeight: FontWeight.bold)),
          const Text('ستُضاف الدفعات إلى المخزون ولا يمكن التراجع.'),
          const SizedBox(height: 8),
          TextField(
            controller: c,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(labelText: 'المدفوع الآن (0 = آجل)', border: const OutlineInputBorder(), errorText: err),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: method,
            decoration: const InputDecoration(labelText: 'وسيلة الدفع', border: OutlineInputBorder()),
            items: [for (final m in ['cash', 'card', 'transfer']) DropdownMenuItem(value: m, child: Text(methodLabel(m)))],
            onChanged: (v) => setS(() => method = v ?? 'cash'),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
          FilledButton(
            onPressed: () {
              final n = parseInt(c.text);
              if (n == null || n < 0 || n > total) {
                setS(() => err = 'أدخل مبلغاً بين 0 و${money(total)}');
                return;
              }
              Navigator.pop(ctx, (n, method));
            },
            child: const Text('استلام'),
          ),
        ],
      ),
    ),
  );
}
