import 'package:flutter_test/flutter_test.dart';
import 'package:nasaq_market/services/updater.dart';

void main() {
  group('التحديثات', () {
    test('تحليل version.json ومقارنة الإصدار', () {
      final u = UpdateInfo.fromJson({
        'versionCode': 5,
        'versionName': '1.0.4',
        'apkUrl': 'https://example.com/a.apk',
        'notes': 'تحسينات'
      });
      expect(u.isNewerThan(4), isTrue);
      expect(u.isNewerThan(5), isFalse);
      expect(u.mandatory, isFalse);
    });
    test('الملف غير الصالح أو غير الآمن يُرفض', () {
      expect(() => UpdateInfo.fromJson({'versionCode': 5, 'apkUrl': 'http://x/a.apk'}), throwsFormatException);
      expect(() => UpdateInfo.fromJson({'apkUrl': 'https://x/a.apk'}), throwsFormatException);
    });
  });
}
