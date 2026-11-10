import 'dart:io';
import 'dart:typed_data';

import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart' as sql;

import '../data/database.dart';

/// صيغة ملف النسخة: gzip لملف SQLite كامل.
/// الامتداد المعتمد: .nqbak
class BackupFile {
  static const ext = 'nqbak';

  /// لقطة متسقة من قاعدة البيانات الحالية (VACUUM INTO) مضغوطة.
  static Future<Uint8List> snapshot(AppDatabase db, Directory tmpDir) async {
    final tmp = File('${tmpDir.path}/snap_${DateTime.now().microsecondsSinceEpoch}.sqlite');
    if (await tmp.exists()) await tmp.delete();
    await db.customStatement("VACUUM INTO '${tmp.path.replaceAll("'", "''")}'");
    try {
      final bytes = await tmp.readAsBytes();
      return Uint8List.fromList(gzip.encode(bytes));
    } finally {
      await tmp.delete();
    }
  }

  /// يفك الضغط ويتحقق أن الملف قاعدة بيانات «نسق فارما» سليمة وغير أحدث من التطبيق.
  /// يعيد بايتات SQLite الخام أو يرمي [BackupException].
  static Uint8List validate(Uint8List packed, Directory tmpDir) {
    Uint8List raw;
    try {
      raw = Uint8List.fromList(gzip.decode(packed));
    } catch (_) {
      throw BackupException('الملف ليس نسخة احتياطية صالحة');
    }
    if (raw.length < 100 || String.fromCharCodes(raw.sublist(0, 15)) != 'SQLite format 3') {
      throw BackupException('الملف ليس نسخة احتياطية صالحة');
    }
    final f = File('${tmpDir.path}/verify_${DateTime.now().microsecondsSinceEpoch}.sqlite')
      ..writeAsBytesSync(raw);
    try {
      final d = sql.sqlite3.open(f.path, mode: sql.OpenMode.readOnly);
      try {
        final integrity = d.select('PRAGMA integrity_check').first.values.first;
        if (integrity != 'ok') throw BackupException('النسخة تالفة');
        final version = d.select('PRAGMA user_version').first.values.first as int;
        if (version > kSchemaVersion) {
          throw BackupException('النسخة من إصدار أحدث من التطبيق. حدّث التطبيق أولاً.');
        }
        final tables = d
            .select("SELECT name FROM sqlite_master WHERE type='table'")
            .map((r) => r['name'] as String)
            .toSet();
        for (final t in ['products', 'batches', 'invoices', 'invoice_items', 'suppliers']) {
          if (!tables.contains(t)) throw BackupException('النسخة لا تخص هذا التطبيق');
        }
      } finally {
        d.close();
      }
    } on sql.SqliteException {
      throw BackupException('النسخة تالفة');
    } finally {
      f.deleteSync();
    }
    return raw;
  }
}

class BackupException implements Exception {
  final String message;
  BackupException(this.message);
  @override
  String toString() => message;
}

class RemoteBackup {
  final String id, name;
  final DateTime created;
  final int size;
  const RemoteBackup(this.id, this.name, this.created, this.size);
}

class _AuthClient extends http.BaseClient {
  final Map<String, String> headers;
  final http.Client _inner = http.Client();
  _AuthClient(this.headers);
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request..headers.addAll(headers));
}

const kGoogleServerClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');

Future<void>? _googleInit;

/// تهيئة Google Sign-In مرة واحدة فقط لكل تشغيل.
Future<void> ensureGoogleInit() => _googleInit ??= GoogleSignIn.instance
    .initialize(serverClientId: kGoogleServerClientId.isEmpty ? null : kGoogleServerClientId);

/// النسخ الاحتياطي على Google Drive داخل مجلد التطبيق المخفي (appDataFolder).
/// النطاق drive.appdata فقط: التطبيق لا يرى أي ملف آخر في درايف الزبون.
class DriveBackupService {
  static const scope = 'https://www.googleapis.com/auth/drive.appdata';
  static const keep = 10;

  Future<drive.DriveApi> _api({bool interactive = false}) async {
    await ensureGoogleInit();
    final acct = await GoogleSignIn.instance.attemptLightweightAuthentication() ??
        (interactive ? await GoogleSignIn.instance.authenticate(scopeHint: [scope]) : null);
    if (acct == null) throw BackupException('سجّل الدخول بحساب Google أولاً');
    final headers = await acct.authorizationClient
        .authorizationHeaders([scope], promptIfNecessary: interactive);
    if (headers == null) throw BackupException('لم تُمنح صلاحية Google Drive');
    return drive.DriveApi(_AuthClient(headers));
  }

  /// يتحقق من إمكانية الوصول (يطلب الإذن عند الحاجة).
  Future<void> connect() async => _api(interactive: true);

  /// يتأكد فعلياً أن Drive متاح للحساب: يطلب الإذن ثم يقرأ مجلد التطبيق المخفي.
  Future<void> verifyAccess() async {
    final api = await _api(interactive: true);
    try {
      await api.files.list(spaces: 'appDataFolder', pageSize: 1, $fields: 'files(id)');
    } catch (_) {
      throw BackupException('تعذّر الوصول إلى Google Drive لهذا الحساب. تأكد من الاتصال بالإنترنت ومن منح الإذن.');
    }
  }

  Future<RemoteBackup> upload(Uint8List packed, {bool interactive = false}) async {
    final api = await _api(interactive: interactive);
    final now = DateTime.now();
    final name =
        'nasaq_${now.toIso8601String().replaceAll(':', '-').split('.').first}.${BackupFile.ext}';
    final media = drive.Media(Stream.value(packed), packed.length);
    final f = await api.files.create(
      drive.File()
        ..name = name
        ..parents = ['appDataFolder']
        ..appProperties = {'schema': '$kSchemaVersion'},
      uploadMedia: media,
      $fields: 'id,name,createdTime,size',
    );
    await _prune(api);
    return RemoteBackup(f.id!, f.name!, f.createdTime ?? now, int.tryParse(f.size ?? '') ?? packed.length);
  }

  Future<List<RemoteBackup>> list({bool interactive = false}) async {
    final api = await _api(interactive: interactive);
    final res = await api.files.list(
      spaces: 'appDataFolder',
      orderBy: 'createdTime desc',
      pageSize: 50,
      $fields: 'files(id,name,createdTime,size)',
    );
    return [
      for (final f in res.files ?? <drive.File>[])
        RemoteBackup(f.id!, f.name ?? '', f.createdTime ?? DateTime.fromMillisecondsSinceEpoch(0),
            int.tryParse(f.size ?? '') ?? 0)
    ];
  }

  Future<Uint8List> download(String id) async {
    final api = await _api();
    final media = await api.files.get(id,
        downloadOptions: drive.DownloadOptions.fullMedia) as drive.Media;
    final b = BytesBuilder();
    await for (final chunk in media.stream) {
      b.add(chunk);
    }
    return b.takeBytes();
  }

  Future<void> _prune(drive.DriveApi api) async {
    final res = await api.files.list(
        spaces: 'appDataFolder',
        orderBy: 'createdTime desc',
        pageSize: 100,
        $fields: 'files(id)');
    final files = res.files ?? [];
    for (final f in files.skip(keep)) {
      await api.files.delete(f.id!);
    }
  }
}
