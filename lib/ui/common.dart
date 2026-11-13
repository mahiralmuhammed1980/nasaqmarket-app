import 'package:flutter/material.dart';

import '../app_state.dart';

const kBreakpoint = 720.0;
bool isWide(BuildContext c) => MediaQuery.sizeOf(c).width >= kBreakpoint;

void snack(BuildContext c, String msg, {bool error = false}) {
  final m = ScaffoldMessenger.of(c);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(msg),
    backgroundColor: error ? Theme.of(c).colorScheme.error : null,
  ));
}

/// يمنع الإضافة/التعديل بعد انتهاء الفترة المجانية ويعرض سبب المنع. true = مسموح.
bool canWrite(BuildContext c) {
  if (!c.appRead.readOnly) return true;
  snack(c, 'انتهت الفترة المجانية: التطبيق للقراءة والتصدير فقط. فعّل كوداً من مندوبك من «المزيد ← الإعدادات».', error: true);
  return false;
}

Future<bool> confirm(BuildContext c, String title, {String? body, String ok = 'تأكيد', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (_) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

/// يحد عرض المحتوى على الشاشات الكبيرة ليبقى مقروءاً.
class Centered extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const Centered({super.key, required this.child, this.maxWidth = 900});
  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.topCenter, child: ConstrainedBox(constraints: BoxConstraints(maxWidth: maxWidth), child: child));
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyState(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 56, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
          ]),
        ),
      );
}

class SearchBox extends StatelessWidget {
  final ValueChanged<String> onChanged;
  final String hint;
  final Widget? trailing;
  const SearchBox({super.key, required this.onChanged, this.hint = 'بحث...', this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Row(children: [
          Expanded(
            child: TextField(
              onChanged: onChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ]),
      );
}

/// حقل نصي مع تحقق، لنماذج الإدخال.
Widget formField(
  String label,
  TextEditingController c, {
  TextInputType? type,
  bool required = false,
  int maxLines = 1,
  String? Function(String?)? validator,
  Widget? suffix,
  void Function(String)? onChanged,
}) =>
    Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: TextFormField(
        controller: c,
        keyboardType: type,
        maxLines: maxLines,
        onChanged: onChanged,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), suffixIcon: suffix),
        validator: validator ??
            (required ? (v) => (v == null || v.trim().isEmpty) ? 'هذا الحقل مطلوب' : null : null),
      ),
    );

class StatCard extends StatelessWidget {
  final String title, value;
  final IconData icon;
  final Color? color;
  final VoidCallback? onTap;
  const StatCard(this.title, this.value, this.icon, {super.key, this.color, this.onTap});
  @override
  Widget build(BuildContext context) {
    final c = color ?? Theme.of(context).colorScheme.primary;
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(children: [
            CircleAvatar(backgroundColor: c.withValues(alpha: .12), child: Icon(icon, color: c)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 2),
                FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(value, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold))),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
