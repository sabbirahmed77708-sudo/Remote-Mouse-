import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Version of this build. Keep in sync with `version:` in pubspec.yaml.
const String kAppVersion = '1.7.3';

const String kRepo = 'sabbirahmed77708-sudo/remote-mouse-';
const String kReleasesPage = 'https://github.com/$kRepo/releases';
const String kPcDownloadPage = 'https://remotemouse-1ib.pages.dev/pc';

/// Typed into PowerShell on the PC. The installer then has no "downloaded from the internet" mark, so the
/// Windows SmartScreen warning does not appear.
const String kPcInstallCommand =
    'irm https://remotemouse-1ib.pages.dev/install.ps1 | iex';

class UpdateInfo {
  UpdateInfo({
    required this.current,
    required this.latest,
    required this.apkUrl,
    required this.pageUrl,
    required this.notes,
    this.apkSize,
    this.apkSha256,
  });

  final String current;
  final String latest;
  final String? apkUrl;
  final String pageUrl;
  final String notes;
  final int? apkSize;
  final String? apkSha256;

  bool get available => compareVersions(latest, current) > 0;
}

class UpdateException implements Exception {
  UpdateException(this.message, {this.notFound = false});
  final String message;
  final bool notFound;
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

/// Release notes without build bookkeeping lines.
String cleanNotes(String body) => body
    .split('\n')
    .where((l) => !RegExp(r'^\s*(co-authored-by|claude-session)\s*:', caseSensitive: false).hasMatch(l))
    .join('\n')
    .trim();

/// Pulls version, APK link and notes out of a GitHub "latest release" JSON document.
UpdateInfo? parseRelease(Map<String, dynamic> json, {String current = kAppVersion}) {
  final tag = json['tag_name'];
  if (tag is! String) return null;
  final m = RegExp(r'(\d+(?:\.\d+){0,2})').firstMatch(tag);
  if (m == null) return null;
  String? apk;
  String? anyApk;
  int? apkSize;
  String? apkSha;
  int? anySize;
  String? anySha;
  final assets = json['assets'];
  if (assets is List) {
    for (final a in assets) {
      if (a is Map && a['name'] is String && (a['name'] as String).toLowerCase().endsWith('.apk')) {
        final u = a['browser_download_url'];
        if (u is! String || !u.startsWith('https://')) continue;
        final size = a['size'] is int ? a['size'] as int : null;
        final digest = a['digest'];
        final sha = digest is String && RegExp(r'^sha256:[0-9a-fA-F]{64}$').hasMatch(digest) ? digest.substring(7).toLowerCase() : null;
        if (anyApk == null) {
          anyApk = u;
          anySize = size;
          anySha = sha;
        }
        if ((a['name'] as String).toLowerCase().contains('arm64')) {
          apk = u; // what almost every phone needs
          apkSize = size;
          apkSha = sha;
        }
      }
    }
  }
  if (apk == null) {
    apk = anyApk;
    apkSize = anySize;
    apkSha = anySha;
  }
  final page = json['html_url'];
  final body = json['body'];
  return UpdateInfo(
    current: current,
    latest: m.group(1)!,
    apkUrl: apk,
    pageUrl: page is String && page.startsWith('https://') ? page : kReleasesPage,
    notes: body is String ? cleanNotes(body) : '',
    apkSize: apkSize,
    apkSha256: apkSha,
  );
}

/// Asks the release server for the newest version. Needs internet (not the PC).
/// The detailed answer can be refused when many phones share one network address (rate limit);
/// then the plain "latest" link is used instead, which has no such limit.
Future<UpdateInfo> checkForUpdate({Duration timeout = const Duration(seconds: 10)}) async {
  try {
    return await _checkDetailed(timeout);
  } on UpdateException catch (e) {
    if (e.notFound) rethrow;
  } catch (_) {
    // fall through to the simple check
  }
  return _checkSimple(timeout);
}

Future<UpdateInfo> _checkDetailed(Duration timeout) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$kRepo/releases/latest'));
    req.headers.set('Accept', 'application/vnd.github+json');
    req.headers.set('User-Agent', 'Remote-Mouse-App');
    final res = await req.close().timeout(timeout);
    final text = await res.transform(utf8.decoder).join().timeout(timeout);
    if (res.statusCode == 404) throw UpdateException('No release has been published yet.', notFound: true);
    if (res.statusCode != 200) throw UpdateException('The update server answered ${res.statusCode}.');
    final json = jsonDecode(text);
    final info = json is Map<String, dynamic> ? parseRelease(json) : null;
    if (info == null) throw UpdateException('Could not read the release information.');
    return info;
  } finally {
    client.close(force: true);
  }
}

