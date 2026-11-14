#!/usr/bin/env python3
"""يولّد version.json (يقرؤه التطبيق للتحقق من التحديثات) من pubspec.yaml والـ APK.

الاستخدام: make_version_json.py <apk> <repo owner/name> <out> [notes]
"""
import hashlib, json, re, sys

apk, repo, out = sys.argv[1:4]
notes = sys.argv[4] if len(sys.argv) > 4 else ""
text = open("pubspec.yaml", encoding="utf-8").read()
m = re.search(r"^version:\s*([0-9.]+)\+(\d+)\s*$", text, re.M)
if not m:
    sys.exit("pubspec.yaml: صيغة version غير صحيحة (المطلوب x.y.z+N)")
name, code = m.group(1), int(m.group(2))
sha = hashlib.sha256(open(apk, "rb").read()).hexdigest()
tag = f"v{name}-{code}"
json.dump(
    {
        "versionCode": code,
        "versionName": name,
        "apkUrl": f"https://github.com/{repo}/releases/download/{tag}/nasaq_market.apk",
        "sha256": sha,
        "notes": notes,
        "mandatory": False,
    },
    open(out, "w", encoding="utf-8"),
    ensure_ascii=False,
    indent=2,
)
print(f"version.json: {name} ({code}) sha256={sha[:12]}…")
