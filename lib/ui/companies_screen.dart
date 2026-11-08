import 'package:flutter/material.dart';

import '../app_state.dart';
import '../data/repository.dart';
import 'common.dart';

/// قائمة الشركات المصنّعة التي تُنسب إليها الأدوية.
class CompaniesScreen extends StatelessWidget {
  const CompaniesScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('الشركات')),
        floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showCompanyDialog(context), icon: const Icon(Icons.add), label: const Text('شركة جديدة')),
        body: StreamBuilder<List<CompanyInfo>>(
          stream: context.repo.watchCompanies(),
          builder: (ctx, snap) {
            if (!snap.hasData) return const Center(child: CircularProgressIndicator());
            final list = snap.data!;
            if (list.isEmpty) return const EmptyState(Icons.factory_outlined, 'لا توجد شركات بعد.\nأضف شركة، أو استورد كتالوج الأدوية الذي يتضمن الشركات.');
            return Centered(
              child: ListView.separated(
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: list.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) => ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.factory)),
                  title: Text(list[i].company.name),
                  subtitle: Text([if (list[i].company.country.isNotEmpty) list[i].company.country, '${list[i].productCount} صنف'].join(' • ')),
                  onTap: () => showCompanyDialog(context, info: list[i]),
                ),
              ),
            );
          },
        ),
      );
}

/// إضافة/تعديل شركة. يعيد معرّف الشركة المحفوظة (أو null).
Future<int?> showCompanyDialog(BuildContext context, {CompanyInfo? info}) async {
  final name = TextEditingController(text: info?.company.name);
  final country = TextEditingController(text: info?.company.country);
  final form = GlobalKey<FormState>();
  final repo = context.repoRead;
  return showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(info == null ? 'شركة جديدة' : 'تعديل الشركة'),
      content: Form(
        key: form,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          formField('اسم الشركة *', name, required: true),
          formField('البلد', country),
        ]),
      ),
      actions: [
        if (info != null)
          TextButton(
              onPressed: () async {
                final extra = info.productCount > 0 ? 'سيُفصل عنها ${info.productCount} صنف (لا يُحذف أي صنف).' : null;
                if (!await confirm(ctx, 'حذف الشركة؟', body: extra, danger: true, ok: 'حذف')) return;
                await repo.deleteCompany(info.company.id);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('حذف')),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
        FilledButton(
            onPressed: () async {
              if (!form.currentState!.validate()) return;
              try {
                final id = await repo.saveCompany(id: info?.company.id, name: name.text, country: country.text);
                if (ctx.mounted) Navigator.pop(ctx, id);
              } on StateError catch (e) {
                if (ctx.mounted) snack(ctx, e.message, error: true);
              }
            },
            child: const Text('حفظ')),
      ],
    ),
  );
}
