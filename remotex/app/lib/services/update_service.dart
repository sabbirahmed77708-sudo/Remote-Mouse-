import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Version of this build. Keep in sync with `version:` in pubspec.yaml.
const String kAppVersion = '1.1.0';

const String kRepo = 'sabbirahmed77708-sudo/remote-mouse-';
const String kReleasesPage = 'https://github.com/$kRepo/releases';

class UpdateInfo {
  UpdateInfo({required this.current, required this.latest, required this.apkUrl, required this.pageUrl, required this.notes});

  final String current;
  final String latest;
  final String? apkUrl;
  final String pageUrl;
  final String notes;

  bool get available => compareVersions(latest, current) > 0;
}

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Compares "1.2.3" style versions. Missing parts count as 0; non-numeric junk is ignored.
int compareVersions(String a, String b) {
  List<int> parse(String v) => RegExp(r'\d+').allMatches(v).map((m) => int.parse(m.group(0)!)).toList();
  final x = parse(a), y = parse(b);
  for (var i = 0; i < 3; i++) {
    final p = i < x.length ? x[i] : 0, q = i < y.length ? y[i] : 0;
    if (p != q) return p.compareTo(q);
  }
  return 0;
}

/// Pulls version, APK link and notes out of a GitHub "latest release" JSON document.
UpdateInfo? parseRelease(Map<String, dynamic> json, {String current = kAppVersion}) {
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final m = RegExp(r'(\d+(?:\.\d+){0,2})').firstMatch(tag);
  if (m == null) return null;
  String? apk;
  String? anyApk;
  final assets = json['assets'];
  if (assets is List) {
    for (final a in assets) {
      if (a is Map && a['name'] is String && (a['name'] as String).toLowerCase().endsWith('.apk')) {
        final u = a['browser_download_url'];
        if (u is! String || !u.startsWith('https://')) continue;
        anyApk ??= u;
        if ((a['name'] as String).toLowerCase().contains('arm64')) apk = u; // what almost every phone needs
      }
    }
  }
  apk ??= anyApk;
  final page = json['html_url'];
  final body = json['body'];
  return UpdateInfo(
    current: current,
    latest: m.group(1)!,
    apkUrl: apk,
    pageUrl: page is String && page.startsWith('https://') ? page : kReleasesPage,
    notes: body is String ? body.trim() : '',
  );
}

/// Asks GitHub for the newest release of RemoteX. Needs internet (not the PC).
Future<UpdateInfo> checkForUpdate({Duration timeout = const Duration(seconds: 10)}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('User-Agent', 'RemoteX-App');
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == 404) throw UpdateException('No release has been published yet.');
    if (res.statusCode != 200) throw UpdateException('GitHub answered ${res.statusCode}. Try again later.');
    final json = jsonDecode(text);
    final info = json is Map<String, dynamic> ? parseRelease(json) : null;
    if (info == null) throw UpdateException('Could not read the release information.');
    return info;
  } on UpdateException {
    rethrow;
  } on TimeoutException {
    throw UpdateException('GitHub did not answer. Check your internet connection.');
  } on SocketException {
    throw UpdateException('No internet connection.');
  } on HandshakeException {
    throw UpdateException('Secure connection to GitHub failed.');
  } catch (_) {
    throw UpdateException('Could not check for updates.');
  } finally {
    client.close(force: true);
  }
}