/// Reads the newest version number from where the "latest" link leads to, and builds the APK link from it.
Future<UpdateInfo> _checkSimple(Duration timeout, {String current = kAppVersion}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final req = await client.getUrl(Uri.parse('https://github.com/$kRepo/releases/latest'));
    req.followRedirects = false;
    req.headers.set('User-Agent', 'Remote-Mouse-App');
    final res = await req.close().timeout(timeout);
    await res.drain<void>();
    final where = res.headers.value('location') ?? '';
    final m = RegExp(r'/releases/tag/([^/?#]+)$').firstMatch(where);
    final v = m == null ? null : RegExp(r'(\d+\.\d+\.\d+)').firstMatch(m.group(1)!);
    if (m == null || v == null) throw UpdateException('Could not check for updates right now. Try again later.');
    final tag = m.group(1)!;
    return UpdateInfo(
      current: current,
      latest: v.group(1)!,
      apkUrl: 'https://github.com/$kRepo/releases/download/$tag/Remote-Mouse-arm64.apk',
      pageUrl: kReleasesPage,
      notes: '',
    );
  } on UpdateException {
    rethrow;
  } on TimeoutException {
    throw UpdateException('The update server did not answer. Check your internet connection.');
  } on SocketException {
    throw UpdateException('No internet connection.');
  } on HandshakeException {
    throw UpdateException('Secure connection failed.');
  } catch (_) {
    throw UpdateException('Could not check for updates.');
  } finally {
    client.close(force: true);
  }
}

// ---------------------------------------------------------------------------
// In-app update: download, verify, hand to the Android installer
// ---------------------------------------------------------------------------

const MethodChannel _updateChannel = MethodChannel('remotex/update');

enum UpdateStage { idle, checking, upToDate, available, downloading, installing, needsPermission, failed }

/// Everything about updating, so the screens only show state.
class UpdateController extends ChangeNotifier {
  UpdateStage stage = UpdateStage.idle;
  UpdateInfo? info;
  double progress = 0;
  String? error;

  bool get hasUpdate => info != null && info!.available;

  void _set(UpdateStage s) {
    stage = s;
    notifyListeners();
  }

  /// [silent]: no spinner and no error message (used at app start).
  Future<void> check({bool silent = false}) async {
    if (stage == UpdateStage.checking || stage == UpdateStage.downloading) return;
    error = null;
    if (!silent) _set(UpdateStage.checking);
    try {
      final r = await checkForUpdate();
      info = r;
      _set(r.available ? UpdateStage.available : UpdateStage.upToDate);
    } on UpdateException catch (e) {
      if (silent) {
        if (stage == UpdateStage.checking) _set(UpdateStage.idle);
        return;
      }
      error = e.message;
      _set(UpdateStage.failed);
    }
  }

  /// Downloads the new version and opens the Android installer.
  Future<void> install() async {
    final i = info;
    if (i == null || !i.available) return;
    if (stage == UpdateStage.downloading || stage == UpdateStage.installing) return;
    error = null;
    progress = 0;
    _set(UpdateStage.downloading);
    try {
      final url = i.apkUrl;
      if (url == null) throw UpdateException('This version has no app file for your phone yet.');
      final dir = await _updateChannel.invokeMethod<String>('cacheDir') ?? Directory.systemTemp.path;
      final file = await downloadApk(url, '$dir/Remote-Mouse-update.apk', expectedSize: i.apkSize, expectedSha256: i.apkSha256,
          onProgress: (p) {
        progress = p;
        notifyListeners();
      });
      _set(UpdateStage.installing);
      final res = await _updateChannel.invokeMethod<String>('install', {'path': file.path});
      if (res == 'needs_permission') {
        _set(UpdateStage.needsPermission);
      } else {
        _set(UpdateStage.available); // the installer is on screen now
      }
    } on UpdateException catch (e) {
      error = e.message;
      _set(UpdateStage.failed);
    } on PlatformException {
      error = 'Could not open the installer.';
      _set(UpdateStage.failed);
    } on MissingPluginException {
      error = 'Updating inside the app works on Android only.';
      _set(UpdateStage.failed);
    }
  }
}

/// Downloads [url] to [path], checks size and SHA-256 (when known) and returns the file.
Future<File> downloadApk(
  String url,
  String path, {
  int? expectedSize,
  String? expectedSha256,
  void Function(double progress)? onProgress,
  Duration timeout = const Duration(seconds: 30),
}) async {
  final file = File(path);
  if (file.existsSync()) file.deleteSync();
  final client = HttpClient()..connectionTimeout = timeout;
  IOSink? sink;
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'Remote-Mouse-App');
    final res = await req.close().timeout(timeout);
    if (res.statusCode != 200) throw UpdateException('Download failed (${res.statusCode}).');
    final total = expectedSize ?? (res.contentLength > 0 ? res.contentLength : null);
    var got = 0;
    sink = file.openWrite();
    await for (final chunk in res.timeout(timeout)) {
      sink.add(chunk);
      got += chunk.length;
      if (total != null && onProgress != null) onProgress((got / total).clamp(0.0, 1.0));
    }
    await sink.close();
    sink = null;
    if (expectedSize != null && got != expectedSize) throw UpdateException('The download was incomplete. Try again.');
    if (expectedSha256 != null) {
      final digest = (await sha256.bind(file.openRead()).first).toString();
      if (digest != expectedSha256.toLowerCase()) {
        file.deleteSync();
        throw UpdateException('The downloaded file did not pass the safety check.');
      }
    }
    return file;
  } on UpdateException {
    rethrow;
  } on TimeoutException {
    throw UpdateException('The download stalled. Check your internet connection.');
  } on SocketException {
    throw UpdateException('No internet connection.');
  } on HandshakeException {
    throw UpdateException('Secure connection failed.');
  } on FileSystemException {
    throw UpdateException('Not enough storage space to download the update.');
  } finally {
    try {
      await sink?.close();
    } catch (_) {}
    client.close(force: true);
  }
}
