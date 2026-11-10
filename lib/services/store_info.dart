import 'dart:convert';
import 'dart:typed_data';

import '../data/database.dart';

/// بيانات المحل (تظهر في الفواتير). الشعار يُخزَّن داخل قاعدة البيانات
/// فيدخل في النسخ الاحتياطي تلقائياً.
class StoreInfo {
  final String name, phone, address;
  final Uint8List? logo;
  const StoreInfo({this.name = '', this.phone = '', this.address = '', this.logo});

  static Future<StoreInfo> load(AppDatabase db) async {
    final logo = await db.getSetting('store_logo');
    return StoreInfo(
      name: await db.getSetting('store_name') ?? '',
      phone: await db.getSetting('store_phone') ?? '',
      address: await db.getSetting('store_address') ?? '',
      logo: logo == null || logo.isEmpty ? null : base64.decode(logo),
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setSetting('store_name', name);
    await db.setSetting('store_phone', phone);
    await db.setSetting('store_address', address);
    await db.setSetting('store_logo', logo == null ? '' : base64.encode(logo!));
  }
}
