#!/usr/bin/env python3
"""يصدّر جهات الاتصال التي **وافقت** على التواصل فقط (من users/{uid}) إلى CSV.

  pip install google-cloud-firestore
  export GOOGLE_APPLICATION_CREDENTIALS=/path/to/key.json      # حساب الخدمة، لا يُرفع إلى git
  python3 tool/export_contacts.py --channel email    --project my-project   # من وافق على الإيميل
  python3 tool/export_contacts.py --channel whatsapp --project my-project   # من وافق على الواتساب وله رقم
  python3 tool/export_contacts.py --channel any      --project my-project

لا يُصدَّر أحد لم يضع علامة الموافقة بنفسه. عند طلب حذف من مستخدم: احذف مستنده من users
(ومن Authentication إن طلب حذف الحساب كلياً) ولا تُدرجه في أي حملة لاحقة.
"""
import argparse
import csv


def eligible(d: dict, channel: str) -> bool:
    mail = d.get("marketingEmail") is True and bool(d.get("email"))
    wa = d.get("marketingWhatsapp") is True and bool(d.get("phone"))
    return {"email": mail, "whatsapp": wa, "any": mail or wa}[channel]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--channel", choices=["email", "whatsapp", "any"], required=True)
    p.add_argument("--project")
    p.add_argument("--out")
    a = p.parse_args()
    from google.cloud import firestore
    db = firestore.Client(project=a.project)
    rows = []
    for doc in db.collection("users").stream():
        d = doc.to_dict()
        if eligible(d, a.channel):
            ts = d.get("consentAt")
            rows.append([d.get("email", ""), d.get("phone", ""), d.get("marketingEmail") is True,
                         d.get("marketingWhatsapp") is True, ts.isoformat() if ts else ""])
    out = a.out or f"contacts_{a.channel}.csv"
    with open(out, "w", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        w.writerow(["email", "phone", "agreed_email", "agreed_whatsapp", "consent_at"])
        w.writerows(rows)
    print(f"{len(rows)} جهة اتصال وافقت ({a.channel}) ← {out}")


if __name__ == "__main__":
    main()
