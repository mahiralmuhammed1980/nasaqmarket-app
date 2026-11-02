import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/importers.dart';
import '../data/table_reader.dart';
import '../services/backup.dart';
import 'common.dart';

class DataScreen extends StatefulWidget {
  const DataScreen({super.key});
  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  bool _busy = false;

  Future<T?> _guard<T>(Future<T> Function() f) async {
    setState(() => _busy = true);
    try {
      return await f();
    } on BackupException catch (e) {
      if (mounted) snack(context, e.message, error: true);
    } catch (e) {
      if (mounted) snack(context, 'حدث خطأ: $e', error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return null;
  }

  Future<ParsedTable?> _pickTable() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['csv', 'xlsx']);
    if (f == null) return null;
    try {
      return readTable(await f.readAsBytes(), f.name);
    } catch (e) {
      if (mounted) snack(context, 'تعذّرت قراءة الملف: $e', error: true);
      return null;
    }
  }

  Future<void> _importCatalog() async {
    final t = await _pickTable();
    if (t == null || !mounted) return;
    final imp = CatalogImporter(context.app.db);
    final pv = await imp.preview(t);
    if (!mounted) return;
    final go = await _previewDialog('معاينة استيراد كتالوج الأدوية', pv,
        note: 'هذا الاستيراد يحدّث الكتالوج فقط (الأدوية والشركات). لا يمسّ المخزون ولا الفواتير ولا المشتريات ولا الأرصدة.');
    if (go != true || !mounted) return;
    await context.app.safetyBackup('before_catalog_import');
    final res = await _guard(() => imp.apply(t));
    if (res != null && mounted) snack(context, 'تمت الإضافة: ${res.created} • التحديث: ${res.updated}');
  }

  Future<void> _importInventory() async {
    final t = await _pickTable();
    if (t == null || !mounted) return;
    final imp = InventoryImporter(context.app.db);
    final pv = await imp.preview(t);
    if (!mounted) return;
    final go = await _previewDialog('معاينة استيراد الجرد', pv,
        note: 'تُنشأ الأصناف الجديدة وتُضاف الدفعات. الأصناف الموجودة تبقى أسعارها كما هي.');
    if (go != true || !mounted) return;
    await context.app.safetyBackup('before_inventory_import');
    final res = await _guard(() => imp.apply(t));
    if (res != null && mounted) snack(context, 'أصناف جديدة: ${res.products} • دفعات: ${res.batches} • متخطّاة: ${res.skipped}');
  }

