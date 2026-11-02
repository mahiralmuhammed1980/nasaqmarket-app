import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../core/gs1.dart';
import '../data/database.dart';
import '../data/importers.dart';
import '../data/repository.dart';
import 'common.dart';
import 'scanner.dart';

class InventoryScreen extends StatefulWidget {
  const InventoryScreen({super.key});
  @override
  State<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends State<InventoryScreen> {
  String _q = '';
  String _filter = 'all'; // all | low | expiring | out

  Future<void> _scan() async {
    final raw = await scanBarcode(context);
    if (raw == null || !mounted) return;
    final gs = parseGs1(raw);
    final code = gs.gtin ?? raw;
    final p = await context.repo.productByBarcode(code);
    if (!mounted) return;
    if (p == null) {
      final create = await confirm(context, 'باركود غير مسجّل', body: 'لا يوجد صنف بالباركود $code. هل تريد إنشاء صنف جديد؟', ok: 'إنشاء');
      if (create && mounted) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => ProductFormPage(initialBarcode: code)));
      }
      return;
    }
    Navigator.push(context, MaterialPageRoute(builder: (_) => ProductDetailPage(productId: p.id, scanned: gs)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProductFormPage())),
        icon: const Icon(Icons.add),
        label: const Text('صنف جديد'),
      ),
      body: Column(children: [
        SearchBox(
          hint: 'ابحث بالاسم أو الاسم العلمي أو الباركود',
          onChanged: (v) => setState(() => _q = v),
          trailing: IconButton.filledTonal(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), tooltip: 'مسح باركود'),
        ),
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final (k, l) in [('all', 'الكل'), ('low', 'منخفض'), ('out', 'نفد'), ('expiring', 'قريب الانتهاء')])
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ChoiceChip(label: Text(l), selected: _filter == k, onSelected: (_) => setState(() => _filter = k)),
              ),
          ]),
        ),
        Expanded(
          child: StreamBuilder<List<ProductStock>>(
            stream: context.repo.watchProducts(query: _q),
            builder: (ctx, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              var items = snap.data!;
              final soon = DateTime.now().add(const Duration(days: 90));
              items = switch (_filter) {
                'low' => items.where((p) => p.low && p.stock > 0).toList(),
                'out' => items.where((p) => p.stock == 0).toList(),
                'expiring' => items.where((p) => p.nearestExpiry != null && p.nearestExpiry!.isBefore(soon)).toList(),
                _ => items,
              };
              if (items.isEmpty) return const EmptyState(Icons.inventory_2_outlined, 'لا توجد أصناف مطابقة.\nأضف صنفاً جديداً أو استورد الجرد من تبويب «البيانات».');
              return Centered(
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final it = items[i];
                    final expSoon = it.nearestExpiry != null && it.nearestExpiry!.isBefore(soon);
                    return ListTile(
                      title: Text(it.product.name),
                      subtitle: Text([
                        if (it.product.scientificName.isNotEmpty) it.product.scientificName,
                        'السعر ${money(it.product.salePrice)}',
                        if (it.nearestExpiry != null) 'أقرب انتهاء ${dateFmt(it.nearestExpiry)}',
                      ].join(' • ')),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text('${it.stock}',
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: it.stock == 0 ? Colors.red : (it.low ? Colors.orange.shade800 : null))),
                        if (expSoon) Icon(Icons.event_busy, size: 16, color: Colors.deepOrange.shade400),
                      ]),
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProductDetailPage(productId: it.product.id))),
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
}

// ═════════════ نموذج الصنف ═════════════

class ProductFormPage extends StatefulWidget {
  final Product? product;
  final String? initialBarcode;
  const ProductFormPage({super.key, this.product, this.initialBarcode});
  @override
  State<ProductFormPage> createState() => _ProductFormPageState();
}

