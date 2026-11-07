import 'package:drift/drift.dart';

// ───────── الكتالوج المرجعي (يقبل الاستيراد والتحديث) ─────────

class CatalogCompanies extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text().unique()();
  TextColumn get country => text().withDefault(const Constant(''))();
}

class CatalogDrugs extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get barcode => text().nullable().unique()();
  TextColumn get tradeName => text()();
  TextColumn get scientificName => text().withDefault(const Constant(''))();
  TextColumn get category => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant(''))();
  IntColumn get companyId => integer().nullable().references(CatalogCompanies, #id)();
  IntColumn get referencePrice => integer().nullable()();
}

// ───────── بيانات الصيدلية (لا يمسّها استيراد الكتالوج أبداً) ─────────

class Suppliers extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get name => text()();
  TextColumn get contact => text().withDefault(const Constant(''))();
  TextColumn get phone => text().withDefault(const Constant(''))();
  TextColumn get email => text().withDefault(const Constant(''))();
  TextColumn get city => text().withDefault(const Constant(''))();
  TextColumn get address => text().withDefault(const Constant(''))();
  TextColumn get paymentTerms => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  /// رصيد افتتاحي: مبلغ مستحق للمورد قبل بدء استخدام التطبيق (موجب = علينا للمورد).
  IntColumn get openingBalance => integer().withDefault(const Constant(0))();
}

class Products extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get catalogDrugId => integer().nullable().references(CatalogDrugs, #id)();
  TextColumn get name => text()();
  TextColumn get scientificName => text().withDefault(const Constant(''))();
  TextColumn get category => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('علبة'))();
  IntColumn get salePrice => integer().withDefault(const Constant(0))();
  IntColumn get costPrice => integer().withDefault(const Constant(0))();
  IntColumn get minStock => integer().withDefault(const Constant(0))();
  TextColumn get barcode => text().nullable()();
  IntColumn get defaultSupplierId => integer().nullable().references(Suppliers, #id)();
  TextColumn get notes => text().withDefault(const Constant(''))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  /// الشركة المصنّعة (من قائمة الشركات).
  IntColumn get companyId => integer().nullable().references(CatalogCompanies, #id)();
  /// دواء مقيّد: لا يُباع إلا بوصفة وتُسجَّل بياناتها في سجل المقيّدة.
  BoolColumn get isRestricted => boolean().withDefault(const Constant(false))();
}

@DataClassName('StockBatch')
class Batches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  TextColumn get batchNo => text().withDefault(const Constant(''))();
  IntColumn get quantity => integer().withDefault(const Constant(0))();
  DateTimeColumn get expiry => dateTime().nullable()();
  IntColumn get cost => integer().withDefault(const Constant(0))();
  TextColumn get location => text().withDefault(const Constant(''))();
  IntColumn get supplierId => integer().nullable().references(Suppliers, #id)();
  TextColumn get notes => text().withDefault(const Constant(''))();
}

class PurchaseOrders extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get supplierId => integer().references(Suppliers, #id)();
  // draft | ordered | received | cancelled
  TextColumn get status => text().withDefault(const Constant('draft'))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get receivedAt => dateTime().nullable()();
  TextColumn get notes => text().withDefault(const Constant(''))();
}

class PurchaseOrderItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get orderId => integer().references(PurchaseOrders, #id)();
  IntColumn get productId => integer().references(Products, #id)();
  IntColumn get quantity => integer()();
  IntColumn get unitCost => integer()();
  TextColumn get batchNo => text().withDefault(const Constant(''))();
  DateTimeColumn get expiry => dateTime().nullable()();
}

class Invoices extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get patientName => text()();
  TextColumn get patientPhone => text().withDefault(const Constant(''))();
  IntColumn get subtotal => integer()();
  IntColumn get discount => integer().withDefault(const Constant(0))();
  IntColumn get total => integer()();
  TextColumn get paymentMethod => text().withDefault(const Constant('cash'))();
  // paid | partial | unpaid
  TextColumn get paymentStatus => text().withDefault(const Constant('paid'))();
  IntColumn get paidAmount => integer().withDefault(const Constant(0))();
  TextColumn get notes => text().withDefault(const Constant(''))();
}

/// لقطة (snapshot) من اسم الصنف وسعره وقت البيع؛ لا تتأثر بتحديثات لاحقة.
class InvoiceItems extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceId => integer().references(Invoices, #id)();
  IntColumn get productId => integer().nullable().references(Products, #id)();
  TextColumn get productName => text()();
  IntColumn get quantity => integer()();
  IntColumn get unitPrice => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  IntColumn get lineTotal => integer()();
}

/// من أي دفعة خُصمت الكمية (لإرجاع الفواتير الملغاة).
class InvoiceItemBatches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceItemId => integer().references(InvoiceItems, #id)();
  IntColumn get batchId => integer().references(Batches, #id)();
  IntColumn get quantity => integer()();
}

class AppSettings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();
  @override
  Set<Column> get primaryKey => {key};
}

// ───────── الصندوق (حركة الأموال) ─────────

/// حركة مالية. المبلغ بإشارة: موجب = دخل، سالب = خرج.
/// kind: opening | sale | sale_settlement | supplier_payment | expense |
///       owner_in | owner_out | adjustment | void
/// method: cash | card | transfer
class CashEntries extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get kind => text()();
  TextColumn get method => text().withDefault(const Constant('cash'))();
  IntColumn get amount => integer()();
  TextColumn get category => text().withDefault(const Constant(''))();
  TextColumn get note => text().withDefault(const Constant(''))();
  /// ربط بمستند: invoice | order | null
  TextColumn get refType => text().nullable()();
  IntColumn get refId => integer().nullable()();
  IntColumn get supplierId => integer().nullable().references(Suppliers, #id)();
}

/// إغلاق يومي: مطابقة الرصيد النقدي الفعلي مع رصيد النظام.
class CashClosings extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get systemBalance => integer()();
  IntColumn get countedAmount => integer()();
  IntColumn get difference => integer()();
  TextColumn get note => text().withDefault(const Constant(''))();
}

// ───────── سجل الأدوية المقيّدة ─────────

class RestrictedRecords extends Table {
  IntColumn get id => integer().autoIncrement()();
  DateTimeColumn get createdAt => dateTime()();
  IntColumn get invoiceId => integer().nullable()();
  TextColumn get invoiceNumber => text().withDefault(const Constant(''))();
  IntColumn get productId => integer().nullable()();
  TextColumn get productName => text()();
  IntColumn get quantity => integer()();
  TextColumn get prescriptionNo => text()();
  TextColumn get doctorName => text()();
  TextColumn get patientName => text()();
  TextColumn get patientNationalId => text()();
  /// تُعلَّم عند حذف الفاتورة؛ يبقى السجل للمراجعة.
  BoolColumn get voided => boolean().withDefault(const Constant(false))();
}
