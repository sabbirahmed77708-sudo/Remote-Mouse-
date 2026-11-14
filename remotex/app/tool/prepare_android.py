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


def patch_minify():
    """R8 shrinking renames/removes classes the camera (QR scanner) needs, and the camera then fails to start.
    The app is small anyway (the Flutter engine is most of it), so the release build keeps all classes."""
    p = os.path.join(ANDROID, "app", "build.gradle.kts")
    s = read(p)
    if "isMinifyEnabled" in s:
        return
    marker = 'signingConfig = if (System.getenv("RX_KEYSTORE")'
    i = s.find(marker)
    if i < 0:
        sys.exit("cannot find the release signing line to add the minify setting")
    j = s.index("\n", i)
    indent = " " * (len(s[s.rfind("\n", 0, i) + 1:i]))
    s = s[:j] + "\n" + indent + "isMinifyEnabled = false\n" + indent + "isShrinkResources = false" + s[j:]
    write(p, s)


def patch_lint():
    """Android lint's release check crashes inside some plugins (tool bug, not our code): turn it off."""
    for name in ("build.gradle.kts", "build.gradle"):
        p = os.path.join(ANDROID, name)
        if not os.path.exists(p):
            continue
        s = read(p)
        if "lintVital" in s:
            return
        if name.endswith(".kts"):
            s += ('\nsubprojects {\n    tasks.configureEach {\n'
                  '        if (name.startsWith("lintVital") || name == "lintAnalyzeRelease") { enabled = false }\n    }\n}\n')
        else:
            s += ('\nsubprojects {\n    tasks.configureEach { t ->\n'
                  '        if (t.name.startsWith("lintVital") || t.name == "lintAnalyzeRelease") { t.enabled = false }\n    }\n}\n')
        write(p, s)
        return
    sys.exit("no android/build.gradle(.kts) found")


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
    s = re.sub(r'android:label="[^"]*"', 'android:label="Remote Mouse"', s, count=1)
    if "android.permission.INTERNET" not in s:
        perms = (
            '    <uses-permission android:name="android.permission.INTERNET"/>\n'
            '    <uses-permission android:name="android.permission.CAMERA"/>\n'
            '    <uses-permission android:name="android.permission.VIBRATE"/>\n'
            '    <uses-permission android:name="android.permission.ACCESS_WIFI_STATE"/>\n'
            '    <uses-permission android:name="android.permission.WAKE_LOCK"/>\n'
            '    <uses-permission android:name="android.permission.REQUEST_INSTALL_PACKAGES"/>\n'
            '    <uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30"/>\n'
            '    <uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30"/>\n'
            '    <uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>\n'
            '    <uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>\n'
            '    <uses-feature android:name="android.hardware.bluetooth" android:required="false"/>\n'
            '    <uses-feature android:name="android.hardware.camera" android:required="false"/>\n'
            '    <uses-feature android:name="android.hardware.touchscreen" android:required="true"/>\n'
        )
        s = re.sub(r"(<manifest[^>]*>\s*\n)", lambda m: m.group(1) + perms, s, count=1)
    if "rx_file_paths" not in s:
        provider = (
            '        <provider android:name="androidx.core.content.FileProvider"\n'
            '            android:authorities="${applicationId}.update" android:exported="false"\n'
            '            android:grantUriPermissions="true">\n'
            '            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/rx_file_paths"/>\n'
            '        </provider>\n'
        )
        s = s.replace("</application>", provider + "    </application>", 1)
    if "usesCleartextTraffic" not in s:
        s = s.replace("<application", '<application\n        android:usesCleartextTraffic="false"', 1)
    write(MANIFEST, s)


