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

// ═════════════ استيراد الكتالوج (أدوية وشركات) ═════════════
//
// يلمس جدولي CatalogDrugs وCatalogCompanies فقط. لا يقرب الأصناف ولا الدفعات
// ولا الفواتير ولا المشتريات أبداً، فلا تتأثر الأرصدة والبيانات المالية.

class _Drug {
  final String? barcode;
  final String name, sci, category, unit, company, country;
  final int? price;
  _Drug(this.barcode, this.name, this.sci, this.category, this.unit, this.company,
      this.country, this.price);
}

class CatalogImporter {
  final AppDatabase db;
  CatalogImporter(this.db);

  List<(int, _Drug?, String?)> _parse(ParsedTable t) {
    final out = <(int, _Drug?, String?)>[];
    for (var i = 0; i < t.rows.length; i++) {
      final r = t.rows[i];
      final name = field(r, 'tradeName');
      if (name.isEmpty) {
        out.add((i + 2, null, 'الاسم التجاري فارغ'));
        continue;
      }
      final priceStr = field(r, 'price');
      final price = parseInt(priceStr);
      if (priceStr.isNotEmpty && (price == null || price < 0)) {
        out.add((i + 2, null, 'السعر غير صالح: $priceStr'));
        continue;
      }
      final bc = normalizeDigits(field(r, 'barcode')).replaceAll(RegExp(r'\s'), '');
      out.add((
        i + 2,
        _Drug(bc.isEmpty ? null : bc, name, field(r, 'scientificName'), field(r, 'category'),
            field(r, 'unit'), field(r, 'company'), field(r, 'country'), price),
        null
      ));
    }
    return out;
  }

  Future<ImportPreview> preview(ParsedTable t) async {
    if (!hasColumn(t, 'tradeName')) {
      return const ImportPreview([], 'لم أجد عمود "الاسم التجاري" في الملف');
    }
    final drugs = await db.select(db.catalogDrugs).get();
    final byBarcode = {for (final d in drugs) if (d.barcode != null) d.barcode!: d};
    final byName = {for (final d in drugs) '${normKey(d.tradeName)}|${normKey(d.scientificName)}': d};
    final companies = {for (final c in await db.select(db.catalogCompanies).get()) normKey(c.name): c};
    final results = <ImportRowResult>[];
    final seen = <String>{};
    for (final (line, d, err) in _parse(t)) {
      if (d == null) {
        results.add(ImportRowResult(line, ImportAction.invalid, '', err));
        continue;
      }
      final key = d.barcode ?? '${normKey(d.name)}|${normKey(d.sci)}';
      if (!seen.add(key)) {
        results.add(ImportRowResult(line, ImportAction.invalid, d.name, 'مكرر داخل الملف'));
        continue;
      }
      final existing = (d.barcode != null ? byBarcode[d.barcode!] : null) ??
          byName['${normKey(d.name)}|${normKey(d.sci)}'];
      if (existing == null) {
        results.add(ImportRowResult(line, ImportAction.create, d.name));
      } else {
        final comp = d.company.isEmpty ? null : companies[normKey(d.company)];
        final changed = existing.tradeName != d.name ||
            (d.sci.isNotEmpty && existing.scientificName != d.sci) ||
            (d.category.isNotEmpty && existing.category != d.category) ||
            (d.unit.isNotEmpty && existing.unit != d.unit) ||
            (d.price != null && existing.referencePrice != d.price) ||
            (d.barcode != null && existing.barcode != d.barcode) ||
            (d.company.isNotEmpty && (comp == null || existing.companyId != comp.id));
        results.add(ImportRowResult(
            line, changed ? ImportAction.update : ImportAction.unchanged, d.name));
      }
    }
    return ImportPreview(results);
  }