class _ProductFormPageState extends State<ProductFormPage> {
  final _form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.product?.name);
  late final sci = TextEditingController(text: widget.product?.scientificName);
  late final cat = TextEditingController(text: widget.product?.category);
  late final unit = TextEditingController(text: widget.product?.unit ?? 'علبة');
  late final sale = TextEditingController(text: widget.product == null ? '' : '${widget.product!.salePrice}');
  late final cost = TextEditingController(text: widget.product == null ? '' : '${widget.product!.costPrice}');
  late final minStock = TextEditingController(text: widget.product == null ? '0' : '${widget.product!.minStock}');
  late final barcode = TextEditingController(text: widget.product?.barcode ?? widget.initialBarcode);
  late final notes = TextEditingController(text: widget.product?.notes);
  int? _catalogId;
  int? _supplierId;

  @override
  void initState() {
    super.initState();
    _catalogId = widget.product?.catalogDrugId;
    _supplierId = widget.product?.defaultSupplierId;
  }

  Future<void> _pickCatalog() async {
    final d = await showModalBottomSheet<CatalogDrug>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CatalogPicker(importer: CatalogImporter(context.app.db)),
    );
    if (d == null) return;
    setState(() {
      _catalogId = d.id;
      name.text = d.tradeName;
      if (d.scientificName.isNotEmpty) sci.text = d.scientificName;
      if (d.category.isNotEmpty) cat.text = d.category;
      if (d.unit.isNotEmpty) unit.text = d.unit;
      if (d.barcode != null) barcode.text = d.barcode!;
      if (d.referencePrice != null && sale.text.isEmpty) sale.text = '${d.referencePrice}';
    });
  }

  Future<void> _scan() async {
    final raw = await scanBarcode(context);
    if (raw == null) return;
    setState(() => barcode.text = parseGs1(raw).gtin ?? raw);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final bc = normalizeDigits(barcode.text).trim();
    if (bc.isNotEmpty) {
      final dup = await context.repo.productByBarcode(bc);
      if (dup != null && dup.id != widget.product?.id) {
        if (!mounted) return;
        snack(context, 'الباركود مستخدم للصنف: ${dup.name}', error: true);
        return;
      }
    }
    await context.repo.saveProduct(ProductsCompanion(
      id: widget.product == null ? const Value.absent() : Value(widget.product!.id),
      catalogDrugId: Value(_catalogId),
      name: Value(name.text.trim()),
      scientificName: Value(sci.text.trim()),
      category: Value(cat.text.trim()),
      unit: Value(unit.text.trim().isEmpty ? 'علبة' : unit.text.trim()),
      salePrice: Value(parseInt(sale.text) ?? 0),
      costPrice: Value(parseInt(cost.text) ?? 0),
      minStock: Value(parseInt(minStock.text) ?? 0),
      barcode: Value(bc.isEmpty ? null : bc),
      defaultSupplierId: Value(_supplierId),
      notes: Value(notes.text.trim()),
    ));
    if (mounted) Navigator.pop(context);
  }

  String? _num(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final n = parseInt(v);
    return (n == null || n < 0) ? 'أدخل رقماً صحيحاً' : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.product == null ? 'صنف جديد' : 'تعديل الصنف'), actions: [
        TextButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('حفظ')),
      ]),
      body: Centered(
        maxWidth: 640,
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            OutlinedButton.icon(onPressed: _pickCatalog, icon: const Icon(Icons.menu_book), label: const Text('اختيار من كتالوج الأدوية')),
            formField('الاسم التجاري *', name, required: true),
            formField('الاسم العلمي', sci),
            Row(children: [Expanded(child: formField('التصنيف', cat)), const SizedBox(width: 8), Expanded(child: formField('الوحدة', unit))]),
            Row(children: [
              Expanded(child: formField('سعر البيع', sale, type: TextInputType.number, validator: _num)),
              const SizedBox(width: 8),
              Expanded(child: formField('سعر التكلفة', cost, type: TextInputType.number, validator: _num)),
            ]),
            formField('الحد الأدنى للمخزون', minStock, type: TextInputType.number, validator: _num),
            formField('الباركود', barcode,
                type: TextInputType.number,
                suffix: IconButton(icon: const Icon(Icons.qr_code_scanner), onPressed: _scan, tooltip: 'مسح')),
            StreamBuilder<List<Supplier>>(
              stream: context.repo.watchSuppliers(),
              builder: (ctx, s) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: DropdownButtonFormField<int?>(
                  initialValue: s.data?.any((x) => x.id == _supplierId) == true ? _supplierId : null,
                  decoration: const InputDecoration(labelText: 'المورد الافتراضي', border: OutlineInputBorder()),
                  items: [
                    const DropdownMenuItem(value: null, child: Text('— بدون —')),
                    for (final x in s.data ?? <Supplier>[]) DropdownMenuItem(value: x.id, child: Text(x.name)),
                  ],
                  onChanged: (v) => _supplierId = v,
                ),
              ),
            ),
            formField('ملاحظات', notes, maxLines: 3),
          ]),
        ),
      ),
    );
  }
}

