import 'dart:convert';

import 'package:android_id/android_id.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'kv_store.dart';

const kLicenseSecret = String.fromEnvironment('LICENSE_SECRET', defaultValue: 'nasaq-dev-secret');
const kGoogleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

/// حدود نقل الترخيص بين الأجهزة تلقائياً.
const int kMaxTransfers = 3;
const Duration kTransferWindow = Duration(days: 30);

// ─────────────────────────────────────────────────────────────
// منطق القرار (نقي وقابل للاختبار) — تطابقه قواعد firebase/firestore.rules
// ─────────────────────────────────────────────────────────────

enum ActivationKind { create, sameDevice, transfer, tooManyTransfers }

class ActivationDecision {
  final ActivationKind kind;
  final int transferCount;
  final bool resetWindow;
  const ActivationDecision(this.kind, {this.transferCount = 0, this.resetWindow = false});
}

/// [existing] بيانات مستند الترخيص الحالي (أو null إن لم يوجد).
ActivationDecision decideActivation({
  required Map<String, dynamic>? existing,
  required String deviceId,
  required DateTime now,
}) {
  if (existing == null) {
    return const ActivationDecision(ActivationKind.create, transferCount: 0, resetWindow: true);
  }
  if (existing['deviceId'] == deviceId) {
    return ActivationDecision(ActivationKind.sameDevice,
        transferCount: (existing['transferCount'] as int?) ?? 0);
  }
  final windowStart = existing['windowStart'] as DateTime?;
  final count = (existing['transferCount'] as int?) ?? 0;
  final windowExpired = windowStart == null || now.difference(windowStart) >= kTransferWindow;
  if (windowExpired) {
    return const ActivationDecision(ActivationKind.transfer, transferCount: 1, resetWindow: true);
  }
  if (count >= kMaxTransfers) {
    return ActivationDecision(ActivationKind.tooManyTransfers, transferCount: count);
  }
  return ActivationDecision(ActivationKind.transfer, transferCount: count + 1);
}

// ─────────────────────────────────────────────────────────────
// الرخصة المحلية الموقّعة
// ─────────────────────────────────────────────────────────────

class LocalLicense {
  final String email, deviceId;
  final DateTime activatedAt;
  const LocalLicense(this.email, this.deviceId, this.activatedAt);
}

class LicenseVault {
  final KvStore kv;
  LicenseVault(this.kv);

  static String sign(String email, String deviceId, int ts) => base64.encode(
      Hmac(sha256, utf8.encode(kLicenseSecret)).convert(utf8.encode('$email|$deviceId|$ts')).bytes);

  Future<void> save(LocalLicense l) async {
    final ts = l.activatedAt.millisecondsSinceEpoch;
    await kv.write('license', jsonEncode({
      'email': l.email,
      'deviceId': l.deviceId,
      'ts': ts,
      'sig': sign(l.email, l.deviceId, ts),
    }));
  }

  /// يعيد الرخصة إن كانت سليمة وتخص هذا الجهاز؛ وإلا null.
  Future<LocalLicense?> load(String currentDeviceId) async {
    final raw = await kv.read('license');
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final email = m['email'] as String, dev = m['deviceId'] as String;
      final ts = m['ts'] as int;
      if (m['sig'] != sign(email, dev, ts)) return null;
      if (dev != currentDeviceId) return null;
      return LocalLicense(email, dev, DateTime.fromMillisecondsSinceEpoch(ts));
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() => kv.delete('license');
}

// ─────────────────────────────────────────────────────────────
// التفعيل عبر Google + Firestore (مرة واحدة)
// ─────────────────────────────────────────────────────────────

class ActivationException implements Exception {
  final String message;
  ActivationException(this.message);
  @override
  String toString() => message;
}

class LicenseService {
  final LicenseVault vault;
  LicenseService(this.vault);

  Future<String> deviceId() async {
    final id = await const AndroidId().getId();
    if (id == null || id.isEmpty) throw ActivationException('تعذّر تحديد هوية الجهاز');
    return id;
  }

  /// الترخيص المحلي إن وُجد وكان صالحاً — بلا أي اتصال.
  Future<LocalLicense?> current() async => vault.load(await deviceId());

  static bool get firebaseReady => Firebase.apps.isNotEmpty;

  Future<void> _ensureGoogleInit() async {
    await GoogleSignIn.instance.initialize(
        serverClientId: kGoogleServerClientId.isEmpty ? null : kGoogleServerClientId);
  }

  /// يتحقق أن من يسجّل الآن هو نفس صاحب الترخيص (لاستعادة PIN المنسي). يحتاج اتصالاً.
  Future<bool> confirmOwner() async {
    final lic = await current();
    if (lic == null) return false;
    await _ensureGoogleInit();
    final account = await GoogleSignIn.instance.authenticate();
    return account.email.toLowerCase() == lic.email;
  }

  /// تسجيل الدخول بـ Google ثم التفعيل/نقل الترخيص إلى هذا الجهاز تلقائياً.
  Future<LocalLicense> activate() async {
    if (!firebaseReady) {
      throw ActivationException('لم يُضبط Firebase في هذا الإصدار (google-services.json مفقود)');
    }
    final dev = await deviceId();
    await _ensureGoogleInit();
    final account = await GoogleSignIn.instance.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null) throw ActivationException('تعذّر الحصول على رمز الدخول من Google');
    final cred = await FirebaseAuth.instance
        .signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
    final email = cred.user?.email?.toLowerCase();
    if (email == null) throw ActivationException('الحساب لا يحتوي بريداً إلكترونياً');

    final fs = FirebaseFirestore.instance;
    final ref = fs.collection('licenses').doc(email);
    try {
      await fs.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final data = snap.data();
        final existing = data == null
            ? null
            : {
                'deviceId': data['deviceId'],
                'transferCount': data['transferCount'],
                'windowStart': (data['windowStart'] as Timestamp?)?.toDate(),
              };
        final d = decideActivation(existing: existing, deviceId: dev, now: DateTime.now());
        switch (d.kind) {
          case ActivationKind.sameDevice:
            return;
          case ActivationKind.tooManyTransfers:
            throw ActivationException(
                'تم تجاوز الحد المسموح لنقل الترخيص بين الأجهزة. حاول لاحقاً أو تواصل مع المطوّر.');
          case ActivationKind.create:
            tx.set(ref, {
              'deviceId': dev,
              'activatedAt': FieldValue.serverTimestamp(),
              'windowStart': FieldValue.serverTimestamp(),
              'transferCount': 0,
            });
          case ActivationKind.transfer:
            tx.update(ref, {
              'deviceId': dev,
              'activatedAt': FieldValue.serverTimestamp(),
              if (d.resetWindow) 'windowStart': FieldValue.serverTimestamp(),
              'transferCount': d.transferCount,
            });
        }
      });
    } on FirebaseException catch (e) {
      if (e.code == 'permission-denied') {
        throw ActivationException('هذا البريد ($email) غير مصرّح له باستخدام التطبيق');
      }
      if (e.code == 'unavailable') {
        throw ActivationException('لا يوجد اتصال بالإنترنت. التفعيل الأول يحتاج اتصالاً.');
      }
      throw ActivationException('فشل التفعيل: ${e.message}');
    }
    final lic = LocalLicense(email, dev, DateTime.now());
    await vault.save(lic);
    return lic;
  }
}
