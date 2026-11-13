import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

/// تفضيلات التواصل الاختيارية للمستخدم (موافقة صريحة، غير مفعّلة افتراضياً).
class ContactPrefs {
  final String phone;
  final bool marketingEmail, marketingWhatsapp;
  const ContactPrefs({this.phone = '', this.marketingEmail = false, this.marketingWhatsapp = false});
}

/// يوحّد رقم الهاتف: أرقام فقط مع + اختيارية في البداية. null إن كان غير صالح (7 إلى 15 رقماً).
String? normalizePhone(String raw) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  final b = StringBuffer();
  for (final r in raw.runes) {
    final c = String.fromCharCode(r);
    final i = ar.indexOf(c);
    b.write(i >= 0 ? '$i' : c);
  }
  var s = b.toString().trim();
  final plus = s.startsWith('+') || s.startsWith('00');
  s = s.replaceAll(RegExp(r'[^0-9]'), '');
  if (s.startsWith('00') && plus) s = s.substring(2);
  if (s.isEmpty) return '';
  if (s.length < 7 || s.length > 15) return null;
  return plus ? '+$s' : s;
}

class ProfileService {
  static bool get _ready => Firebase.apps.isNotEmpty && FirebaseAuth.instance.currentUser != null;

  DocumentReference<Map<String, dynamic>> _ref(String uid) => FirebaseFirestore.instance.collection('users').doc(uid);

  Future<ContactPrefs?> load() async {
    if (!_ready) return null;
    final u = FirebaseAuth.instance.currentUser!;
    final d = (await _ref(u.uid).get()).data();
    if (d == null) return null;
    return ContactPrefs(
        phone: (d['phone'] as String?) ?? '',
        marketingEmail: d['marketingEmail'] == true,
        marketingWhatsapp: d['marketingWhatsapp'] == true);
  }

  /// يحفظ التفضيلات في users/{uid}. وقت الموافقة من الخادم.
  Future<void> save(ContactPrefs p) async {
    if (!_ready) throw StateError('سجّل الدخول أولاً');
    final u = FirebaseAuth.instance.currentUser!;
    await _ref(u.uid).set({
      'email': (u.email ?? '').toLowerCase(),
      'phone': p.phone,
      'marketingEmail': p.marketingEmail,
      'marketingWhatsapp': p.marketingWhatsapp,
      'consentAt': FieldValue.serverTimestamp(),
    });
  }
}