  /// يطبّق الاستيراد. الصفوف غير الصالحة تُتخطى. لا حذف لأي شيء غائب عن الملف.
  Future<({int created, int updated})> apply(ParsedTable t) async {
    if (!hasColumn(t, 'tradeName')) throw StateError('لم أجد عمود "الاسم التجاري"');
    var created = 0, updated = 0;
    await db.transaction(() async {
      final companyIds = {
        for (final c in await db.select(db.catalogCompanies).get()) normKey(c.name): c.id
      };
      final drugs = await db.select(db.catalogDrugs).get();
      final byBarcode = {for (final d in drugs) if (d.barcode != null) d.barcode!: d};
      final byName = {for (final d in drugs) '${normKey(d.tradeName)}|${normKey(d.scientificName)}': d};
      final seen = <String>{};
      for (final (_, d, _) in _parse(t)) {
        if (d == null) continue;
        final key = d.barcode ?? '${normKey(d.name)}|${normKey(d.sci)}';
        if (!seen.add(key)) continue;
        int? companyId;
        if (d.company.isNotEmpty) {
          final k = normKey(d.company);
          companyId = companyIds[k];
          if (companyId == null) {
            companyId = await db.into(db.catalogCompanies).insert(
                CatalogCompaniesCompanion.insert(name: d.company, country: Value(d.country)));
            companyIds[k] = companyId;
          } else if (d.country.isNotEmpty) {
            await (db.update(db.catalogCompanies)..where((c) => c.id.equals(companyId!)))
                .write(CatalogCompaniesCompanion(country: Value(d.country)));
          }
        }
        final existing = (d.barcode != null ? byBarcode[d.barcode!] : null) ??
            byName['${normKey(d.name)}|${normKey(d.sci)}'];
        if (existing == null) {
          final id = await db.into(db.catalogDrugs).insert(CatalogDrugsCompanion.insert(
                tradeName: d.name,
                barcode: Value(d.barcode),
                scientificName: Value(d.sci),
                category: Value(d.category),
                unit: Value(d.unit),
                companyId: Value(companyId),
                referencePrice: Value(d.price),
              ));
          final row = await (db.select(db.catalogDrugs)..where((x) => x.id.equals(id))).getSingle();
          if (row.barcode != null) byBarcode[row.barcode!] = row;
          byName['${normKey(row.tradeName)}|${normKey(row.scientificName)}'] = row;
          created++;
        } else {
          await (db.update(db.catalogDrugs)..where((x) => x.id.equals(existing.id))).write(
              CatalogDrugsCompanion(
                tradeName: Value(d.name),
                barcode: d.barcode != null ? Value(d.barcode) : const Value.absent(),
                scientificName: d.sci.isNotEmpty ? Value(d.sci) : const Value.absent(),
                category: d.category.isNotEmpty ? Value(d.category) : const Value.absent(),
                unit: d.unit.isNotEmpty ? Value(d.unit) : const Value.absent(),
                companyId: companyId != null ? Value(companyId) : const Value.absent(),
                referencePrice: d.price != null ? Value(d.price) : const Value.absent(),
              ));
          updated++;
        }
      }
    });
    return (created: created, updated: updated);
  }

  Future<List<CatalogDrug>> search(String q, {int limit = 30}) {
    final s = q.trim();
    final sel = db.select(db.catalogDrugs)..limit(limit);
    if (s.isNotEmpty) {
      sel.where((t) => t.tradeName.like('%$s%') | t.scientificName.like('%$s%') | t.barcode.like('%$s%'));
    }
    return sel.get();
  }
}

// ═════════════ استيراد الجرد (أصناف + دفعات) ═════════════
// أعمدة: الاسم التجاري، الباركود، رقم الدفعة، الكمية، تاريخ الانتهاء، التكلفة، السعر، الحد الأدنى...
// الأصناف الموجودة (بالباركود أو الاسم) تُستخدم كما هي دون تعديل أسعارها؛ تُضاف الدفعات فقط.

class InventoryImporter {
  final AppDatabase db;
  InventoryImporter(this.db);