class _CatalogPicker extends StatefulWidget {
  final CatalogImporter importer;
  const _CatalogPicker({required this.importer});
  @override
  State<_CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<_CatalogPicker> {
  List<CatalogDrug> _items = [];
  @override
  void initState() {
    super.initState();
    _load('');
  }

  Future<void> _load(String q) async {
    final r = await widget.importer.search(q);
    if (mounted) setState(() => _items = r);
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(children: [
          SearchBox(onChanged: _load, hint: 'ابحث في الكتالوج'),
          Expanded(
            child: _items.isEmpty
                ? const EmptyState(Icons.menu_book, 'الكتالوج فارغ أو لا نتائج.\nاستورد ملف الأدوية من تبويب «البيانات».')
                : ListView.builder(
                    itemCount: _items.length,
                    itemBuilder: (_, i) => ListTile(
                      title: Text(_items[i].tradeName),
                      subtitle: Text(_items[i].scientificName),
                      onTap: () => Navigator.pop(context, _items[i]),
                    ),
                  ),
          ),
        ]),
      );
}

// ═════════════ تفاصيل الصنف والدفعات ═════════════

class ProductDetailPage extends StatefulWidget {
  final int productId;
  final Gs1Data? scanned;
  const ProductDetailPage({super.key, required this.productId, this.scanned});
  @override
  State<ProductDetailPage> createState() => _ProductDetailPageState();
}

class _ProductDetailPageState extends State<ProductDetailPage> {
  Product? _p;
  @override
  void initState() {
    super.initState();
    _load();
    final s = widget.scanned;
    if (s != null && (s.batch != null || s.expiry != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => showBatchDialog(context, widget.productId, gs1: s));
    }
  }

  Future<void> _load() async {
    final p = await context.repoRead.productById(widget.productId);
    if (mounted) setState(() => _p = p);
  }

  Future<void> _delete() async {
    if (!await confirm(context, 'حذف الصنف؟', body: 'إن كان للصنف مبيعات أو مشتريات سابقة فسيُؤرشف مع بقاء الفواتير كما هي.', danger: true, ok: 'حذف')) return;
    await context.repo.deleteProduct(widget.productId);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = _p;
    if (p == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return Scaffold(
      appBar: AppBar(title: Text(p.name), actions: [
        IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => ProductFormPage(product: p)));
              _load();
            }),
        IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showBatchDialog(context, p.id), icon: const Icon(Icons.add), label: const Text('دفعة جديدة')),
      body: Centered(
        child: StreamBuilder<List<StockBatch>>(
          stream: context.repo.watchBatches(p.id),
          builder: (ctx, snap) {
            final batches = snap.data ?? [];
            final total = batches.fold<int>(0, (a, b) => a + b.quantity);
            return ListView(padding: const EdgeInsets.only(bottom: 88), children: [
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    if (p.scientificName.isNotEmpty) Text(p.scientificName, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Wrap(spacing: 24, runSpacing: 8, children: [
                      _kv('الكمية الكلية', '$total ${p.unit}'),
                      _kv('سعر البيع', money(p.salePrice)),
                      _kv('التكلفة', money(p.costPrice)),
                      _kv('الحد الأدنى', '${p.minStock}'),
                      if (p.barcode != null) _kv('الباركود', p.barcode!),
                      if (p.category.isNotEmpty) _kv('التصنيف', p.category),
                    ]),
                    if (p.notes.isNotEmpty) ...[const SizedBox(height: 8), Text(p.notes)],
                  ]),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('الدفعات', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              if (batches.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد دفعات. أضف دفعة لتسجيل الكمية وتاريخ الصلاحية.')),
              for (final b in batches)
                ListTile(
                  leading: Icon(Icons.event, color: _expColor(b)),
                  title: Text('دفعة ${b.batchNo.isEmpty ? '—' : b.batchNo} • الكمية ${b.quantity}'),
                  subtitle: Text('الانتهاء ${dateFmt(b.expiry)} • تكلفة ${money(b.cost)}${b.location.isEmpty ? '' : ' • ${b.location}'}'),
                  trailing: b.expiry != null && b.expiry!.isBefore(DateTime.now()) && b.quantity > 0
                      ? const Chip(label: Text('منتهية'), visualDensity: VisualDensity.compact)
                      : null,
                  onTap: () => showBatchDialog(context, p.id, batch: b),
                ),
            ]);
          },
        ),
      ),
    );
  }

