import 'package:drift/drift.dart';

import '../core/format.dart';
import 'database.dart';

class InsufficientStock implements Exception {
  final String productName;
  final double requested, available;
  InsufficientStock(this.productName, this.requested, this.available);
  @override
  String toString() =>
      'الكمية غير كافية للصنف "$productName": المطلوب ${qtyFmt(requested)} والمتاح ${qtyFmt(available)}';
}

/// يُظهر المقاس واللون مع اسم الصنف (لأصناف الألبسة والأحذية).
extension ProductLabel on Product {
  String get displayName =>
      [name, if (size.isNotEmpty) size, if (color.isNotEmpty) color].join(' - ');
}

class InvoiceLine {
  final int productId;
  final double quantity;
  final int unitPrice;
  const InvoiceLine(this.productId, this.quantity, this.unitPrice);
}

class CashSummary {
  final int totalIn, totalOut; // للفترة المطلوبة (قيم موجبة)
  final Map<String, int> balanceByMethod; // رصيد تراكمي لكل وسيلة
  const CashSummary(this.totalIn, this.totalOut, this.balanceByMethod);
  int get net => totalIn - totalOut;
  int get totalBalance => balanceByMethod.values.fold(0, (a, b) => a + b);
  int get cashBalance => balanceByMethod['cash'] ?? 0;
}

class StatementRow {
  final DateTime date;
  final String description;
  final int debit; // مشتريات (تزيد المستحق للمورد)
  final int credit; // دفعات (تُنقص المستحق)
  final int balance;
  final String kind; // opening | order | payment
  const StatementRow(this.date, this.description, this.debit, this.credit, this.balance, this.kind);
}

class SupplierStatement {
  final Supplier supplier;
  final int openingBalance;
  final List<StatementRow> rows;
  const SupplierStatement(this.supplier, this.openingBalance, this.rows);
  int get balance => rows.isEmpty ? openingBalance : rows.last.balance;
  int get totalPurchases => rows.where((r) => r.kind == 'order').fold(0, (a, r) => a + r.debit);
  int get totalPaid => rows.where((r) => r.kind == 'payment').fold(0, (a, r) => a + r.credit);
}

const kExpenseCategories = ['إيجار', 'رواتب', 'كهرباء وماء', 'مواصلات', 'صيانة', 'مستلزمات', 'أخرى'];

String normalizeMethod(String m) => (m == 'card' || m == 'transfer') ? m : 'cash';

class ProductStock {
  final Product product;
  final double stock;
  final DateTime? nearestExpiry;
  const ProductStock(this.product, this.stock, this.nearestExpiry);
  bool get low => stock <= product.minStock;
}

class BatchInfo {
  final StockBatch batch;
  final Product product;
  const BatchInfo(this.batch, this.product);
  int get daysToExpiry => batch.expiry == null
      ? 99999
      : batch.expiry!.difference(DateTime.now()).inDays;
}

/// طبقة العمليات على قاعدة البيانات: المخزون، المبيعات، المشتريات.
class Repository {
  final AppDatabase db;
  Repository(this.db);

  // ───────── الموردون ─────────
  Stream<List<Supplier>> watchSuppliers() =>
      (db.select(db.suppliers)..orderBy([(t) => OrderingTerm.asc(t.name)])).watch();
  Future<int> saveSupplier(SuppliersCompanion s) =>
      db.into(db.suppliers).insertOnConflictUpdate(s);
  Future<void> deleteSupplier(int id) async {
    final used = await (db.select(db.purchaseOrders)..where((t) => t.supplierId.equals(id))).get();
    if (used.isNotEmpty) {
      throw StateError('لا يمكن حذف مورد لديه أوامر شراء');
    }
    await (db.update(db.products)..where((t) => t.defaultSupplierId.equals(id)))
        .write(const ProductsCompanion(defaultSupplierId: Value(null)));
    await (db.update(db.batches)..where((t) => t.supplierId.equals(id)))
        .write(const BatchesCompanion(supplierId: Value(null)));
    await (db.delete(db.suppliers)..where((t) => t.id.equals(id))).go();
  }

