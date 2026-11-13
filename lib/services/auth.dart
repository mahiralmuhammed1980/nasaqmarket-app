import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'backup.dart';
import 'kv_store.dart';

class AuthException implements Exception {
  final String message;
  AuthException(this.message);
  @override
  String toString() => message;
}

/// حساب Google الذي سجّل به المستخدم. التسجيل إلزامي لضمان وجود Drive للنسخ الاحتياطي.
class Account {
  final String email;
  final DateTime signedInAt;
  const Account(this.email, this.signedInAt);
}

class AuthService {
  final KvStore kv;
  final DriveBackupService drive;
  AuthService(this.kv, this.drive);

  static const _kEmail = 'account_email';
  static const _kAt = 'account_at';

  /// الحساب المحفوظ محلياً — بلا أي اتصال (يعمل التطبيق دون إنترنت بعد أول تسجيل).
  Future<Account?> current() async {
    final e = await kv.read(_kEmail);
    if (e == null || e.isEmpty) return null;
    final ts = int.tryParse(await kv.read(_kAt) ?? '');
    return Account(e, ts == null ? DateTime.now() : DateTime.fromMillisecondsSinceEpoch(ts));
  }

  /// تسجيل الدخول بحساب Google مع طلب إذن Drive والتحقق من توفره.
  Future<Account> signIn() async {
    try {
      await ensureGoogleInit();
      final acct = await GoogleSignIn.instance.authenticate(scopeHint: [DriveBackupService.scope]);
      final email = acct.email.toLowerCase();
      if (email.isEmpty) throw AuthException('الحساب لا يحتوي بريداً إلكترونياً');
      await drive.verifyAccess();
      // دخول Firebase بنفس حساب Google (لازم لقواعد الترخيص). بدون google-services.json يُتخطى.
      if (Firebase.apps.isNotEmpty) {
        final idToken = acct.authentication.idToken;
        if (idToken == null) throw AuthException('تعذّر الحصول على رمز الدخول من Google');
        await FirebaseAuth.instance.signInWithCredential(GoogleAuthProvider.credential(idToken: idToken));
      }
      final now = DateTime.now();
      await kv.write(_kEmail, email);
      await kv.write(_kAt, '${now.millisecondsSinceEpoch}');
      return Account(email, now);
    } on BackupException catch (e) {
      throw AuthException(e.message);
    } on FirebaseAuthException catch (e) {
      throw AuthException('تعذّر تسجيل الدخول: ${e.message ?? e.code}');
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled) {
        throw AuthException('أُلغي تسجيل الدخول. التسجيل بحساب Google مطلوب لاستخدام التطبيق.');
      }
      throw AuthException('تعذّر تسجيل الدخول: ${e.description ?? e.code.name}');
    }
  }

  /// يتحقق أن من يسجّل الآن هو نفس صاحب الحساب (لاستعادة PIN المنسي). يحتاج اتصالاً.
  Future<bool> confirmOwner() async {
    final acc = await current();
    if (acc == null) return false;
    await ensureGoogleInit();
    final a = await GoogleSignIn.instance.authenticate();
    return a.email.toLowerCase() == acc.email;
  }

  Future<void> signOut() async {
    try {
      await ensureGoogleInit();
      await GoogleSignIn.instance.signOut();
      if (Firebase.apps.isNotEmpty) await FirebaseAuth.instance.signOut();
    } catch (_) {}
    await kv.delete(_kEmail);
    await kv.delete(_kAt);
  }
}
