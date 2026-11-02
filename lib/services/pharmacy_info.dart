import 'dart:convert';
import 'dart:typed_data';

import '../data/database.dart';

/// بيانات الصيدلية (تظهر في الفواتير). الشعار يُخزَّن داخل قاعدة البيانات
/// فيدخل في النسخ الاحتياطي تلقائياً.
class PharmacyInfo {
  final String name, phone, address;
  final Uint8List? logo;
  const PharmacyInfo({this.name = '', this.phone = '', this.address = '', this.logo});

  static Future<PharmacyInfo> load(AppDatabase db) async {
    final logo = await db.getSetting('pharmacy_logo');
    return PharmacyInfo(
      name: await db.getSetting('pharmacy_name') ?? '',
      phone: await db.getSetting('pharmacy_phone') ?? '',
      address: await db.getSetting('pharmacy_address') ?? '',
      logo: logo == null || logo.isEmpty ? null : base64.decode(logo),
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setSetting('pharmacy_name', name);
    await db.setSetting('pharmacy_phone', phone);
    await db.setSetting('pharmacy_address', address);
    await db.setSetting('pharmacy_logo', logo == null ? '' : base64.encode(logo!));
  }
}
