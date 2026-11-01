import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

import 'tables.dart';

part 'database.g.dart';

/// رقم مخطط قاعدة البيانات. ارفعه عند كل تعديل في الجداول وأضف خطوة في [onUpgrade].
const int kSchemaVersion = 1;

@DriftDatabase(tables: [
  CatalogCompanies,
  CatalogDrugs,
  Suppliers,
  Products,
  Batches,
  PurchaseOrders,
  PurchaseOrderItems,
  Invoices,
  InvoiceItems,
  InvoiceItemBatches,
  AppSettings,
])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  /// قاعدة بيانات في ذاكرة مؤقتة للاختبارات.
  AppDatabase.memory() : super(NativeDatabase.memory());

  @override
  int get schemaVersion => kSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          // مثال للمستقبل:
          // if (from < 2) { await m.addColumn(products, products.xyz); }
          await _createIndexes();
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
        },
      );

  Future<void> _createIndexes() async {
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_batches_product ON batches(product_id)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_batches_expiry ON batches(expiry)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode)');
    await customStatement(
        'CREATE INDEX IF NOT EXISTS idx_invoice_items_invoice ON invoice_items(invoice_id)');
  }

  // ───────── إعدادات ─────────
  Future<String?> getSetting(String key) async {
    final row = await (select(appSettings)..where((t) => t.key.equals(key)))
        .getSingleOrNull();
    return row?.value;
  }

  Future<void> setSetting(String key, String value) =>
      into(appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value));

  /// ينشئ رقم الفاتورة التالي داخل المعاملة الحالية.
  Future<String> nextInvoiceNumber() async {
    final cur = int.tryParse(await getSetting('invoice_counter') ?? '0') ?? 0;
    final next = cur + 1;
    await setSetting('invoice_counter', '$next');
    return 'INV-${next.toString().padLeft(6, '0')}';
  }
}

Future<File> databaseFile() async {
  final dir = await getApplicationDocumentsDirectory();
  return File(p.join(dir.path, 'nasaq_pharma.sqlite'));
}

AppDatabase openAppDatabase() =>
    AppDatabase(LazyDatabase(() async => NativeDatabase.createInBackground(await databaseFile())));