  // ───────── الأصناف ─────────
  Future<int> saveProduct(ProductsCompanion p) =>
      db.into(db.products).insertOnConflictUpdate(p);

  Future<Product?> productById(int id) =>
      (db.select(db.products)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<Product?> productByBarcode(String code) async {
    for (final v in _variants(code)) {
      final r = await (db.select(db.products)
            ..where((t) => t.barcode.equals(v) & t.archived.equals(false)))
          .get();
      if (r.isNotEmpty) return r.first;
    }
    return null;
  }

  List<String> _variants(String code) {
    final c = code.trim();
    final out = <String>{c};
    if (c.length == 14 && c.startsWith('0')) out.add(c.substring(1));
    if (c.length == 13) out.add('0$c');
    return out.toList();
  }

  /// يؤرشف الصنف إن كانت له حركات، وإلا يحذفه.
  Future<void> deleteProduct(int id) async {
    final hasItems = await (db.select(db.invoiceItems)..where((t) => t.productId.equals(id))).get();
    final hasPo = await (db.select(db.purchaseOrderItems)..where((t) => t.productId.equals(id))).get();
    await db.transaction(() async {
      if (hasItems.isNotEmpty || hasPo.isNotEmpty) {
        await (db.update(db.products)..where((t) => t.id.equals(id)))
            .write(const ProductsCompanion(archived: Value(true)));
        await (db.update(db.batches)..where((t) => t.productId.equals(id)))
            .write(const BatchesCompanion(quantity: Value(0)));
      } else {
        await (db.delete(db.batches)..where((t) => t.productId.equals(id))).go();
        await (db.delete(db.products)..where((t) => t.id.equals(id))).go();
      }
    });
  }

  /// التصنيفات المستخدمة فعلاً (للتصفية والاقتراح).
  Future<List<String>> categories() async {
    final rows = await (db.select(db.products)..where((t) => t.archived.equals(false))).get();
    return (rows.map((p) => p.category.trim()).where((c) => c.isNotEmpty).toSet().toList()..sort());
  }

  /// الأصناف مع مجموع الكمية وأقرب انتهاء، مع بحث اختياري (اسم/مقاس/لون/تصنيف/باركود).
  Stream<List<ProductStock>> watchProducts({String query = '', String? category}) {
    final q = db.select(db.products)
      ..where((t) => t.archived.equals(false))
      ..orderBy([(t) => OrderingTerm.asc(t.name), (t) => OrderingTerm.asc(t.size), (t) => OrderingTerm.asc(t.color)]);
    if (category != null) q.where((t) => t.category.equals(category));
    final qs = query.trim();
    if (qs.isNotEmpty) {
      q.where((t) =>
          t.name.like('%$qs%') |
          t.size.like('%$qs%') |
          t.color.like('%$qs%') |
          t.category.like('%$qs%') |
          t.barcode.like('%$qs%'));
    }
    return q.watch().asyncMap((products) async {
      final batches = await db.select(db.batches).get();
      final qty = <int, double>{};
      final exp = <int, DateTime>{};
      for (final b in batches) {
        if (b.quantity <= 0) continue;
        qty[b.productId] = q3((qty[b.productId] ?? 0) + b.quantity);
        if (b.expiry != null) {
          final cur = exp[b.productId];
          if (cur == null || b.expiry!.isBefore(cur)) exp[b.productId] = b.expiry!;
        }
      }
      return [for (final p in products) ProductStock(p, qty[p.id] ?? 0, exp[p.id])];
    });
  }

  Future<double> stockOf(int productId) async {
    final r = await (db.select(db.batches)..where((t) => t.productId.equals(productId))).get();
    return q3(r.fold<double>(0, (a, b) => a + b.quantity));
  }

  /// ينشئ أصنافاً متعددة لنفس الموديل بتوليفات المقاسات × الألوان، وكمية ابتدائية اختيارية لكل منها.
  /// يعيد معرّفات الأصناف المنشأة.
  Future<List<int>> createVariants({
    required ProductsCompanion base,
    required List<String> sizes,
    required List<String> colors,
    double initialQty = 0,
  }) =>
      db.transaction(() async {
        final ids = <int>[];
        final ss = sizes.isEmpty ? [''] : sizes;
        final cs = colors.isEmpty ? [''] : colors;
        for (final s in ss) {
          for (final c in cs) {
            final id = await db.into(db.products).insert(base.copyWith(size: Value(s), color: Value(c)));
            ids.add(id);
            if (initialQty > 0) {
              await db.into(db.batches).insert(BatchesCompanion.insert(
                    productId: id,
                    quantity: Value(q3(initialQty)),
                    cost: base.costPrice,
                    notes: const Value('رصيد افتتاحي'),
                  ));
            }
          }
        }
        return ids;
      });

  // ───────── الدفعات ─────────
  Stream<List<StockBatch>> watchBatches(int productId) => (db.select(db.batches)
        ..where((t) => t.productId.equals(productId))
        ..orderBy([(t) => OrderingTerm.asc(t.expiry)]))
      .watch();
  Future<int> saveBatch(BatchesCompanion b) =>
      db.into(db.batches).insertOnConflictUpdate(b);
  Future<void> deleteBatch(int id) async {
    final used = await (db.select(db.invoiceItemBatches)..where((t) => t.batchId.equals(id))).get();
    if (used.isNotEmpty) {
      // دفعة سبق البيع منها: نصفّر الكمية بدل الحذف لحفظ سجل الفواتير.
      await (db.update(db.batches)..where((t) => t.id.equals(id)))
          .write(const BatchesCompanion(quantity: Value(0)));
    } else {
      await (db.delete(db.batches)..where((t) => t.id.equals(id))).go();
    }
  }

  // ───────── لوحة التحكم ─────────
  Future<List<BatchInfo>> expiringBatches({int withinDays = 90}) async {
    final limit = DateTime.now().add(Duration(days: withinDays));
    final rows = await (db.select(db.batches).join([
      innerJoin(db.products, db.products.id.equalsExp(db.batches.productId)),
    ])
          ..where(db.batches.quantity.isBiggerThanValue(0) &
              db.batches.expiry.isNotNull() &
              db.batches.expiry.isSmallerOrEqualValue(limit) &
              db.products.archived.equals(false) &
              db.products.trackExpiry.equals(true))
          ..orderBy([OrderingTerm.asc(db.batches.expiry)]))
        .get();
    return [for (final r in rows) BatchInfo(r.readTable(db.batches), r.readTable(db.products))];
  }

  Future<List<ProductStock>> lowStock() async {
    final all = await watchProducts().first;
    return all.where((p) => p.low && p.product.minStock > 0).toList();
  }

  Future<int> inventoryValueAtCost() async {
    final bs = await db.select(db.batches).get();
    return bs.fold<int>(0, (a, b) => a + (b.quantity * b.cost).round());
  }

  // ───────── المبيعات ─────────

  /// إنشاء فاتورة: داخل معاملة واحدة، يخصم من الدفعات الأقرب انتهاءً (FEFO)
  /// متجاهلاً المنتهية. أي فشل يُلغي كل شيء. اسم الزبون اختياري.
  Future<Invoice> createInvoice({
    String customerName = '',
    String customerPhone = '',
    required List<InvoiceLine> lines,
    int discount = 0,
    String paymentMethod = 'cash',
    int? paidAmount,
    String notes = '',
    DateTime? now,
  }) {
    if (lines.isEmpty) throw ArgumentError('الفاتورة بلا أصناف');
    final when = now ?? DateTime.now();
    return db.transaction(() async {
      var subtotal = 0;
      final number = await db.nextInvoiceNumber();
      final invId = await db.into(db.invoices).insert(InvoicesCompanion.insert(
            number: number,
            createdAt: when,
            customerName: Value(customerName.trim()),
            customerPhone: Value(customerPhone.trim()),
            subtotal: 0,
            total: 0,
            paymentMethod: Value(paymentMethod),
            notes: Value(notes),
          ));
      for (final l in lines) {
        final qty = q3(l.quantity);
        if (qty <= 0) throw ArgumentError('كمية غير صالحة');
        final product = await productById(l.productId);
        if (product == null) throw StateError('صنف غير موجود');
        final batches = await (db.select(db.batches)
              ..where((t) => t.productId.equals(l.productId) & t.quantity.isBiggerThanValue(0))
              ..orderBy([
                // الأقرب انتهاءً أولاً، والبلا تاريخ في الآخر
                (t) => OrderingTerm(expression: t.expiry.isNull()),
                (t) => OrderingTerm.asc(t.expiry),
                (t) => OrderingTerm.asc(t.id),
              ]))
            .get();
        final today = DateTime(when.year, when.month, when.day);
        final usable = batches.where((b) => b.expiry == null || !b.expiry!.isBefore(today)).toList();
        final available = q3(usable.fold<double>(0, (a, b) => a + b.quantity));
        if (available < qty) {
          throw InsufficientStock(product.displayName, qty, available);
        }
        final lineTotal = (qty * l.unitPrice).round();
        final itemId = await db.into(db.invoiceItems).insert(InvoiceItemsCompanion.insert(
              invoiceId: invId,
              productId: Value(l.productId),
              productName: product.displayName,
              quantity: qty,
              unitPrice: l.unitPrice,
              unitCost: Value(product.costPrice),
              lineTotal: lineTotal,
            ));
        var remaining = qty;
        for (final b in usable) {
          if (remaining <= 0) break;
          final take = remaining < b.quantity ? remaining : b.quantity;
          await (db.update(db.batches)..where((t) => t.id.equals(b.id)))
              .write(BatchesCompanion(quantity: Value(q3(b.quantity - take))));
          await db.into(db.invoiceItemBatches).insert(InvoiceItemBatchesCompanion.insert(
              invoiceItemId: itemId, batchId: b.id, quantity: take));
          remaining = q3(remaining - take);
        }
        subtotal += lineTotal;
      }
      if (discount < 0 || discount > subtotal) {
        throw ArgumentError('خصم غير صالح');
      }
      final total = subtotal - discount;
      final paid = paidAmount ?? total;
      final status = paid >= total ? 'paid' : (paid <= 0 ? 'unpaid' : 'partial');
      await (db.update(db.invoices)..where((t) => t.id.equals(invId))).write(
          InvoicesCompanion(
              subtotal: Value(subtotal),
              discount: Value(discount),
              total: Value(total),
              paidAmount: Value(paid > total ? total : paid),
              paymentStatus: Value(status)));
      final received = paid > total ? total : paid;
      if (received > 0) {
        await _cash(
            kind: 'sale',
            amount: received,
            method: normalizeMethod(paymentMethod),
            category: 'مبيعات',
            note: 'فاتورة $number',
            at: when,
            refType: 'invoice',
            refId: invId);
      }
      return (db.select(db.invoices)..where((t) => t.id.equals(invId))).getSingle();
    });
  }

  /// حذف فاتورة مع إرجاع الكميات إلى الدفعات التي خُصمت منها.
  Future<void> voidInvoice(int invoiceId) => db.transaction(() async {
        final inv = await (db.select(db.invoices)..where((t) => t.id.equals(invoiceId))).getSingleOrNull();
        // عكس الحركات المالية المرتبطة (تبقى الحركة الأصلية في السجل).
        final entries = await (db.select(db.cashEntries)
              ..where((t) => t.refType.equals('invoice') & t.refId.equals(invoiceId)))
            .get();
        final net = <String, int>{};
        for (final e in entries) {
          net[e.method] = (net[e.method] ?? 0) + e.amount;
        }
        for (final m in net.entries) {
          if (m.value != 0) {
            await _cash(
                kind: 'void',
                amount: -m.value,
                method: m.key,
                category: 'إلغاء فاتورة',
                note: 'حذف فاتورة ${inv?.number ?? invoiceId}',
                refType: 'invoice',
                refId: invoiceId);
          }
        }
        final items = await (db.select(db.invoiceItems)..where((t) => t.invoiceId.equals(invoiceId))).get();
        for (final it in items) {
          final allocs = await (db.select(db.invoiceItemBatches)..where((t) => t.invoiceItemId.equals(it.id))).get();
          for (final a in allocs) {
            final b = await (db.select(db.batches)..where((t) => t.id.equals(a.batchId))).getSingleOrNull();
            if (b != null) {
              await (db.update(db.batches)..where((t) => t.id.equals(b.id)))
                  .write(BatchesCompanion(quantity: Value(q3(b.quantity + a.quantity))));
            }
          }
          await (db.delete(db.invoiceItemBatches)..where((t) => t.invoiceItemId.equals(it.id))).go();
        }
        await (db.delete(db.invoiceItems)..where((t) => t.invoiceId.equals(invoiceId))).go();
        await (db.delete(db.invoices)..where((t) => t.id.equals(invoiceId))).go();
      });

  /// تسجيل سداد المتبقي من فاتورة؛ يدخل الصندوق بوسيلة الدفع المختارة.
  Future<void> settleInvoice(int invoiceId, {String method = 'cash'}) => db.transaction(() async {
        final inv = await (db.select(db.invoices)..where((t) => t.id.equals(invoiceId))).getSingle();
        final remaining = inv.total - inv.paidAmount;
        await (db.update(db.invoices)..where((t) => t.id.equals(invoiceId))).write(
            InvoicesCompanion(paidAmount: Value(inv.total), paymentStatus: const Value('paid')));
        if (remaining > 0) {
          await _cash(
              kind: 'sale_settlement',
              amount: remaining,
              method: normalizeMethod(method),
              category: 'سداد فاتورة',
              note: 'سداد فاتورة ${inv.number}',
              refType: 'invoice',
              refId: invoiceId);
        }
      });

  Stream<List<Invoice>> watchInvoices({String query = ''}) {
    final q = db.select(db.invoices)..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.id)]);
    final qs = query.trim();
    if (qs.isNotEmpty) {
      q.where((t) => t.customerName.like('%$qs%') | t.number.like('%$qs%') | t.customerPhone.like('%$qs%'));
    }
    return q.watch();
  }

  Future<List<InvoiceItem>> invoiceItems(int invoiceId) =>
      (db.select(db.invoiceItems)..where((t) => t.invoiceId.equals(invoiceId))).get();

  Future<int> salesTotalSince(DateTime from) async {
    final r = await (db.select(db.invoices)..where((t) => t.createdAt.isBiggerOrEqualValue(from))).get();
    return r.fold<int>(0, (a, b) => a + b.total);
  }

  /// ربح الفترة = إجمالي الفواتير (بعد الخصم) − تكلفة الأصناف المباعة وقت البيع.
  Future<int> profitSince(DateTime from) async {
    final invs = await (db.select(db.invoices)..where((t) => t.createdAt.isBiggerOrEqualValue(from))).get();
    if (invs.isEmpty) return 0;
    final ids = invs.map((i) => i.id).toSet();
    final items = await db.select(db.invoiceItems).get();
    var cost = 0;
    for (final it in items) {
      if (ids.contains(it.invoiceId)) cost += (it.quantity * it.unitCost).round();
    }
    return invs.fold<int>(0, (a, b) => a + b.total) - cost;
  }

  /// ديون الزبائن: مجموع المتبقي على الفواتير غير المسددة.
  Future<int> customerReceivables() async {
    final r = await (db.select(db.invoices)..where((t) => t.paymentStatus.equals('paid').not())).get();
    return r.fold<int>(0, (a, b) => a + (b.total - b.paidAmount));
  }

  // ───────── المشتريات ─────────
  Stream<List<PurchaseOrder>> watchOrders() => (db.select(db.purchaseOrders)
        ..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.id)]))
      .watch();

  Future<List<PurchaseOrderItem>> orderItems(int orderId) =>
      (db.select(db.purchaseOrderItems)..where((t) => t.orderId.equals(orderId))).get();

  Future<int> createOrder({
    required int supplierId,
    required List<PurchaseOrderItemsCompanion Function(int orderId)> items,
    String notes = '',
    String status = 'draft',
  }) =>
      db.transaction(() async {
        final id = await db.into(db.purchaseOrders).insert(PurchaseOrdersCompanion.insert(
            supplierId: supplierId,
            createdAt: DateTime.now(),
            status: Value(status),
            notes: Value(notes)));
        for (final f in items) {
          await db.into(db.purchaseOrderItems).insert(f(id));
        }
        return id;
      });

  Future<void> setOrderStatus(int orderId, String status) async {
    final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(orderId))).getSingle();
    if (o.status == 'received') throw StateError('الأمر مستلم سابقاً');
    await (db.update(db.purchaseOrders)..where((t) => t.id.equals(orderId)))
        .write(PurchaseOrdersCompanion(status: Value(status)));
  }

  Future<void> deleteOrder(int orderId) async {
    final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(orderId))).getSingle();
    if (o.status == 'received') throw StateError('لا يمكن حذف أمر مستلم');
    await db.transaction(() async {
      await (db.delete(db.purchaseOrderItems)..where((t) => t.orderId.equals(orderId))).go();
      await (db.delete(db.purchaseOrders)..where((t) => t.id.equals(orderId))).go();
    });
  }

  /// استلام الأمر: كل بند يتحول إلى دفعة في المخزون، مرة واحدة فقط.
  Future<void> receiveOrder(int orderId, {int paid = 0, String method = 'cash'}) => db.transaction(() async {
        final o = await (db.select(db.purchaseOrders)..where((t) => t.id.equals(orderId))).getSingle();
        if (o.status == 'received') throw StateError('الأمر مستلم سابقاً');
        if (o.status == 'cancelled') throw StateError('الأمر ملغى');
        final items = await orderItems(orderId);
        final total = orderTotal(items);
        if (paid < 0 || paid > total) throw StateError('المبلغ المدفوع يجب أن يكون بين 0 وإجمالي الأمر');
        for (final it in items) {
          await db.into(db.batches).insert(BatchesCompanion.insert(
                productId: it.productId,
                batchNo: Value(it.batchNo),
                quantity: Value(q3(it.quantity)),
                expiry: Value(it.expiry),
                cost: Value(it.unitCost),
                supplierId: Value(o.supplierId),
                notes: Value('أمر شراء #$orderId'),
              ));
          // تحديث آخر تكلفة للصنف
          await (db.update(db.products)..where((t) => t.id.equals(it.productId)))
              .write(ProductsCompanion(costPrice: Value(it.unitCost)));
        }
        await (db.update(db.purchaseOrders)..where((t) => t.id.equals(orderId))).write(
            PurchaseOrdersCompanion(status: const Value('received'), receivedAt: Value(DateTime.now())));
        if (paid > 0) {
          await _cash(
              kind: 'supplier_payment',
              amount: -paid,
              method: normalizeMethod(method),
              category: 'دفع لمورد',
              note: 'استلام أمر شراء #$orderId',
              refType: 'order',
              refId: orderId,
              supplierId: o.supplierId);
        }
      });

  int orderTotal(List<PurchaseOrderItem> items) =>
      items.fold<int>(0, (a, i) => a + (i.quantity * i.unitCost).round());

  // ═════════════ الصندوق ═════════════

  Future<int> _cash({
    required String kind,
    required int amount,
    String method = 'cash',
    String category = '',
    String note = '',
    DateTime? at,
    String? refType,
    int? refId,
    int? supplierId,
  }) =>
      db.into(db.cashEntries).insert(CashEntriesCompanion.insert(
            createdAt: at ?? DateTime.now(),
            kind: kind,
            method: Value(method),
            amount: amount,
            category: Value(category),
            note: Value(note),
            refType: Value(refType),
            refId: Value(refId),
            supplierId: Value(supplierId),
          ));

  /// حركة يدوية. [amount] موجب دائماً؛ الإشارة تُحدَّد من [kind]:
  /// opening/owner_in دخل، expense/owner_out خرج.
  Future<int> addManualEntry({
    required String kind,
    required int amount,
    String method = 'cash',
    String category = '',
    String note = '',
    DateTime? at,
  }) async {
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    final sign = switch (kind) {
      'opening' || 'owner_in' => 1,
      'expense' || 'owner_out' => -1,
      _ => throw ArgumentError('نوع حركة غير مدعوم: $kind'),
    };
    return _cash(kind: kind, amount: sign * amount, method: normalizeMethod(method), category: category, note: note, at: at);
  }

  /// دفعة مستقلة لمورد (تُخصم من الصندوق وتنقص رصيده المستحق).
  Future<int> addSupplierPayment({
    required int supplierId,
    required int amount,
    String method = 'cash',
    String note = '',
    DateTime? at,
  }) async {
    if (amount <= 0) throw ArgumentError('المبلغ يجب أن يكون أكبر من صفر');
    return _cash(
        kind: 'supplier_payment',
        amount: -amount,
        method: normalizeMethod(method),
        category: 'دفع لمورد',
        note: note,
        at: at,
        supplierId: supplierId);
  }

  Stream<List<CashEntry>> watchCash({String filter = 'all', DateTime? from, DateTime? to}) {
    final q = db.select(db.cashEntries)
      ..orderBy([(t) => OrderingTerm.desc(t.createdAt), (t) => OrderingTerm.desc(t.id)]);
    if (filter == 'in') q.where((t) => t.amount.isBiggerThanValue(0));
    if (filter == 'out') q.where((t) => t.amount.isSmallerThanValue(0));
    if (from != null) q.where((t) => t.createdAt.isBiggerOrEqualValue(from));
    if (to != null) q.where((t) => t.createdAt.isSmallerThanValue(to));
    return q.watch();
  }

  Stream<CashSummary> watchCashSummary({DateTime? from, DateTime? to}) =>
      db.select(db.cashEntries).watch().map((all) {
        final bal = <String, int>{};
        var tin = 0, tout = 0;
        for (final e in all) {
          bal[e.method] = (bal[e.method] ?? 0) + e.amount;
          final inPeriod = (from == null || !e.createdAt.isBefore(from)) && (to == null || e.createdAt.isBefore(to));
          if (inPeriod && e.kind != 'opening') {
            if (e.amount > 0) {
              tin += e.amount;
            } else {
              tout += -e.amount;
            }
          }
        }
        return CashSummary(tin, tout, bal);
      });

  Future<CashSummary> cashSummary({DateTime? from, DateTime? to}) => watchCashSummary(from: from, to: to).first;

  /// إغلاق اليوم: يطابق الرصيد النقدي الفعلي مع رصيد النظام ويسجّل الفرق كتسوية.
  Future<CashClosing> closeDay(int counted, {String note = ''}) => db.transaction(() async {
        if (counted < 0) throw ArgumentError('المبلغ لا يمكن أن يكون سالباً');
        final system = (await cashSummary()).cashBalance;
        final diff = counted - system;
        final id = await db.into(db.cashClosings).insert(CashClosingsCompanion.insert(
              createdAt: DateTime.now(),
              systemBalance: system,
              countedAmount: counted,
              difference: diff,
              note: Value(note),
            ));
        if (diff != 0) {
          await _cash(kind: 'adjustment', amount: diff, category: 'تسوية إغلاق', note: note.isEmpty ? 'فرق إغلاق اليوم' : note);
        }
        return (db.select(db.cashClosings)..where((t) => t.id.equals(id))).getSingle();
      });

  Stream<List<CashClosing>> watchClosings() =>
      (db.select(db.cashClosings)..orderBy([(t) => OrderingTerm.desc(t.createdAt)])).watch();

  // ═════════════ كشف حساب المورد ═════════════

  /// المشتريات (أوامر مستلمة) تزيد المستحق للمورد، والدفعات تنقصه.
  /// الرصيد الموجب = علينا للمورد.
  Future<SupplierStatement> supplierStatement(int supplierId) async {
    final sup = await (db.select(db.suppliers)..where((t) => t.id.equals(supplierId))).getSingle();
    final orders = await (db.select(db.purchaseOrders)
          ..where((t) => t.supplierId.equals(supplierId) & t.status.equals('received')))
        .get();
    final events = <({DateTime date, int order, String desc, int debit, int credit, String kind})>[];
    for (final o in orders) {
      final total = orderTotal(await orderItems(o.id));
      events.add((date: o.receivedAt ?? o.createdAt, order: 0, desc: 'أمر شراء #${o.id}', debit: total, credit: 0, kind: 'order'));
    }
    final pays = await (db.select(db.cashEntries)
          ..where((t) => t.kind.equals('supplier_payment') & t.supplierId.equals(supplierId)))
        .get();
    for (final e in pays) {
      events.add((
        date: e.createdAt,
        order: 1,
        desc: e.note.isEmpty ? 'دفعة' : e.note,
        debit: 0,
        credit: -e.amount,
        kind: 'payment'
      ));
    }
    events.sort((a, b) {
      final c = a.date.compareTo(b.date);
      return c != 0 ? c : a.order.compareTo(b.order);
    });
    var bal = sup.openingBalance;
    final rows = <StatementRow>[];
    if (sup.openingBalance != 0) {
      rows.add(StatementRow(DateTime.fromMillisecondsSinceEpoch(0), 'رصيد افتتاحي (ذمم سابقة)', sup.openingBalance > 0 ? sup.openingBalance : 0, sup.openingBalance < 0 ? -sup.openingBalance : 0, bal, 'opening'));
    }
    for (final e in events) {
      bal += e.debit - e.credit;
      rows.add(StatementRow(e.date, e.desc, e.debit, e.credit, bal, e.kind));
    }
    return SupplierStatement(sup, sup.openingBalance, rows);
  }

  /// أرصدة كل الموردين: معرّف المورد → المستحق له.
  Future<Map<int, int>> supplierBalances() async {
    final sups = await db.select(db.suppliers).get();
    final out = <int, int>{for (final s in sups) s.id: s.openingBalance};
    final orders = await (db.select(db.purchaseOrders)..where((t) => t.status.equals('received'))).get();
    final items = await db.select(db.purchaseOrderItems).get();
    final totals = <int, int>{};
    for (final i in items) {
      totals[i.orderId] = (totals[i.orderId] ?? 0) + (i.quantity * i.unitCost).round();
    }
    for (final o in orders) {
      out[o.supplierId] = (out[o.supplierId] ?? 0) + (totals[o.id] ?? 0);
    }
    final pays = await (db.select(db.cashEntries)..where((t) => t.kind.equals('supplier_payment'))).get();
    for (final e in pays) {
      if (e.supplierId != null) out[e.supplierId!] = (out[e.supplierId!] ?? 0) + e.amount; // amount سالب
    }
    return out;
  }
}