  Future<bool?> _previewDialog(String title, ImportPreview pv, {required String note}) => showDialog<bool>(
        context: context,
        builder: (ctx) {
          final bad = pv.rows.where((r) => r.action == ImportAction.invalid).toList();
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 480,
              child: pv.fatalError != null
                  ? Text(pv.fatalError!, style: TextStyle(color: Theme.of(ctx).colorScheme.error))
                  : SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                        Text(note, style: Theme.of(ctx).textTheme.bodySmall),
                        const SizedBox(height: 12),
                        Text('جديد: ${pv.count(ImportAction.create)}'),
                        Text('سيتم تحديثه: ${pv.count(ImportAction.update)}'),
                        Text('بلا تغيير: ${pv.count(ImportAction.unchanged)}'),
                        Text('أخطاء (ستُتخطى): ${bad.length}', style: TextStyle(color: bad.isEmpty ? null : Colors.red)),
                        for (final b in bad.take(8)) Text('  سطر ${b.line}: ${b.error}', style: const TextStyle(fontSize: 12)),
                        if (bad.length > 8) Text('  ... و${bad.length - 8} أخطاء أخرى', style: const TextStyle(fontSize: 12)),
                      ]),
                    ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
              FilledButton(onPressed: pv.canApply ? () => Navigator.pop(ctx, true) : null, child: const Text('اعتماد الاستيراد')),
            ],
          );
        },
      );

  Future<void> _shareText(String content, String filename) async {
    final dir = await context.app.tmpDir();
    final f = File('${dir.path}/$filename')..writeAsBytesSync(utf8.encode(content));
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  Future<void> _exportInventory() async {
    final db = context.app.db;
    final prods = await db.select(db.products).get();
    final batches = await db.select(db.batches).get();
    String esc(String s) => '"${s.replaceAll('"', '""')}"';
    final b = StringBuffer('﻿الاسم التجاري,الاسم العلمي,الباركود,رقم الدفعة,الكمية,تاريخ الانتهاء,التكلفة,السعر,الحد الأدنى,موقع التخزين\n');
    for (final p in prods.where((p) => !p.archived)) {
      final bs = batches.where((x) => x.productId == p.id && x.quantity > 0).toList();
      if (bs.isEmpty) {
        b.writeln([esc(p.name), esc(p.scientificName), esc(p.barcode ?? ''), '', 0, '', p.costPrice, p.salePrice, p.minStock, ''].join(','));
      }
      for (final x in bs) {
        b.writeln([esc(p.name), esc(p.scientificName), esc(p.barcode ?? ''), esc(x.batchNo), x.quantity, dateFmt(x.expiry).replaceAll('—', ''), x.cost, p.salePrice, p.minStock, esc(x.location)].join(','));
      }
    }
    await _shareText(b.toString(), 'inventory_${dateFmt(DateTime.now())}.csv');
  }

  Future<void> _localBackup() async {
    final bytes = await _guard(() => context.app.snapshot());
    if (bytes == null || !mounted) return;
    final dir = await context.app.tmpDir();
    final f = File('${dir.path}/nasaq_${dateFmt(DateTime.now())}.${BackupFile.ext}')..writeAsBytesSync(bytes);
    await SharePlus.instance.share(ShareParams(files: [XFile(f.path)]));
  }

  Future<void> _localRestore() async {
    final f = await FilePicker.pickFile();
    if (f == null || !mounted) return;
    final bytes = await f.readAsBytes();
    if (!mounted) return;
    if (!await confirm(context, 'استعادة نسخة احتياطية؟', body: 'ستُستبدل كل بيانات التطبيق الحالية ببيانات النسخة. تُحفظ نسخة أمان تلقائياً قبل ذلك.', danger: true, ok: 'استعادة')) return;
    await _guard(() => context.app.restore(bytes));
    if (mounted) snack(context, 'تمت الاستعادة');
  }

  @override
  Widget build(BuildContext context) {
    Widget tile(IconData i, String t, String s, VoidCallback f) => ListTile(leading: Icon(i), title: Text(t), subtitle: Text(s), onTap: _busy ? null : f);
    return Stack(children: [
      Centered(
        child: ListView(padding: const EdgeInsets.all(12), children: [
          _group(context, 'الاستيراد', [
            tile(Icons.menu_book, 'استيراد كتالوج الأدوية والشركات', 'ملف Excel أو CSV لتحديث قائمة الأدوية دون التأثير على المخزون والمالية', _importCatalog),
            tile(Icons.inventory, 'استيراد الجرد (أصناف ودفعات)', 'ملف يحتوي الأصناف والكميات وأرقام الدفعات وتواريخ الانتهاء', _importInventory),
            tile(Icons.description_outlined, 'قالب كتالوج الأدوية', 'ملف CSV بالأعمدة العربية المعتمدة', () => _shareText(catalogTemplateCsv(), 'catalog_template.csv')),
            tile(Icons.description_outlined, 'قالب الجرد', 'ملف CSV بالأعمدة العربية المعتمدة', () => _shareText(inventoryTemplateCsv(), 'inventory_template.csv')),
          ]),
          _group(context, 'التصدير', [
            tile(Icons.file_download_outlined, 'تصدير الجرد (CSV)', 'يمكن فتحه في Excel', _exportInventory),
          ]),
          _group(context, 'النسخ الاحتياطي', [
            tile(Icons.cloud_upload_outlined, 'Google Drive', 'نسخ واستعادة تلقائية في حسابك', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DriveBackupPage()))),
            tile(Icons.save_alt, 'تنزيل نسخة احتياطية (ملف)', 'يحتفظ بها المستخدم أو يشاركها', _localBackup),
            tile(Icons.restore, 'استعادة من ملف', 'استبدال البيانات بنسخة محفوظة', _localRestore),
          ]),
          const _ColumnsGuide(),
        ]),
      ),
      if (_busy) const Positioned.fill(child: ColoredBox(color: Colors.black26, child: Center(child: CircularProgressIndicator()))),
    ]);
  }

  Widget _group(BuildContext c, String t, List<Widget> children) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: Text(t, style: Theme.of(c).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
          ...children,
        ]),
      );
}

class _ColumnsGuide extends StatelessWidget {
  const _ColumnsGuide();
  @override
  Widget build(BuildContext context) => Card(
        child: ExpansionTile(
          leading: const Icon(Icons.help_outline),
          title: const Text('دليل الأعمدة المقبولة'),
          children: const [
            Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'كتالوج الأدوية: الباركود، الاسم التجاري (مطلوب)، الاسم العلمي، التصنيف، الوحدة، الشركة، بلد الشركة، السعر المرجعي.\n\n'
                'الجرد: الاسم التجاري (مطلوب)، الباركود، رقم الدفعة، الكمية، تاريخ الانتهاء، التكلفة، السعر، الحد الأدنى، موقع التخزين.\n\n'
                'التواريخ: 2027-12-31 أو 31/12/2027 أو 12/2027 (يُعتبر آخر الشهر).\n'
                'الأرقام: تُقبل الأرقام العربية والفواصل (3,000).\n'
                'الملفات: CSV بترميز UTF-8 (فاصلة أو فاصلة منقوطة) أو Excel بصيغة xlsx.',
              ),
            ),
          ],
        ),
      );
}