def write_main_activity():
    """MainActivity with the Bluetooth mouse/keyboard bridge (see tool/MainActivity.kt.tmpl)."""
    base = os.path.join(ANDROID, "app", "src", "main", "kotlin")
    found = None
    for root, _dirs, files in os.walk(base):
        if "MainActivity.kt" in files:
            found = os.path.join(root, "MainActivity.kt")
    if not found:
        sys.exit("MainActivity.kt not found under " + base)
    m = re.search(r"^package\s+([\w.]+)", read(found), re.M)
    package = m.group(1) if m else "app.remotex.remotex"
    tmpl = read(os.path.join(APP, "tool", "MainActivity.kt.tmpl"))
    write(found, tmpl.replace("__PACKAGE__", package))


def update_support():
    """FileProvider paths and the androidx.core dependency used by the in-app installer."""
    write(os.path.join(RES, "xml", "rx_file_paths.xml"),
          '<?xml version="1.0" encoding="utf-8"?>\n<paths>\n    <cache-path name="cache" path="."/>\n</paths>\n')
    p = os.path.join(ANDROID, "app", "build.gradle.kts")
    s = read(p)
    if "androidx.core:core" not in s:
        s += '\ndependencies {\n    implementation("androidx.core:core:1.13.1")\n}\n'
        write(p, s)


def icons():
    write(os.path.join(RES, "values", "ic_launcher_background.xml"),
          '<?xml version="1.0" encoding="utf-8"?>\n<resources>\n'
          '    <color name="ic_launcher_background">#0F1115</color>\n</resources>\n')
    write(os.path.join(RES, "drawable", "ic_launcher_bg.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<shape xmlns:android="http://schemas.android.com/apk/res/android" android:shape="rectangle">
    <gradient android:type="linear" android:angle="315"
        android:startColor="#10B981" android:endColor="#065F46"/>
</shape>
''')
    write(os.path.join(RES, "drawable", "ic_launcher_foreground.xml"),
          '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <group android:pivotX="54" android:pivotY="54" android:scaleX="0.78" android:scaleY="0.78">
        <group android:pivotX="54" android:pivotY="54" android:rotation="18">
            <path android:fillColor="#FFFFFF"
                android:pathData="M38,50 A16,16 0 0 1 70,50 L70,74 A16,16 0 0 1 38,74 Z"/>
            <path android:fillColor="#10966E"
                android:pathData="M38,57.5 L70,57.5 L70,59.7 L38,59.7 Z"/>
            <path android:fillColor="#10966E"
                android:pathData="M52.9,34.5 L55.1,34.5 L55.1,58 L52.9,58 Z"/>
            <path android:fillColor="#10966E"
                android:pathData="M51,45 A3,3 0 0 1 57,45 L57,51 A3,3 0 0 1 51,51 Z"/>
        </group>
        <path android:strokeColor="#FFFFFF" android:strokeWidth="3" android:pathData="%s"/>
        <path android:strokeColor="#CCFFFFFF" android:strokeWidth="3" android:pathData="%s"/>
        <path android:strokeColor="#99FFFFFF" android:strokeWidth="3" android:pathData="%s"/>
    </group>
</vector>
''' % ('M73.74,18.15 A10,10 0 0 1 81.85,29.74', 'M75.13,10.27 A18,18 0 0 1 89.73,31.13', 'M76.51,2.39 A26,26 0 0 1 97.61,32.51'))
    xml = ('<?xml version="1.0" encoding="utf-8"?>\n'
           '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
           '    <background android:drawable="@drawable/ic_launcher_bg"/>\n'
           '    <foreground android:drawable="@drawable/ic_launcher_foreground"/>\n'
           '    <monochrome android:drawable="@drawable/ic_launcher_foreground"/>\n'
           '</adaptive-icon>\n')
    write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml"), xml)
    write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher_round.xml"), xml)


if __name__ == "__main__":
    create()
    drop_template_test()
    patch_gradle()
    patch_lint()
    patch_signing()
    patch_minify()
    patch_manifest()
    write_main_activity()
    update_support()
    icons()
    print("android/ is ready (minSdk 24, INTERNET + CAMERA + VIBRATE, Remote Mouse icon)")
