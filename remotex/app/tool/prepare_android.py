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


def drop_template_test():
    p = os.path.join(APP, "test", "widget_test.dart")  # made by flutter create, refers to a class we do not have
    if os.path.exists(p):
        os.remove(p)


def patch_signing():
    """Release builds use the committed keystore when RX_KEYSTORE is set, so updates install over old versions."""
    p = os.path.join(ANDROID, "app", "build.gradle.kts")
    if not os.path.exists(p):
        sys.exit("signing patch needs app/build.gradle.kts (Kotlin DSL)")
    s = read(p)
    if "\"rx\"" in s:
        return
    old = 'signingConfig = signingConfigs.getByName("debug")'
    if old not in s or "buildTypes {" not in s:
        sys.exit("unexpected build.gradle.kts layout; cannot add signing")
    block = (
        "    signingConfigs {\n"
        '        create("rx") {\n'
        '            storeFile = System.getenv("RX_KEYSTORE")?.let { file(it) }\n'
        '            storePassword = System.getenv("RX_STORE_PASS")\n'
        '            keyAlias = System.getenv("RX_KEY_ALIAS")\n'
        '            keyPassword = System.getenv("RX_KEY_PASS")\n'
        "        }\n"
        "    }\n\n"
    )
    s = s.replace("    buildTypes {", block + "    buildTypes {", 1)
    s = s.replace(old, 'signingConfig = if (System.getenv("RX_KEYSTORE") != null) signingConfigs.getByName("rx") else signingConfigs.getByName("debug")', 1)
    write(p, s)


def patch_gradle():
    for name in ("build.gradle.kts", "build.gradle"):
        p = os.path.join(ANDROID, "app", name)
        if not os.path.exists(p):
            continue
        s = read(p)
        n = re.sub(r"minSdk(Version)?(\s*=\s*|\s+)flutter\.minSdkVersion",
                   lambda m: "minSdk" + ("Version" if m.group(1) else "") + m.group(2) + "24", s)
        if n == s and not re.search(r"minSdk(Version)?\s*=?\s*24", s):
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
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <group android:pivotX="54" android:pivotY="54" android:rotation="45">
        <path android:pathData="M43,32 L65,32 A11,11 0 0 1 76,43 L76,65 A11,11 0 0 1 65,76 L43,76 A11,11 0 0 1 32,65 L32,43 A11,11 0 0 1 43,32 Z">
            <aapt:attr name="android:fillColor">
                <gradient android:type="linear" android:startX="32" android:startY="32"
                    android:endX="76" android:endY="76"
                    android:startColor="#4F8CFF" android:endColor="#965AFF"/>
            </aapt:attr>
        </path>
    </group>
    <path android:fillColor="#FFFFFF"
        android:pathData="M45,41 L45,67 L51,61.5 L55,70 L59,68 L55,59.5 L63,59.5 Z"/>
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
    drop_template_test()
    patch_gradle()
    patch_signing()
    patch_manifest()
    icons()
    print("android/ is ready (minSdk 24, INTERNET + CAMERA + VIBRATE, RemoteX icon)")
