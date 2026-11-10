import 'package:drift/drift.dart';

// ───────── بيانات المحل ─────────

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
  TextColumn get name => text()();
  TextColumn get category => text().withDefault(const Constant(''))();
  TextColumn get unit => text().withDefault(const Constant('قطعة'))();
  IntColumn get salePrice => integer().withDefault(const Constant(0))();
  IntColumn get costPrice => integer().withDefault(const Constant(0))();
  /// الكميات عشرية (كغ/متر...) وتُقرَّب إلى 3 منازل عند كل كتابة.
  RealColumn get minStock => real().withDefault(const Constant(0))();
  TextColumn get barcode => text().nullable()();
  IntColumn get defaultSupplierId => integer().nullable().references(Suppliers, #id)();
  TextColumn get notes => text().withDefault(const Constant(''))();
  BoolColumn get archived => boolean().withDefault(const Constant(false))();
  /// متغيّرات (ألبسة/أحذية): كل مقاس/لون صنف مستقل له باركوده ومخزونه.
  TextColumn get size => text().withDefault(const Constant(''))();
  TextColumn get color => text().withDefault(const Constant(''))();
  /// تاريخ الصلاحية اختياري: عند التفعيل يُطلب في الدفعات ويُنبَّه قبل الانتهاء.
  BoolColumn get trackExpiry => boolean().withDefault(const Constant(false))();
}

@DataClassName('StockBatch')
class Batches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get productId => integer().references(Products, #id)();
  TextColumn get batchNo => text().withDefault(const Constant(''))();
  RealColumn get quantity => real().withDefault(const Constant(0))();
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
  RealColumn get quantity => real()();
  IntColumn get unitCost => integer()();
  TextColumn get batchNo => text().withDefault(const Constant(''))();
  DateTimeColumn get expiry => dateTime().nullable()();
}

class Invoices extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get number => text().unique()();
  DateTimeColumn get createdAt => dateTime()();
  TextColumn get customerName => text().withDefault(const Constant(''))();
  TextColumn get customerPhone => text().withDefault(const Constant(''))();
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
  RealColumn get quantity => real()();
  IntColumn get unitPrice => integer()();
  IntColumn get unitCost => integer().withDefault(const Constant(0))();
  IntColumn get lineTotal => integer()();
}

/// من أي دفعة خُصمت الكمية (لإرجاع الفواتير الملغاة).
class InvoiceItemBatches extends Table {
  IntColumn get id => integer().autoIncrement()();
  IntColumn get invoiceItemId => integer().references(InvoiceItems, #id)();
  IntColumn get batchId => integer().references(Batches, #id)();
  RealColumn get quantity => real()();
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