  Color? _expColor(StockBatch b) {
    if (b.expiry == null) return null;
    final d = b.expiry!.difference(DateTime.now()).inDays;
    return d < 0 ? Colors.red : (d < 90 ? Colors.orange.shade800 : Colors.green);
  }

  Widget _kv(String k, String v) => Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text(k, style: Theme.of(context).textTheme.bodySmall),
        Text(v, style: const TextStyle(fontWeight: FontWeight.bold)),
      ]);
}

/// إضافة/تعديل دفعة. [gs1] يعبّئ رقم الدفعة والانتهاء تلقائياً من مسح DataMatrix.
Future<void> showBatchDialog(BuildContext context, int productId, {StockBatch? batch, Gs1Data? gs1}) async {
  final no = TextEditingController(text: batch?.batchNo ?? gs1?.batch ?? '');
  final qty = TextEditingController(text: batch == null ? '' : '${batch.quantity}');
  final exp = TextEditingController(text: batch?.expiry != null ? dateFmt(batch!.expiry) : (gs1?.expiry != null ? dateFmt(gs1!.expiry) : ''));
  final cost = TextEditingController(text: batch == null ? '' : '${batch.cost}');
  final loc = TextEditingController(text: batch?.location ?? '');
  final form = GlobalKey<FormState>();
  final repo = context.repo;
  if (batch == null && cost.text.isEmpty) {
    final p = await repo.productById(productId);
    cost.text = '${p?.costPrice ?? 0}';
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(batch == null ? 'دفعة جديدة' : 'تعديل الدفعة'),
      content: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            formField('رقم الدفعة', no),
            formField('الكمية *', qty, type: TextInputType.number, validator: (v) {
              final n = parseInt(v);
              return (n == null || n < 0) ? 'أدخل كمية صحيحة' : null;
            }),
            formField('تاريخ الانتهاء (yyyy-mm-dd أو mm/yyyy)', exp, validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              return parseDate(v) == null ? 'تاريخ غير صالح' : null;
            },
                suffix: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final d = await showDatePicker(
                          context: ctx,
                          initialDate: parseDate(exp.text) ?? DateTime.now().add(const Duration(days: 365)),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100));
                      if (d != null) exp.text = dateFmt(d);
                    })),
            formField('تكلفة الوحدة', cost, type: TextInputType.number),
            formField('موقع التخزين', loc),
          ]),
        ),
      ),
      actions: [
        if (batch != null)
          TextButton(
              onPressed: () async {
                if (await confirm(ctx, 'حذف الدفعة؟', danger: true, ok: 'حذف')) {
                  await repo.deleteBatch(batch.id);
                  if (ctx.mounted) Navigator.pop(ctx);
                }
              },
              child: const Text('حذف')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              await repo.saveBatch(BatchesCompanion(
                id: batch == null ? const Value.absent() : Value(batch.id),
                productId: Value(productId),
                batchNo: Value(no.text.trim()),
                quantity: Value(parseInt(qty.text) ?? 0),
                expiry: Value(parseDate(exp.text)),
                cost: Value(parseInt(cost.text) ?? 0),
                location: Value(loc.text.trim()),
              ));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('حفظ')),
      ],
    ),
  );
}
