import 'package:drift/drift.dart';

import '../core/format.dart';
import 'database.dart';
import 'table_reader.dart';

enum ImportAction { create, update, unchanged, invalid }

class ImportRowResult {
  final int line; // رقم السطر في الملف (يبدأ من 2 بعد الترويسة)
  final ImportAction action;
  final String label;
  final String? error;
  const ImportRowResult(this.line, this.action, this.label, [this.error]);
}

class ImportPreview {
  final List<ImportRowResult> rows;
  final String? fatalError;
  const ImportPreview(this.rows, [this.fatalError]);
  int count(ImportAction a) => rows.where((r) => r.action == a).length;
  bool get canApply =>
      fatalError == null && rows.any((r) => r.action == ImportAction.create || r.action == ImportAction.update);
}

// ═════════════ استيراد الجرد (أصناف + دفعات) ═════════════
// أعمدة: اسم الصنف، الباركود، التصنيف، المقاس، اللون، الكمية، التكلفة، السعر، الحد الأدنى، (اختياري) الدفعة والانتهاء...
// الأصناف الموجودة (بالباركود أو الاسم) تُستخدم كما هي دون تعديل أسعارها؛ تُضاف الدفعات فقط.

class InventoryImporter {
  final AppDatabase db;
  InventoryImporter(this.db);

  static String _key(String name, String size, String color) =>
      [normKey(name), normKey(size), normKey(color)].join('|');

  Future<ImportPreview> preview(ParsedTable t) async {
    if (!hasColumn(t, 'name')) {
      return const ImportPreview([], 'لم أجد عمود "اسم الصنف" في الملف');
    }
    final products = await db.select(db.products).get();
    final byBarcode = {for (final p in products) if (p.barcode != null) p.barcode!: p};
    final byName = {for (final p in products) _key(p.name, p.size, p.color): p};
    final res = <ImportRowResult>[];
    for (var i = 0; i < t.rows.length; i++) {
      final r = t.rows[i];
      final name = field(r, 'name');
      final err = _validate(r);
      if (err != null) {
        res.add(ImportRowResult(i + 2, ImportAction.invalid, name, err));
        continue;
      }
      final bc = normalizeDigits(field(r, 'barcode')).trim();
      final exists = (bc.isNotEmpty ? byBarcode[bc] : null) ?? byName[_key(name, field(r, 'size'), field(r, 'color'))];
      res.add(ImportRowResult(i + 2, exists == null ? ImportAction.create : ImportAction.update, name));
    }
    return ImportPreview(res);
  }

  String? _validate(Map<String, String> r) {
    if (field(r, 'name').isEmpty) return 'الاسم فارغ';
    final q = field(r, 'quantity');
    if (q.isNotEmpty) {
      final v = parseQty(q);
      if (v == null || v < 0) return 'كمية غير صالحة: $q';
    }
    final e = field(r, 'expiry');
    if (e.isNotEmpty && parseDate(e) == null) return 'تاريخ غير صالح: $e';
    for (final k in ['cost', 'price']) {
      final v = field(r, k);
      if (v.isNotEmpty && (parseInt(v) == null || parseInt(v)! < 0)) return 'رقم غير صالح: $v';
    }
    final m = field(r, 'minStock');
    if (m.isNotEmpty && (parseQty(m) == null || parseQty(m)! < 0)) return 'رقم غير صالح: $m';
    return null;
  }

  Future<({int products, int batches, int skipped})> apply(ParsedTable t) async {
    if (!hasColumn(t, 'name')) throw StateError('لم أجد عمود "اسم الصنف"');
    var np = 0, nb = 0, skipped = 0;
    await db.transaction(() async {
      final products = await db.select(db.products).get();
      final byBarcode = {for (final p in products) if (p.barcode != null) p.barcode!: p};
      final byName = {for (final p in products) _key(p.name, p.size, p.color): p};
      for (final r in t.rows) {
        if (_validate(r) != null) {
          skipped++;
          continue;
        }
        final name = field(r, 'name');
        final size = field(r, 'size'), color = field(r, 'color');
        final bc = normalizeDigits(field(r, 'barcode')).replaceAll(RegExp(r'\s'), '');
        final hasExpiry = parseDate(field(r, 'expiry')) != null;
        var prod = (bc.isNotEmpty ? byBarcode[bc] : null) ?? byName[_key(name, size, color)];
        int pid;
        if (prod == null) {
          pid = await db.into(db.products).insert(ProductsCompanion.insert(
                name: name,
                category: Value(field(r, 'category')),
                size: Value(size),
                color: Value(color),
                unit: field(r, 'unit').isEmpty ? const Value.absent() : Value(field(r, 'unit')),
                salePrice: Value(parseInt(field(r, 'price')) ?? 0),
                costPrice: Value(parseInt(field(r, 'cost')) ?? 0),
                minStock: Value(parseQty(field(r, 'minStock')) ?? 0),
                barcode: Value(bc.isEmpty ? null : bc),
                trackExpiry: Value(hasExpiry),
              ));
          prod = await (db.select(db.products)..where((x) => x.id.equals(pid))).getSingle();
          if (bc.isNotEmpty) byBarcode[bc] = prod;
          byName[_key(name, size, color)] = prod;
          np++;
        } else {
          pid = prod.id;
          // وجود تاريخ انتهاء في الملف يفعّل تتبع الصلاحية للصنف الموجود.
          if (hasExpiry && !prod.trackExpiry) {
            await (db.update(db.products)..where((x) => x.id.equals(pid))).write(const ProductsCompanion(trackExpiry: Value(true)));
          }
        }
        final qty = parseQty(field(r, 'quantity')) ?? 0;
        if (qty > 0) {
          await db.into(db.batches).insert(BatchesCompanion.insert(
                productId: pid,
                batchNo: Value(field(r, 'batchNo')),
                quantity: Value(qty),
                expiry: Value(parseDate(field(r, 'expiry'))),
                cost: Value(parseInt(field(r, 'cost')) ?? 0),
                location: Value(field(r, 'location')),
                notes: const Value('مستورد من ملف'),
              ));
          nb++;
        }
      }
    });
    return (products: np, batches: nb, skipped: skipped);
  }
}

String inventoryTemplateCsv() =>
    '\uFEFFاسم الصنف,الباركود,التصنيف,الوحدة,المقاس,اللون,الكمية,التكلفة,السعر,الحد الأدنى,رقم الدفعة,تاريخ الانتهاء,موقع التخزين\n'
    'قميص قطن,6221000000011,رجالي,قطعة,M,أزرق,20,8000,15000,5,,,رف A1\n'
    'أرز مصري,6221000000028,مواد غذائية,كغ,,,50.5,9000,12000,10,B100,2027-12-31,مستودع\n';