// ═════════════ Google Drive ═════════════

/// بعد التفعيل على جهاز جديد: يعرض آخر النسخ على Drive للاستعادة.
Future<void> offerRestoreFromDrive(BuildContext context) async {
  final app = context.app;
  List<RemoteBackup> list;
  try {
    list = await app.drive.list(interactive: true);
  } catch (_) {
    return; // لا نزعج المستخدم إن لم يتوفر Drive
  }
  if (list.isEmpty || !context.mounted) return;
  final latest = list.first;
  final go = await confirm(context, 'تم العثور على نسخة احتياطية',
      body: 'آخر نسخة بتاريخ ${dateTimeFmt(latest.created.toLocal())}. هل تريد استعادتها على هذا الجهاز؟', ok: 'استعادة');
  if (!go || !context.mounted) return;
  try {
    await app.restore(await app.drive.download(latest.id));
    if (context.mounted) snack(context, 'تمت استعادة البيانات');
  } catch (e) {
    if (context.mounted) snack(context, 'تعذّرت الاستعادة: $e', error: true);
  }
}

class DriveBackupPage extends StatefulWidget {
  const DriveBackupPage({super.key});
  @override
  State<DriveBackupPage> createState() => _DriveBackupPageState();
}

class _DriveBackupPageState extends State<DriveBackupPage> {
  bool _busy = false;
  bool _auto = false;
  DateTime? _last;
  List<RemoteBackup>? _remote;
  String? _err;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final app = context.appRead;
    final a = await app.driveBackupEnabled();
    final l = await app.lastDriveBackup();
    if (mounted) setState(() {
      _auto = a;
      _last = l;
    });
  }

  Future<void> _run(Future<void> Function() f) async {
    setState(() {
      _busy = true;
      _err = null;
    });
    try {
      await f();
    } catch (e) {
      _err = e is BackupException ? e.message : 'تعذّرت العملية: $e';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.app;
    return Scaffold(
      appBar: AppBar(title: const Text('النسخ الاحتياطي على Google Drive')),
      body: Centered(
        maxWidth: 640,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('تُحفظ النسخ في مجلد مخفي خاص بالتطبيق داخل حسابك على Google Drive، ولا يصل التطبيق إلى أي ملفات أخرى. يُحتفظ بآخر 10 نسخ.'),
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('نسخ احتياطي تلقائي يومي'),
            subtitle: const Text('عند فتح التطبيق إن مضى أكثر من 24 ساعة'),
            value: _auto,
            onChanged: _busy
                ? null
                : (v) => _run(() async {
                      if (v) await app.drive.connect();
                      await app.setDriveBackup(v);
                      _auto = v;
                    }),
          ),
          ListTile(
            leading: const Icon(Icons.history),
            title: const Text('آخر نسخة ناجحة'),
            subtitle: Text(_last == null ? 'لا توجد' : dateTimeFmt(_last!.toLocal())),
          ),
          FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      final r = await app.backupToDrive(interactive: true);
                      _last = DateTime.now();
                      if (mounted) snack(context, 'تم رفع النسخة ${r.name}');
                    }),
            icon: const Icon(Icons.cloud_upload),
            label: const Text('انسخ الآن'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _run(() async => _remote = await app.drive.list(interactive: true)),
            icon: const Icon(Icons.cloud_download),
            label: const Text('عرض النسخ المتوفرة للاستعادة'),
          ),
          if (_busy) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()),
          if (_err != null) Padding(padding: const EdgeInsets.all(8), child: Text(_err!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
          if (_remote != null) ...[
            const Divider(height: 32),
            if (_remote!.isEmpty) const Text('لا توجد نسخ على Drive'),
            for (final b in _remote!)
              ListTile(
                leading: const Icon(Icons.backup),
                title: Text(dateTimeFmt(b.created.toLocal())),
                subtitle: Text('${(b.size / 1024).round()} كيلوبايت'),
                trailing: TextButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          if (!await confirm(context, 'استعادة هذه النسخة؟', body: 'ستُستبدل كل البيانات الحالية. تُحفظ نسخة أمان تلقائياً قبل ذلك.', danger: true, ok: 'استعادة')) return;
                          await _run(() async {
                            final Uint8List bytes = await app.drive.download(b.id);
                            await app.restore(bytes);
                            if (mounted) snack(context, 'تمت الاستعادة');
                          });
                        },
                  child: const Text('استعادة'),
                ),
              ),
          ],
        ]),
      ),
    );
  }
}
