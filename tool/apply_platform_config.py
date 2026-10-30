#!/usr/bin/env python3
"""Adds the permission declarations to android/ and ios/ (idempotent).

Usage (from frontend_flutter/):
    flutter create --org com.rdlive --project-name rdlive --platforms android,ios .
    python3 tool/apply_platform_config.py
"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
cfg = root / "platform_config"
MARK = "rdlive permissions"
ok = True

# ---- Android -------------------------------------------------------------
man = root / "android/app/src/main/AndroidManifest.xml"
if not man.exists():
    sys.exit("android/ not found: run `flutter create --platforms android,ios .` first")
s = man.read_text()
if MARK not in s:
    block = (cfg / "android_permissions.xml").read_text()
    # skip lines already present (flutter create may add INTERNET in debug/profile manifests only)
    s, n = re.subn(r"(\s*<application\b)", "\n" + block.rstrip("\n") + r"\n\1", s, count=1)
    if n != 1:
        sys.exit("could not find <application> in AndroidManifest.xml")
    man.write_text(s)
    print("patched", man)
else:
    print("android manifest already patched")

# ---- iOS Info.plist ------------------------------------------------------
plist = root / "ios/Runner/Info.plist"
if plist.exists():
    s = plist.read_text()
    if MARK not in s:
        block = (cfg / "ios_infoplist.xml").read_text()
        i = s.rfind("</dict>")
        if i < 0:
            sys.exit("Info.plist has no </dict>")
        s = s[:i] + block + s[i:]
        plist.write_text(s)
        print("patched", plist)
    else:
        print("Info.plist already patched")
else:
    print("ios/Runner/Info.plist missing; skipped iOS")

# ---- iOS Podfile ---------------------------------------------------------
pod = root / "ios/Podfile"
if pod.exists():
    s = pod.read_text()
    if "PERMISSION_CAMERA=1" not in s:
        block = (cfg / "ios_podfile_post_install.rb").read_text().rstrip("\n")
        # inside:  flutter_additional_ios_build_settings(target)
        pat = r"(\n[ \t]*flutter_additional_ios_build_settings\(target\)[ \t]*\n)"
        s, n = re.subn(pat, lambda m: m.group(1) + block + "\n", s, count=1)
        if n != 1:
            sys.exit("could not find flutter_additional_ios_build_settings(target) in Podfile; add ios_podfile_post_install.rb by hand")
        pod.write_text(s)
        print("patched", pod)
    else:
        print("Podfile already patched")
    if not re.search(r"^\s*platform :ios, '1[2-9]", pod.read_text(), re.M):
        print("NOTE: set `platform :ios, '13.0'` (or higher) at the top of ios/Podfile.")
else:
    print("ios/Podfile missing; skipped")

print("done. Also make sure android/app/build.gradle(.kts) has minSdk >= 23 and compileSdk >= 34.")
