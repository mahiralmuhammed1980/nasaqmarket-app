import 'dart:convert';
import 'dart:math';

import 'package:android_id/android_id.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';

import 'kv_store.dart';

const kLicenseSecret = String.fromEnvironment('LICENSE_SECRET', defaultValue: 'nasaq-dev-secret');

/// حدود نقل الترخيص بين الأجهزة تلقائياً (تطابقها firebase/firestore.rules).
const int kMaxTransfers = 3;
const Duration kTransferWindow = Duration(days: 30);

// ─────────────────────────────────────────────────────────────
// أنواع الأكواد
// ─────────────────────────────────────────────────────────────

/// ثلاثة أنواع: 6 أشهر، سنة، مدى الحياة. الأيام هنا تطابق دالة planDays في القواعد.
enum LicensePlan {
  months6('6m', '6 أشهر', 183),
  year1('12m', 'سنة', 365),
  lifetime('life', 'مدى الحياة', 0);

  final String id, label;
  final int days;
  const LicensePlan(this.id, this.label, this.days);

  static LicensePlan? parse(String? id) {
    for (final p in values) {
      if (p.id == id) return p;
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────
// الكود: توليد وتطبيع وبصمة
// ─────────────────────────────────────────────────────────────

/// أحرف بلا لبس (بلا 0 O 1 I). 16 حرفاً ≈ 80 بتاً: لا يمكن تخمينه.
const _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

/// يولّد كوداً بالشكل XXXX-XXXX-XXXX-XXXX.
String generateCode([Random? rng]) {
  final r = rng ?? Random.secure();
  final s = List.generate(16, (_) => _alphabet[r.nextInt(_alphabet.length)]).join();
  return [for (var i = 0; i < 16; i += 4) s.substring(i, i + 4)].join('-');
}

/// يوحّد ما يكتبه المستخدم: أحرف كبيرة بلا شرطات ولا مسافات.
String normalizeCode(String s) => s.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

bool isValidCodeFormat(String s) {
  final n = normalizeCode(s);
  return n.length == 16 && n.split('').every(_alphabet.contains);
}

/// بصمة الكود (SHA-256 سداسي): هي معرّف مستند الكود في Firestore، فلا يُخزَّن الكود نفسه.
String codeHash(String code) => sha256.convert(utf8.encode(normalizeCode(code))).toString();

// ─────────────────────────────────────────────────────────────
// الاستحقاق (مدة الاشتراك)
// ─────────────────────────────────────────────────────────────

class Entitlement {
  final bool lifetime;
  final DateTime? paidUntil;
  const Entitlement({this.lifetime = false, this.paidUntil});

  bool active(DateTime now) => lifetime || (paidUntil != null && now.isBefore(paidUntil!));

  /// من مستند الترخيص: الانتهاء = بداية الفترة + الأيام (يحسبها الخادم بوقته).
  factory Entitlement.fromDoc(Map<String, dynamic> d) {
    if (d['lifetime'] == true) return const Entitlement(lifetime: true);
    final start = (d['startedAt'] as Timestamp?)?.toDate();
    final days = (d['days'] as num?)?.toInt() ?? 0;
    return Entitlement(paidUntil: start?.add(Duration(days: days)));
  }
}

// ─────────────────────────────────────────────────────────────
// قرار نقل الترخيص بين الأجهزة (نقي وقابل للاختبار)
// ─────────────────────────────────────────────────────────────

enum TransferKind { sameDevice, transfer, tooManyTransfers }

class TransferDecision {
  final TransferKind kind;
  final int transferCount;
  final bool resetWindow;
  const TransferDecision(this.kind, {this.transferCount = 0, this.resetWindow = false});
}

TransferDecision decideTransfer({
  required Map<String, dynamic> existing,
  required String deviceId,
  required DateTime now,
}) {
  final count = (existing['transferCount'] as int?) ?? 0;
  if (existing['deviceId'] == deviceId) {
    return TransferDecision(TransferKind.sameDevice, transferCount: count);
  }
  final windowStart = existing['windowStart'] as DateTime?;
  final expired = windowStart == null || now.difference(windowStart) >= kTransferWindow;
  if (expired) {
    return const TransferDecision(TransferKind.transfer, transferCount: 1, resetWindow: true);
  }
  if (count >= kMaxTransfers) {
    return TransferDecision(TransferKind.tooManyTransfers, transferCount: count);
  }
  return TransferDecision(TransferKind.transfer, transferCount: count + 1);
}

// ─────────────────────────────────────────────────────────────
// الترخيص المحلي الموقّع (للعمل دون اتصال)
// ─────────────────────────────────────────────────────────────

class LocalLicense {
  final String uid, email, deviceId;
  final Entitlement entitlement;
  final DateTime syncedAt;
  const LocalLicense(this.uid, this.email, this.deviceId, this.entitlement, this.syncedAt);
}

class LicenseVault {
  final KvStore kv;
  LicenseVault(this.kv);
  static const _k = 'license_v2';

  static String sign(String uid, String dev, bool life, int? paid, int sync) => base64.encode(
      Hmac(sha256, utf8.encode(kLicenseSecret)).convert(utf8.encode('$uid|$dev|$life|${paid ?? ''}|$sync')).bytes);

  Future<void> save(LocalLicense l) async {
    final paid = l.entitlement.paidUntil?.millisecondsSinceEpoch;
    final sync = l.syncedAt.millisecondsSinceEpoch;
    await kv.write(
        _k,
        jsonEncode({
          'uid': l.uid,
          'email': l.email,
          'dev': l.deviceId,
          'life': l.entitlement.lifetime,
          'paid': paid,
          'sync': sync,
          'sig': sign(l.uid, l.deviceId, l.entitlement.lifetime, paid, sync),
        }));
  }

  /// يعيد الترخيص إن كان سليماً وتخص هذا الجهاز؛ وإلا null.
  Future<LocalLicense?> load(String deviceId) async {
    final raw = await kv.read(_k);
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final uid = m['uid'] as String, dev = m['dev'] as String, life = m['life'] as bool;
      final paid = m['paid'] as int?, sync = m['sync'] as int;
      if (m['sig'] != sign(uid, dev, life, paid, sync)) return null;
      if (dev != deviceId) return null;
      return LocalLicense(
          uid,
          m['email'] as String,
          dev,
          Entitlement(lifetime: life, paidUntil: paid == null ? null : DateTime.fromMillisecondsSinceEpoch(paid)),
          DateTime.fromMillisecondsSinceEpoch(sync));
    } catch (_) {
      return null;
    }
  }

  Future<void> clear() => kv.delete(_k);
}

// ─────────────────────────────────────────────────────────────
// الخدمة (Firestore)
// ─────────────────────────────────────────────────────────────

class LicenseException implements Exception {
  final String message;
  LicenseException(this.message);
  @override
  String toString() => message;
}

class LicenseService {
  final LicenseVault vault;
  LicenseService(this.vault);

  static bool get firebaseReady => Firebase.apps.isNotEmpty;

  Future<String> deviceId() async {
    final id = await const AndroidId().getId();
    if (id == null || id.isEmpty) throw LicenseException('تعذّر تحديد هوية الجهاز');
    return id;
  }

  /// الترخيص المحلي إن كان سليماً — بلا اتصال.
  Future<LocalLicense?> local() async {
    try {
      return await vault.load(await deviceId());
    } catch (_) {
      return null;
    }
  }

  User _user() {
    if (!firebaseReady) throw LicenseException('خدمة التفعيل غير مضبوطة في هذا الإصدار');
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) throw LicenseException('سجّل الدخول بحساب Google أولاً');
    return u;
  }

  LicenseException _map(FirebaseException e) {
    switch (e.code) {
      case 'unavailable':
      case 'deadline-exceeded':
        return LicenseException('لا يوجد اتصال بالإنترنت. التفعيل يحتاج اتصالاً.');
      case 'permission-denied':
        return LicenseException('رُفض الطلب. تأكد من ضبط تاريخ وساعة الهاتف ومن صحة الكود، ثم أعد المحاولة.');
      default:
        return LicenseException('فشل التفعيل: ${e.message ?? e.code}');
    }
  }

  DocumentReference<Map<String, dynamic>> _lic(String uid) =>
      FirebaseFirestore.instance.collection('licenses').doc(uid);

  /// يزامن الترخيص من الخادم: يعيد الاستحقاق أو null إن لم يوجد ترخيص.
  /// إن كان الترخيص على جهاز آخر يُنقل تلقائياً إلى هذا الجهاز ضمن الحد المسموح.
  Future<Entitlement?> sync() async {
    final u = _user();
    final dev = await deviceId();
    final email = (u.email ?? '').toLowerCase();
    try {
      final ref = _lic(u.uid);
      final snap = await ref.get();
      if (!snap.exists) {
        await vault.clear();
        return null;
      }
      var data = snap.data()!;
      if (data['deviceId'] != dev) {
        await FirebaseFirestore.instance.runTransaction((tx) async {
          final s = await tx.get(ref);
          final d = s.data()!;
          final dec = decideTransfer(existing: {
            'deviceId': d['deviceId'],
            'transferCount': d['transferCount'],
            'windowStart': (d['windowStart'] as Timestamp?)?.toDate(),
          }, deviceId: dev, now: DateTime.now());
          switch (dec.kind) {
            case TransferKind.sameDevice:
              return;
            case TransferKind.tooManyTransfers:
              throw LicenseException(
                  'تم تجاوز الحد المسموح لنقل الترخيص بين الأجهزة (3 مرات كل 30 يوماً). حاول لاحقاً أو تواصل مع المندوب.');
            case TransferKind.transfer:
              tx.update(ref, {
                'deviceId': dev,
                'activatedAt': FieldValue.serverTimestamp(),
                if (dec.resetWindow) 'windowStart': FieldValue.serverTimestamp(),
                'transferCount': dec.transferCount,
              });
          }
        });
        data = (await ref.get(const GetOptions(source: Source.server))).data()!;
      }
      final ent = Entitlement.fromDoc(data);
      await vault.save(LocalLicense(u.uid, email, dev, ent, DateTime.now()));
      return ent;
    } on FirebaseException catch (e) {
      throw _map(e);
    }
  }

  /// يستهلك كوداً (مرة واحدة) ويمدّد الترخيص. كل شيء في معاملة واحدة تحرسها قواعد Firestore.
  Future<Entitlement> redeem(String rawCode) async {
    if (!isValidCodeFormat(rawCode)) throw LicenseException('صيغة الكود غير صحيحة (16 حرفاً/رقماً)');
    final u = _user();
    final dev = await deviceId();
    final email = (u.email ?? '').toLowerCase();
    final hash = codeHash(rawCode);
    // تثبيت الجهاز أولاً (نقل الترخيص إن كان على جهاز آخر) قبل التمديد.
    await sync();
    final fs = FirebaseFirestore.instance;
    final codeRef = fs.collection('codes').doc(hash);
    final licRef = _lic(u.uid);
    try {
      await fs.runTransaction((tx) async {
        final cs = await tx.get(codeRef);
        if (!cs.exists) throw LicenseException('الكود غير صحيح');
        final c = cs.data()!;
        if (c['status'] != 'available') throw LicenseException('هذا الكود مستخدم سابقاً');
        final plan = LicensePlan.parse(c['plan'] as String?);
        if (plan == null) throw LicenseException('نوع الكود غير معروف');
        final ls = await tx.get(licRef);
        final redeemed = {
          'status': 'redeemed',
          'redeemedBy': u.uid,
          'redeemedAt': FieldValue.serverTimestamp(),
        };
        final isLife = plan == LicensePlan.lifetime;
        if (!ls.exists) {
          tx.set(licRef, {
            'email': email,
            'deviceId': dev,
            'activatedAt': FieldValue.serverTimestamp(),
            'windowStart': FieldValue.serverTimestamp(),
            'transferCount': 0,
            'startedAt': FieldValue.serverTimestamp(),
            'days': plan.days,
            'lifetime': isLife,
            'lastCode': hash,
          });
        } else {
          final l = ls.data()!;
          if (l['lifetime'] == true) {
            throw LicenseException('الترخيص مدى الحياة مفعّل مسبقاً، لا حاجة لكود آخر');
          }
          if (isLife) {
            tx.update(licRef, {'lifetime': true, 'lastCode': hash});
          } else {
            final start = (l['startedAt'] as Timestamp).toDate();
            final days = (l['days'] as num).toInt();
            final expired = !DateTime.now().isBefore(start.add(Duration(days: days)));
            tx.update(licRef, {
              if (expired) 'startedAt': FieldValue.serverTimestamp(),
              'days': expired ? plan.days : days + plan.days,
              'lastCode': hash,
            });
          }
        }
        tx.update(codeRef, redeemed);
      });
      final data = (await licRef.get(const GetOptions(source: Source.server))).data()!;
      final ent = Entitlement.fromDoc(data);
      await vault.save(LocalLicense(u.uid, email, dev, ent, DateTime.now()));
      return ent;
    } on FirebaseException catch (e) {
      throw _map(e);
    }
  }

  Future<void> clear() => vault.clear();
}
