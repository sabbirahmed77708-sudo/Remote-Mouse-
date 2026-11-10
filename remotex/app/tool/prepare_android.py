#!/usr/bin/env python3
"""Creates (if missing) and configures app/android for RemoteX. Safe to run repeatedly.

  cd app && python tool/prepare_android.py

Needs the Flutter SDK on PATH for the first run (it calls `flutter create`).
"""
import os
import re
import subprocess
import sys

APP = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
ANDROID = os.path.join(APP, "android")
MANIFEST = os.path.join(ANDROID, "app", "src", "main", "AndroidManifest.xml")
RES = os.path.join(ANDROID, "app", "src", "main", "res")


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def write(p, s):
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "w", encoding="utf-8", newline="\n") as f:
        f.write(s)


def create():
    if os.path.exists(MANIFEST):
        return
    subprocess.check_call(["flutter", "create", "--platforms=android", "--org", "app.remotex",
                           "--project-name", "remotex", "--no-pub", "."], cwd=APP)


def patch_gradle():
    for name in ("build.gradle.kts", "build.gradle"):
        p = os.path.join(ANDROID, "app", name)
        if not os.path.exists(p):
            continue
        s = read(p)
        n = re.sub(r"minSdk(Version)?(\s*=\s*|\s+)flutter\.minSdkVersion",
                   lambda m: "minSdk" + ("Version" if m.group(1) else "") + m.group(2) + "29", s)
        if n == s and not re.search(r"minSdk(Version)?\s*=?\s*29", s):
            sys.exit("could not set minSdk in " + p)
        write(p, n)
        return
    sys.exit("no app/build.gradle(.kts) found")


def patch_manifest():
    s = read(MANIFEST)
    s = re.sub(r'android:label="[^"]*"', 'android:label="RemoteX"', s, count=1)
    if "android.permission.INTERNET" not in s:
        perms = (
            '    <uses-permission android:name="android.permission.INTERNET"/>\n'
            '    <uses-permission android:name="android.permission.CAMERA"/>\n'
            '    <uses-permission android:name="android.permission.VIBRATE"/>\n'
            '    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n'
            '    <uses-feature android:name="android.hardware.touchscreen" android:required="true"/>\n'
        )
        s = re.sub(r"(<manifest[^>]*>\s*\n)", lambda m: m.group(1) + perms, s, count=1)
    if "usesCleartextTraffic" not in s:
        s = s.replace("<application", '<application\n        android:usesCleartextTraffic="false"', 1)
    write(MANIFEST, s)


def icons():
    write(os.path.join(RES, "values", "ic_launcher_background.xml"),
          '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
          '    <color name="ic_launcher_background">#0F1115</color>\n</resources>\n')
    write(os.path.join(RES, "drawable", "ic_launcher_foreground.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#4F8CFF"
        android:pathData="M54,26 C45,26 38,33 38,42 L38,66 C38,75 45,82 54,82 C63,82 70,75 70,66 L70,42 C70,33 63,26 54,26 Z"/>
    <path android:fillColor="#0F1115"
        android:pathData="M52.5,30 L55.5,30 L55.5,50 L52.5,50 Z"/>
    <path android:fillColor="#0F1115"
        android:pathData="M38,50 L70,50 L70,52.5 L38,52.5 Z"/>
</vector>
''')
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@color/ic_launcher_background"/>\n'
           '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
           '    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n'
           '</adaptive-icon>\n')
    write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml"), xml)
    write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher_round.xml"), xml)


if __name__ == "__main__":
    create()
    patch_gradle()
    patch_manifest()
    icons()
    print("android/ is ready (minSdk 29, INTERNET + CAMERA + VIBRATE, RemoteX icon)")
