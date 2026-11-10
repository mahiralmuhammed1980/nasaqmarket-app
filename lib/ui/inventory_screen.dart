import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../core/gs1.dart';
import '../data/database.dart';
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
  String? _category;

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

  Future<void> _pickCategory() async {
    final cats = await context.repo.categories();
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      builder: (_) => SafeArea(
        child: cats.isEmpty
            ? const SizedBox(height: 160, child: EmptyState(Icons.category_outlined, 'لا توجد تصنيفات بعد. أضف تصنيفاً عند إنشاء الصنف.'))
            : ListView(shrinkWrap: true, children: [for (final c in cats) ListTile(title: Text(c), onTap: () => Navigator.pop(context, c))]),
      ),
    );
    if (picked != null) setState(() => _category = picked);
  }

  @override
  Widget build(BuildContext context) {
    final cfg = context.app.cfg;
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ProductFormPage())),
        icon: const Icon(Icons.add),
        label: const Text('صنف جديد'),
      ),
      body: Column(children: [
        SearchBox(
          hint: cfg.variants ? 'ابحث بالاسم أو المقاس أو اللون أو الباركود' : 'ابحث بالاسم أو التصنيف أو الباركود',
          onChanged: (v) => setState(() => _q = v),
          trailing: IconButton.filledTonal(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), tooltip: 'مسح باركود'),
        ),
        SizedBox(
          height: 48,
          child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
            for (final (k, l) in [
              ('all', 'الكل'),
              ('low', 'منخفض'),
              ('out', 'نفد'),
              if (cfg.expiry) ('expiring', 'قريب الانتهاء'),
            ])
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 8),
                child: ChoiceChip(label: Text(l), selected: _filter == k, onSelected: (_) => setState(() => _filter = k)),
              ),
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: InputChip(
                avatar: const Icon(Icons.category_outlined, size: 18),
                label: Text(_category ?? 'كل التصنيفات'),
                selected: _category != null,
                onDeleted: _category == null ? null : () => setState(() => _category = null),
                onPressed: _pickCategory,
              ),
            ),
          ]),
        ),
        Expanded(
          child: StreamBuilder<List<ProductStock>>(
            stream: context.repo.watchProducts(query: _q, category: _category),
            builder: (ctx, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              var items = snap.data!;
              final soon = DateTime.now().add(const Duration(days: 90));
              items = switch (_filter) {
                'low' => items.where((p) => p.low && p.stock > 0).toList(),
                'out' => items.where((p) => p.stock <= 0).toList(),
                'expiring' => items.where((p) => p.nearestExpiry != null && p.nearestExpiry!.isBefore(soon)).toList(),
                _ => items,
              };
              if (items.isEmpty) return const EmptyState(Icons.inventory_2_outlined, 'لا توجد أصناف مطابقة.\nأضف صنفاً جديداً أو استورد الجرد من «المزيد ← البيانات».');
              return Centered(
                child: ListView.separated(
                  padding: const EdgeInsets.only(bottom: 88),
                  itemCount: items.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final it = items[i];
                    final expSoon = it.product.trackExpiry && it.nearestExpiry != null && it.nearestExpiry!.isBefore(soon);
                    return ListTile(
                      title: Text(it.product.displayName),
                      subtitle: Text([
                        if (it.product.category.isNotEmpty) it.product.category,
                        'السعر ${money(it.product.salePrice)}',
                        if (it.product.trackExpiry && it.nearestExpiry != null) 'أقرب انتهاء ${dateFmt(it.nearestExpiry)}',
                      ].join(' • ')),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(qtyFmt(it.stock),
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: it.stock <= 0 ? Colors.red : (it.low ? Colors.orange.shade800 : null))),
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

List<String> _splitList(String s) =>
    s.split(RegExp(r'[,،;\n]')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

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
  late final cat = TextEditingController(text: widget.product?.category);
  late final unit = TextEditingController(text: widget.product?.unit ?? context.appRead.cfg.type.defaultUnit);
  late final sale = TextEditingController(text: widget.product == null ? '' : '${widget.product!.salePrice}');
  late final cost = TextEditingController(text: widget.product == null ? '' : '${widget.product!.costPrice}');
  late final minStock = TextEditingController(text: widget.product == null ? '0' : qtyFmt(widget.product!.minStock));
  late final barcode = TextEditingController(text: widget.product?.barcode ?? widget.initialBarcode);
  late final notes = TextEditingController(text: widget.product?.notes);
  late final size = TextEditingController(text: widget.product?.size);
  late final color = TextEditingController(text: widget.product?.color);
  // مولّد المتغيّرات (للصنف الجديد فقط)
  final _sizes = <String>{};
  final _colors = <String>{};
  final extraSizes = TextEditingController();
  final extraColors = TextEditingController();
  final initialQty = TextEditingController();
  int? _supplierId;
  late bool _trackExpiry = widget.product?.trackExpiry ?? context.appRead.cfg.expiry;

  bool get _isNew => widget.product == null;

  @override
  void initState() {
    super.initState();
    _supplierId = widget.product?.defaultSupplierId;
  }

  Future<void> _scan() async {
    final raw = await scanBarcode(context);
    if (raw == null) return;
    setState(() => barcode.text = parseGs1(raw).gtin ?? raw);
  }

  List<String> get _allSizes => {..._sizes, ..._splitList(extraSizes.text)}.toList();
  List<String> get _allColors => {..._colors, ..._splitList(extraColors.text)}.toList();
  int get _variantCount {
    final s = _allSizes.length, c = _allColors.length;
    return (s == 0 ? 1 : s) * (c == 0 ? 1 : c);
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final cfg = context.appRead.cfg;
    final repo = context.repoRead;
    final nav = Navigator.of(context);
    final bc = normalizeDigits(barcode.text).trim();
    final generating = _isNew && cfg.variants && (_allSizes.isNotEmpty || _allColors.isNotEmpty);
    if (bc.isNotEmpty) {
      if (generating && _variantCount > 1) {
        snack(context, 'لكل متغيّر باركود مستقل: اترك الباركود فارغاً الآن وأضفه لكل مقاس/لون بعد الحفظ.', error: true);
        return;
      }
      final dup = await repo.productByBarcode(bc);
      if (dup != null && dup.id != widget.product?.id) {
        if (!mounted) return;
        snack(context, 'الباركود مستخدم للصنف: ${dup.displayName}', error: true);
        return;
      }
    }
    final base = ProductsCompanion(
      id: _isNew ? const Value.absent() : Value(widget.product!.id),
      name: Value(name.text.trim()),
      category: Value(cat.text.trim()),
      unit: Value(unit.text.trim().isEmpty ? cfg.type.defaultUnit : unit.text.trim()),
      salePrice: Value(parseInt(sale.text) ?? 0),
      costPrice: Value(parseInt(cost.text) ?? 0),
      minStock: Value(parseQty(minStock.text) ?? 0),
      barcode: Value(bc.isEmpty ? null : bc),
      defaultSupplierId: Value(_supplierId),
      trackExpiry: Value(cfg.expiry && _trackExpiry),
      notes: Value(notes.text.trim()),
    );
    if (generating) {
      await repo.createVariants(
        base: base,
        sizes: _allSizes,
        colors: _allColors,
        initialQty: parseQty(initialQty.text) ?? 0,
      );
    } else {
      final id = await repo.saveProduct(base.copyWith(
        size: Value(cfg.variants ? size.text.trim() : ''),
        color: Value(cfg.variants ? color.text.trim() : ''),
      ));
      final q = parseQty(initialQty.text) ?? 0;
      if (_isNew && q > 0) {
        await repo.saveBatch(BatchesCompanion.insert(
          productId: id,
          quantity: Value(q),
          cost: Value(parseInt(cost.text) ?? 0),
          notes: const Value('رصيد افتتاحي'),
        ));
      }
    }
    if (mounted) nav.pop();
  }

  String? _num(String? v) {
    if (v == null || v.trim().isEmpty) return null;
    final n = parseInt(v);
    return (n == null || n < 0) ? 'أدخل رقماً صحيحاً' : null;
  }

  Widget _menu(List<String> items, void Function(String) pick, {String tooltip = 'اقتراحات'}) => items.isEmpty
      ? const SizedBox.shrink()
      : PopupMenuButton<String>(icon: const Icon(Icons.arrow_drop_down), tooltip: tooltip, onSelected: pick, itemBuilder: (_) => [for (final i in items) PopupMenuItem(value: i, child: Text(i))]);

  Widget _chips(String title, List<String> presets, Set<String> selected) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: Theme.of(context).textTheme.labelLarge),
          Wrap(spacing: 6, children: [
            for (final p in presets)
              FilterChip(
                label: Text(p),
                selected: selected.contains(p),
                onSelected: (v) => setState(() => v ? selected.add(p) : selected.remove(p)),
              ),
          ]),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    final cfg = context.app.cfg;
    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'صنف جديد' : 'تعديل الصنف'), actions: [
        TextButton.icon(onPressed: _save, icon: const Icon(Icons.check), label: const Text('حفظ')),
      ]),
      body: Centered(
        maxWidth: 640,
        child: Form(
          key: _form,
          child: ListView(padding: const EdgeInsets.all(16), children: [
            formField('اسم الصنف *', name, required: true),
            FutureBuilder<List<String>>(
              future: context.repo.categories(),
              builder: (ctx, s) {
                final all = {...cfg.type.categoryHints, ...?s.data}.toList();
                return Row(children: [
                  Expanded(child: formField('التصنيف', cat, suffix: _menu(all, (v) => setState(() => cat.text = v)))),
                  const SizedBox(width: 8),
                  Expanded(child: formField('الوحدة', unit, suffix: _menu(cfg.type.units, (v) => setState(() => unit.text = v)))),
                ]);
              },
            ),
            if (cfg.variants && !_isNew) Row(children: [Expanded(child: formField('المقاس', size)), const SizedBox(width: 8), Expanded(child: formField('اللون', color))]),
            if (cfg.variants && _isNew)
              Card(
                margin: const EdgeInsets.symmetric(vertical: 8),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('المقاسات والألوان', style: Theme.of(context).textTheme.titleSmall),
                    const Text('اختر ما يتوفر لتُنشأ كل التوليفات كأصناف مستقلة (لكل منها مخزونه وباركوده).'),
                    if (cfg.type.sizePresets.isNotEmpty) _chips('المقاسات', cfg.type.sizePresets, _sizes),
                    formField('مقاسات أخرى (افصل بفاصلة)', extraSizes, onChanged: (_) => setState(() {})),
                    if (cfg.type.colorPresets.isNotEmpty) _chips('الألوان', cfg.type.colorPresets, _colors),
                    formField('ألوان أخرى (افصل بفاصلة)', extraColors, onChanged: (_) => setState(() {})),
                    if (_variantCount > 1) Text('سيُنشأ $_variantCount صنفاً', style: TextStyle(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold)),
                  ]),
                ),
              ),
            Row(children: [
              Expanded(child: formField('سعر البيع', sale, type: TextInputType.number, validator: _num)),
              const SizedBox(width: 8),
              Expanded(child: formField('سعر التكلفة', cost, type: TextInputType.number, validator: _num)),
            ]),
            Row(children: [
              Expanded(child: formField('الحد الأدنى للمخزون', minStock, type: cfg.qtyKeyboard, validator: (v) => (v == null || v.trim().isEmpty) ? null : cfg.validateQty(v, allowZero: true))),
              const SizedBox(width: 8),
              if (_isNew) Expanded(child: formField(_variantCount > 1 ? 'الكمية لكل متغيّر' : 'الكمية الحالية', initialQty, type: cfg.qtyKeyboard, validator: (v) => (v == null || v.trim().isEmpty) ? null : cfg.validateQty(v, allowZero: true))),
            ]),
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
            if (cfg.expiry)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('له تاريخ صلاحية'),
                subtitle: const Text('يُطلب تاريخ الانتهاء في الدفعات، ويُخصم الأقرب انتهاءً أولاً، وتظهر تنبيهات الانتهاء'),
                value: _trackExpiry,
                onChanged: (v) => setState(() => _trackExpiry = v),
              ),
            formField('ملاحظات', notes, maxLines: 3),
          ]),
        ),
      ),
    );
  }
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
      appBar: AppBar(title: Text(p.displayName), actions: [
        IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => ProductFormPage(product: p)));
              _load();
            }),
        IconButton(icon: const Icon(Icons.delete_outline), onPressed: _delete),
      ]),
      floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showBatchDialog(context, p.id), icon: const Icon(Icons.add), label: const Text('إضافة كمية')),
      body: Centered(
        child: StreamBuilder<List<StockBatch>>(
          stream: context.repo.watchBatches(p.id),
          builder: (ctx, snap) {
            final batches = snap.data ?? [];
            final total = q3(batches.fold<double>(0, (a, b) => a + b.quantity));
            return ListView(padding: const EdgeInsets.only(bottom: 88), children: [
              Card(
                margin: const EdgeInsets.all(12),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Wrap(spacing: 24, runSpacing: 8, children: [
                      _kv('الكمية الكلية', '${qtyFmt(total)} ${p.unit}'),
                      _kv('سعر البيع', money(p.salePrice)),
                      _kv('التكلفة', money(p.costPrice)),
                      _kv('الحد الأدنى', qtyFmt(p.minStock)),
                      if (p.barcode != null) _kv('الباركود', p.barcode!),
                      if (p.category.isNotEmpty) _kv('التصنيف', p.category),
                      if (p.size.isNotEmpty) _kv('المقاس', p.size),
                      if (p.color.isNotEmpty) _kv('اللون', p.color),
                    ]),
                    if (p.notes.isNotEmpty) ...[const SizedBox(height: 8), Text(p.notes)],
                  ]),
                ),
              ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(p.trackExpiry ? 'الدفعات' : 'الكميات', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
              if (batches.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('لا توجد كميات. أضف كمية لتسجيل المخزون.')),
              for (final b in batches)
                ListTile(
                  leading: Icon(p.trackExpiry ? Icons.event : Icons.inventory_2_outlined, color: p.trackExpiry ? _expColor(b) : null),
                  title: Text('${p.trackExpiry || b.batchNo.isNotEmpty ? 'دفعة ${b.batchNo.isEmpty ? '—' : b.batchNo} • ' : ''}الكمية ${qtyFmt(b.quantity)}'),
                  subtitle: Text('${p.trackExpiry ? 'الانتهاء ${dateFmt(b.expiry)} • ' : ''}تكلفة ${money(b.cost)}${b.location.isEmpty ? '' : ' • ${b.location}'}'),
                  trailing: p.trackExpiry && b.expiry != null && b.expiry!.isBefore(DateTime.now()) && b.quantity > 0
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

/// إضافة/تعديل كمية (دفعة). حقول الدفعة والانتهاء تظهر فقط للأصناف ذات الصلاحية.
/// [gs1] يعبّئ رقم الدفعة والانتهاء تلقائياً من مسح DataMatrix.
Future<void> showBatchDialog(BuildContext context, int productId, {StockBatch? batch, Gs1Data? gs1}) async {
  final repo = context.repo;
  final cfg = context.appRead.cfg;
  final product = await repo.productById(productId);
  if (product == null || !context.mounted) return;
  final withExpiry = product.trackExpiry;
  final no = TextEditingController(text: batch?.batchNo ?? gs1?.batch ?? '');
  final qty = TextEditingController(text: batch == null ? '' : qtyFmt(batch.quantity));
  final exp = TextEditingController(text: batch?.expiry != null ? dateFmt(batch!.expiry) : (gs1?.expiry != null ? dateFmt(gs1!.expiry) : ''));
  final cost = TextEditingController(text: batch == null ? '${product.costPrice}' : '${batch.cost}');
  final loc = TextEditingController(text: batch?.location ?? '');
  final form = GlobalKey<FormState>();
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(batch == null ? 'إضافة كمية' : 'تعديل الكمية'),
      content: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (withExpiry) formField('رقم الدفعة', no),
            formField('الكمية *', qty, type: cfg.qtyKeyboard, validator: (v) => cfg.validateQty(v, allowZero: true)),
            if (withExpiry)
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
                if (await confirm(ctx, 'حذف هذه الكمية؟', danger: true, ok: 'حذف')) {
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
                quantity: Value(cfg.readQty(qty.text) ?? 0),
                expiry: Value(withExpiry ? parseDate(exp.text) : null),
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
