import 'package:flutter/material.dart';

import '../data/database.dart';
import 'format.dart';

/// نوع النشاط: يحدد الميزات الافتراضية (متغيّرات، كميات عشرية، صلاحية) والوحدات المقترحة.
enum BusinessType {
  supermarket('سوبر ماركت / بقالية', Icons.local_grocery_store_outlined),
  clothes('ملابس', Icons.checkroom_outlined),
  shoes('أحذية', Icons.directions_walk_outlined),
  electronics('كهربائيات وإلكترونيات', Icons.electrical_services_outlined),
  general('محل عام / أخرى', Icons.storefront_outlined);

  final String label;
  final IconData icon;
  const BusinessType(this.label, this.icon);

  /// المقاس/اللون للألبسة والأحذية.
  bool get variants => this == clothes || this == shoes;

  /// البيع بالوزن والكميات العشرية للسوبر ماركت.
  bool get decimal => this == supermarket;

  /// تتبع الصلاحية افتراضياً للمواد الغذائية.
  bool get expiry => this == supermarket;

  List<String> get units => switch (this) {
        supermarket => ['قطعة', 'كغ', 'غ', 'لتر', 'علبة', 'كرتونة', 'حبة'],
        shoes => ['زوج', 'قطعة'],
        _ => ['قطعة', 'علبة', 'كرتونة', 'متر'],
      };

  String get defaultUnit => units.first;

  /// مقاسات جاهزة للاختيار السريع.
  List<String> get sizePresets => switch (this) {
        clothes => ['XS', 'S', 'M', 'L', 'XL', 'XXL', '3XL'],
        shoes => ['36', '37', '38', '39', '40', '41', '42', '43', '44', '45', '46'],
        _ => const [],
      };

  List<String> get colorPresets => switch (this) {
        clothes || shoes => ['أسود', 'أبيض', 'أزرق', 'أحمر', 'رمادي', 'بيج', 'بني', 'أخضر'],
        _ => const [],
      };

  List<String> get categoryHints => switch (this) {
        supermarket => ['مواد غذائية', 'مشروبات', 'ألبان وأجبان', 'خضار وفواكه', 'منظفات', 'حلويات ومعجنات', 'معلبات'],
        clothes => ['رجالي', 'نسائي', 'أطفال', 'ملابس داخلية', 'إكسسوارات'],
        shoes => ['رجالي', 'نسائي', 'أطفال', 'رياضي'],
        electronics => ['أجهزة منزلية', 'هواتف', 'إكسسوارات', 'إنارة', 'كابلات'],
        general => const [],
      };

  static BusinessType? parse(String? v) {
    for (final t in values) {
      if (t.name == v) return t;
    }
    return null;
  }
}

/// إعدادات المحل المحفوظة داخل قاعدة البيانات (فتدخل في النسخ الاحتياطي).
/// الميزات الثلاث تُضبط افتراضياً من النوع ويمكن تغييرها من الإعدادات.
class StoreConfig {
  final BusinessType type;
  final bool variants, decimal, expiry;
  final String currency;
  const StoreConfig({
    required this.type,
    required this.variants,
    required this.decimal,
    required this.expiry,
    this.currency = 'ل.س',
  });

  factory StoreConfig.forType(BusinessType t, {String currency = 'ل.س'}) => StoreConfig(
      type: t, variants: t.variants, decimal: t.decimal, expiry: t.expiry, currency: currency);

  StoreConfig copyWith({bool? variants, bool? decimal, bool? expiry, String? currency}) => StoreConfig(
      type: type,
      variants: variants ?? this.variants,
      decimal: decimal ?? this.decimal,
      expiry: expiry ?? this.expiry,
      currency: currency ?? this.currency);

  TextInputType get qtyKeyboard =>
      decimal ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.number;

  /// تحقق من إدخال كمية: موجبة، وصحيحة فقط إن كانت الكميات العشرية معطّلة.
  String? validateQty(String? v, {bool allowZero = false}) {
    final q = readQty(v);
    if (q == null) return decimal ? 'أدخل كمية صحيحة' : 'أدخل عدداً صحيحاً';
    if (q < 0 || (!allowZero && q == 0)) return 'الكمية غير صالحة';
    return null;
  }

  /// يقرأ كمية حسب الإعداد: بلا كسور إن كانت العشرية معطّلة (null عند الكسر).
  double? readQty(String? v) {
    final q = parseQty(v);
    if (q == null) return null;
    if (!decimal && q != q.roundToDouble()) return null;
    return q;
  }

  static const _kType = 'business_type';

  static Future<StoreConfig?> load(AppDatabase db) async {
    final t = BusinessType.parse(await db.getSetting(_kType));
    if (t == null) return null;
    bool flag(String? v, bool d) => v == null ? d : v == '1';
    return StoreConfig(
      type: t,
      variants: flag(await db.getSetting('feat_variants'), t.variants),
      decimal: flag(await db.getSetting('feat_decimal'), t.decimal),
      expiry: flag(await db.getSetting('feat_expiry'), t.expiry),
      currency: await db.getSetting('currency') ?? 'ل.س',
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setSetting(_kType, type.name);
    await db.setSetting('feat_variants', variants ? '1' : '0');
    await db.setSetting('feat_decimal', decimal ? '1' : '0');
    await db.setSetting('feat_expiry', expiry ? '1' : '0');
    await db.setSetting('currency', currency);
  }
}