  Future<ImportPreview> preview(ParsedTable t) async {
    if (!hasColumn(t, 'tradeName')) {
      return const ImportPreview([], 'لم أجد عمود "الاسم التجاري" في الملف');
    }
    final products = await db.select(db.products).get();
    final byBarcode = {for (final p in products) if (p.barcode != null) p.barcode!: p};
    final byName = {for (final p in products) normKey(p.name): p};
    final res = <ImportRowResult>[];
    for (var i = 0; i < t.rows.length; i++) {
      final r = t.rows[i];
      final name = field(r, 'tradeName');
      final err = _validate(r);
      if (err != null) {
        res.add(ImportRowResult(i + 2, ImportAction.invalid, name, err));
        continue;
      }
      final bc = normalizeDigits(field(r, 'barcode')).trim();
      final exists = (bc.isNotEmpty ? byBarcode[bc] : null) ?? byName[normKey(name)];
      res.add(ImportRowResult(i + 2, exists == null ? ImportAction.create : ImportAction.update, name));
    }
    return ImportPreview(res);
  }

  String? _validate(Map<String, String> r) {
    if (field(r, 'tradeName').isEmpty) return 'الاسم فارغ';
    final q = field(r, 'quantity');
    if (q.isNotEmpty) {
      final v = parseInt(q);
      if (v == null || v < 0) return 'كمية غير صالحة: $q';
    }
    final e = field(r, 'expiry');
    if (e.isNotEmpty && parseDate(e) == null) return 'تاريخ غير صالح: $e';
    for (final k in ['cost', 'price', 'minStock']) {
      final v = field(r, k);
      if (v.isNotEmpty && (parseInt(v) == null || parseInt(v)! < 0)) return 'رقم غير صالح: $v';
    }
    return null;
  }

  Future<({int products, int batches, int skipped})> apply(ParsedTable t) async {
    if (!hasColumn(t, 'tradeName')) throw StateError('لم أجد عمود "الاسم التجاري"');
    var np = 0, nb = 0, skipped = 0;
    await db.transaction(() async {
      final products = await db.select(db.products).get();
      final byBarcode = {for (final p in products) if (p.barcode != null) p.barcode!: p.id};
      final byName = {for (final p in products) normKey(p.name): p.id};
      for (final r in t.rows) {
        if (_validate(r) != null) {
          skipped++;
          continue;
        }
        final name = field(r, 'tradeName');
        final bc = normalizeDigits(field(r, 'barcode')).replaceAll(RegExp(r'\s'), '');
        var pid = (bc.isNotEmpty ? byBarcode[bc] : null) ?? byName[normKey(name)];
        if (pid == null) {
          pid = await db.into(db.products).insert(ProductsCompanion.insert(
                name: name,
                scientificName: Value(field(r, 'scientificName')),
                category: Value(field(r, 'category')),
                unit: field(r, 'unit').isEmpty ? const Value.absent() : Value(field(r, 'unit')),
                salePrice: Value(parseInt(field(r, 'price')) ?? 0),
                costPrice: Value(parseInt(field(r, 'cost')) ?? 0),
                minStock: Value(parseInt(field(r, 'minStock')) ?? 0),
                barcode: Value(bc.isEmpty ? null : bc),
              ));
          if (bc.isNotEmpty) byBarcode[bc] = pid;
          byName[normKey(name)] = pid;
          np++;
        }
        final qty = parseInt(field(r, 'quantity')) ?? 0;
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

String catalogTemplateCsv() =>
    '﻿الباركود,الاسم التجاري,الاسم العلمي,التصنيف,الوحدة,الشركة,بلد الشركة,السعر المرجعي\n'
    '6221000000011,بنادول 500 ملغ,Paracetamol,مسكنات,علبة,شركة الأمل,سوريا,5000\n';

String inventoryTemplateCsv() =>
    '﻿الاسم التجاري,الباركود,رقم الدفعة,الكمية,تاريخ الانتهاء,التكلفة,السعر,الحد الأدنى,موقع التخزين\n'
    'بنادول 500 ملغ,6221000000011,B1234,50,2027-12-31,4000,5000,10,رف A1\n';
