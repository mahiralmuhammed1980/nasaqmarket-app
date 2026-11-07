import 'package:flutter/material.dart';

import '../app_state.dart';
import '../core/format.dart';
import '../data/database.dart';
import 'common.dart';
import 'share_util.dart';

/// سجل مبيعات الأدوية المقيّدة بوصفة (للمراجعة والتفتيش).
class RestrictedScreen extends StatefulWidget {
  const RestrictedScreen({super.key});
  @override
  State<RestrictedScreen> createState() => _RestrictedScreenState();
}

class _RestrictedScreenState extends State<RestrictedScreen> {
  String _q = '';

  Future<void> _export() async {
    final all = await context.repoRead.watchRestricted(query: _q).first;
    final b = StringBuffer('﻿التاريخ,رقم الفاتورة,الدواء,الكمية,رقم الوصفة,الطبيب,المريض,الرقم الوطني,ملغاة\n');
    for (final r in all) {
      b.writeln([csvCell(dateTimeFmt(r.createdAt)), csvCell(r.invoiceNumber), csvCell(r.productName), r.quantity, csvCell(r.prescriptionNo), csvCell(r.doctorName), csvCell(r.patientName), csvCell(r.patientNationalId), r.voided ? 'نعم' : 'لا'].join(','));
    }
    if (mounted) await shareText(context, b.toString(), 'restricted_register_${dateFmt(DateTime.now())}.csv');
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('سجل الأدوية المقيّدة'), actions: [
          IconButton(tooltip: 'تصدير CSV', icon: const Icon(Icons.file_download_outlined), onPressed: _export),
        ]),
        body: Column(children: [
          SearchBox(onChanged: (v) => setState(() => _q = v), hint: 'ابحث بالمريض أو الرقم الوطني أو الوصفة أو الطبيب أو الدواء'),
          Expanded(
            child: StreamBuilder<List<RestrictedRecord>>(
              stream: context.repo.watchRestricted(query: _q),
              builder: (ctx, snap) {
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final list = snap.data!;
                if (list.isEmpty) return const EmptyState(Icons.lock_outline, 'لا توجد سجلات.\nتُسجَّل هنا تلقائياً مبيعات الأصناف المعلَّمة «مقيّد بوصفة».');
                return Centered(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(8),
                    itemCount: list.length,
                    itemBuilder: (_, i) {
                      final r = list[i];
                      final style = r.voided ? const TextStyle(decoration: TextDecoration.lineThrough) : null;
                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Row(children: [
                              Expanded(child: Text('${r.productName} × ${r.quantity}', style: const TextStyle(fontWeight: FontWeight.bold).merge(style))),
                              if (r.voided) const Chip(label: Text('فاتورة ملغاة'), visualDensity: VisualDensity.compact),
                            ]),
                            const SizedBox(height: 4),
                            Text('المريض: ${r.patientName} • الرقم الوطني: ${r.patientNationalId}', style: style),
                            Text('الطبيب: ${r.doctorName} • رقم الوصفة: ${r.prescriptionNo}', style: style),
                            Text('${r.invoiceNumber} • ${dateTimeFmt(r.createdAt)}', style: Theme.of(context).textTheme.bodySmall),
                          ]),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      );
}
