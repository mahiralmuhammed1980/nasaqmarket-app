import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:ota_update/ota_update.dart';
import 'package:package_info_plus/package_info_plus.dart';

/// عنوان ملف الإصدار. يمكن تغييره عند البناء: --dart-define=UPDATE_URL=...
/// الافتراضي: أحدث إصدار على GitHub Releases (يتطلب مستودعاً عاماً أو استضافة أخرى للملف).
const kUpdateUrl = String.fromEnvironment('UPDATE_URL',
    defaultValue:
        'https://github.com/mahiralmuhammed1980/nasaqmarket-app/releases/latest/download/version.json');

class UpdateInfo {
  final int versionCode;
  final String versionName;
  final String apkUrl;
  final String? sha256;
  final String notes;
  final bool mandatory;
  const UpdateInfo(this.versionCode, this.versionName, this.apkUrl, this.sha256, this.notes,
      this.mandatory);

  factory UpdateInfo.fromJson(Map<String, dynamic> j) {
    final code = j['versionCode'];
    final url = j['apkUrl'];
    if (code is! int || url is! String || !url.startsWith('https://')) {
      throw const FormatException('ملف التحديث غير صالح');
    }
    return UpdateInfo(
      code,
      (j['versionName'] ?? '$code').toString(),
      url,
      j['sha256'] as String?,
      (j['notes'] ?? '').toString(),
      j['mandatory'] == true,
    );
  }

  bool isNewerThan(int currentCode) => versionCode > currentCode;
}

class UpdateService {
  final http.Client _client;
  UpdateService([http.Client? client]) : _client = client ?? http.Client();

  Future<int> currentVersionCode() async =>
      int.tryParse((await PackageInfo.fromPlatform()).buildNumber) ?? 0;

  /// يعيد معلومات التحديث إن وُجد إصدار أحدث، وإلا null. أي فشل شبكة → null بصمت
  /// (إلا إن كان [throwOnError]).
  Future<UpdateInfo?> check({bool throwOnError = false, int? currentCode}) async {
    try {
      final r = await _client.get(Uri.parse(kUpdateUrl)).timeout(const Duration(seconds: 10));
      if (r.statusCode != 200) throw http.ClientException('HTTP ${r.statusCode}');
      final info = UpdateInfo.fromJson(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>);
      final cur = currentCode ?? await currentVersionCode();
      return info.isNewerThan(cur) ? info : null;
    } catch (_) {
      if (throwOnError) rethrow;
      return null;
    }
  }

  /// تنزيل الـ APK وتشغيل المثبّت. البيانات تبقى لأن الحزمة والتوقيع نفسهما.
  Stream<OtaEvent> install(UpdateInfo info) => OtaUpdate().execute(
        info.apkUrl,
        destinationFilename: 'nasaq_market_${info.versionCode}.apk',
        sha256checksum: info.sha256,
      );
}
