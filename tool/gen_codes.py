#!/usr/bin/env python3
"""أداة المطوّر لأكواد التفعيل (تعمل من جهازك وتتجاوز قواعد Firestore بحساب الخدمة).

الإعداد مرة واحدة:
  pip install google-cloud-firestore
  Firebase Console ← Project settings ← Service accounts ← Generate new private key
  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json     # لا ترفع هذا الملف إلى git أبداً

الاستعمال:
  python3 tool/gen_codes.py gen --plan 6m --count 50 --agent "أحمد" --project my-project
  python3 tool/gen_codes.py gen --plan 12m --count 20 --agent "ليلى" --dry-run      # بلا كتابة (للتجربة)
  python3 tool/gen_codes.py report --project my-project
  python3 tool/gen_codes.py lookup --code XXXX-XXXX-XXXX-XXXX --project my-project
  python3 tool/gen_codes.py cancel --agent "أحمد" --project my-project             # يلغي غير المستهلك فقط

الأنواع: 6m (6 أشهر) • 12m (سنة) • life (مدى الحياة).
الكود لا يُخزَّن: يُحفظ SHA-256 له معرّفاً للمستند، وملف CSV الناتج هو النسخة الوحيدة للتوزيع فاحفظه.
"""
import argparse
import csv
import hashlib
import re
import secrets
import sys
import time

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # يطابق lib/services/license.dart
PLANS = {"6m": "6 أشهر", "12m": "سنة", "life": "مدى الحياة"}


def generate_code() -> str:
    s = "".join(secrets.choice(ALPHABET) for _ in range(16))
    return "-".join(s[i:i + 4] for i in range(0, 16, 4))


def normalize(code: str) -> str:
    return re.sub(r"[^A-Z0-9]", "", code.upper())


def code_hash(code: str) -> str:
    return hashlib.sha256(normalize(code).encode()).hexdigest()


def _db(project):
    from google.cloud import firestore  # استيراد متأخر ليعمل --dry-run بدونه
    return firestore.Client(project=project)


def cmd_gen(a):
    if a.plan not in PLANS:
        sys.exit(f"النوع غير معروف: {a.plan} (المسموح: {', '.join(PLANS)})")
    batch_name = a.batch or time.strftime("%Y%m%d-%H%M")
    codes = []
    seen = set()
    while len(codes) < a.count:
        c = generate_code()
        h = code_hash(c)
        if h not in seen:
            seen.add(h)
            codes.append((c, h))
    if not a.dry_run:
        from google.cloud import firestore
        db = _db(a.project)
        col = db.collection("codes")
        for i in range(0, len(codes), 400):
            wb = db.batch()
            for c, h in codes[i:i + 400]:
                ref = col.document(h)
                if ref.get().exists:  # احتمال تصادم ضئيل جداً
                    sys.exit("تصادم في الأكواد، أعد التشغيل (لم يُحفظ شيء من هذه الدفعة بعد)")
                wb.set(ref, {"plan": a.plan, "agent": a.agent, "batch": batch_name, "status": "available",
                             "createdAt": firestore.SERVER_TIMESTAMP})
            wb.commit()
    out = a.out or f"codes_{a.agent}_{a.plan}_{batch_name}.csv".replace(" ", "_")
    with open(out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["الكود", "النوع", "المندوب", "الدفعة"])
        for c, _ in codes:
            w.writerow([c, PLANS[a.plan], a.agent, batch_name])
    mode = "تجربة (لم يُكتب شيء في Firestore)" if a.dry_run else "حُفظت في Firestore"
    print(f"{len(codes)} كود {PLANS[a.plan]} للمندوب {a.agent}: {mode}\nالملف: {out}")


def cmd_report(a):
    db = _db(a.project)
    rows = {}
    for d in db.collection("codes").stream():
        x = d.to_dict()
        k = (x.get("agent", "?"), x.get("plan", "?"))
        r = rows.setdefault(k, {"available": 0, "redeemed": 0, "cancelled": 0})
        r[x.get("status", "available")] = r.get(x.get("status", "available"), 0) + 1
    print(f"{'المندوب':<20}{'النوع':<12}{'متاح':>6}{'مستخدم':>8}{'ملغى':>6}")
    for (agent, plan), r in sorted(rows.items()):
        print(f"{agent:<20}{PLANS.get(plan, plan):<12}{r['available']:>6}{r['redeemed']:>8}{r['cancelled']:>6}")


def cmd_lookup(a):
    d = _db(a.project).collection("codes").document(code_hash(a.code)).get()
    if not d.exists:
        sys.exit("الكود غير موجود")
    x = d.to_dict()
    print({k: x.get(k) for k in ("plan", "agent", "batch", "status", "redeemedBy", "redeemedAt")})


def cmd_cancel(a):
    db = _db(a.project)
    q = db.collection("codes").where("agent", "==", a.agent).where("status", "==", "available")
    n = 0
    for d in q.stream():
        d.reference.update({"status": "cancelled"})
        n += 1
    print(f"أُلغي {n} كوداً غير مستخدم للمندوب {a.agent} (الأكواد المستخدمة والتراخيص القائمة لا تتأثر)")


def main():
    p = argparse.ArgumentParser(description="أداة أكواد التفعيل")
    sub = p.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--plan", required=True)
    g.add_argument("--count", type=int, required=True)
    g.add_argument("--agent", required=True)
    g.add_argument("--batch")
    g.add_argument("--out")
    g.add_argument("--project")
    g.add_argument("--dry-run", action="store_true")
    g.set_defaults(f=cmd_gen)
    r = sub.add_parser("report"); r.add_argument("--project"); r.set_defaults(f=cmd_report)
    l = sub.add_parser("lookup"); l.add_argument("--code", required=True); l.add_argument("--project"); l.set_defaults(f=cmd_lookup)
    c = sub.add_parser("cancel"); c.add_argument("--agent", required=True); c.add_argument("--project"); c.set_defaults(f=cmd_cancel)
    a = p.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
