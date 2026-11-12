import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/connection_controller.dart';

void main() {
  test('appDisplayName turns exe names into readable names', () {
    expect(appDisplayName('chrome.exe'), 'Chrome');
    expect(appDisplayName('WindowsTerminal.exe'), 'WindowsTerminal');
    expect(appDisplayName('avro_keyboard.exe'), 'Avro keyboard');
    expect(appDisplayName('notepad'), 'Notepad');
    expect(appDisplayName(''), 'App');
    expect(appDisplayName('.exe'), 'App');
  });

  test('parseWindows reads well formed items and skips the rest', () {
    final list = parseWindows([
      {'id': 10, 'title': 'Docs - Chrome', 'app': 'chrome.exe', 'min': false},
      {'id': 11, 'title': 'Notes', 'app': 'notepad.exe', 'min': true},
      {'id': 'x', 'title': 'bad id', 'app': 'a.exe'},
      {'id': 12, 'title': 5, 'app': 'a.exe'},
      {'id': 13, 'title': 'no app'},
      'junk',
      null,
    ]);
    expect(list.map((w) => w.id), [10, 11]);
    expect(list[0].appName, 'Chrome');
    expect(list[0].minimized, isFalse);
    expect(list[1].minimized, isTrue);
  });

  test('parseWindows survives anything that is not a list', () {
    expect(parseWindows(null), isEmpty);
    expect(parseWindows('x'), isEmpty);
    expect(parseWindows({'id': 1}), isEmpty);
  });

  test('windows with the same content are equal (so an unchanged list does not repaint)', () {
    const a = RemoteWindow(id: 1, title: 't', app: 'a.exe', minimized: false);
    const b = RemoteWindow(id: 1, title: 't', app: 'a.exe', minimized: false);
    const c = RemoteWindow(id: 1, title: 't', app: 'a.exe', minimized: true);
    expect(a, b);
    expect(a == c, isFalse);
  });
}
