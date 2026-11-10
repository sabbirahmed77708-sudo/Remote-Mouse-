import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/update_service.dart';

void main() {
  test('version comparison', () {
    expect(compareVersions('1.1.0', '1.0.9'), greaterThan(0));
    expect(compareVersions('1.0.0', '1.0.0'), 0);
    expect(compareVersions('1.0', '1.0.0'), 0);
    expect(compareVersions('2.0.0', '10.0.0'), lessThan(0));
    expect(compareVersions('1.10.0', '1.9.0'), greaterThan(0));
  });

  test('release parsing picks arm64 apk and detects update', () {
    final info = parseRelease({
      'tag_name': 'remotex-v1.2.0',
      'html_url': 'https://github.com/x/y/releases/tag/remotex-v1.2.0',
      'body': 'New stuff',
      'assets': [
        {'name': 'RemoteX-x86_64.apk', 'browser_download_url': 'https://example.com/x86.apk'},
        {'name': 'RemoteX-arm64.apk', 'browser_download_url': 'https://example.com/arm64.apk'},
        {'name': 'RemoteXServer.exe', 'browser_download_url': 'https://example.com/s.exe'},
      ],
    }, current: '1.1.0');
    expect(info, isNotNull);
    expect(info!.latest, '1.2.0');
    expect(info.apkUrl, 'https://example.com/arm64.apk');
    expect(info.available, isTrue);
    expect(info.notes, 'New stuff');
  });

  test('same or older release is not an update; bad data is rejected', () {
    expect(parseRelease({'tag_name': 'remotex-v1.1.0', 'assets': []}, current: '1.1.0')!.available, isFalse);
    expect(parseRelease({'tag_name': 'v0.9', 'assets': []}, current: '1.1.0')!.available, isFalse);
    expect(parseRelease({'name': 'no tag'}), isNull);
    expect(parseRelease({'tag_name': 'nightly'}), isNull);
  });

  test('non-https download links are ignored', () {
    final info = parseRelease({
      'tag_name': 'v2.0.0',
      'assets': [
        {'name': 'a.apk', 'browser_download_url': 'http://evil.example/a.apk'},
      ],
    }, current: '1.0.0');
    expect(info!.apkUrl, isNull);
  });
}
