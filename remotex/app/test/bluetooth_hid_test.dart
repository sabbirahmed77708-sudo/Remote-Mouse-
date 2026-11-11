import 'package:flutter_test/flutter_test.dart';
import 'package:remotex/services/bluetooth_hid.dart';

void main() {
  test('mouse report: buttons, signed movement, wheel', () {
    expect(mouseReport(1, 10, -10, wheel: 1, pan: -1), [1, 10, 246, 1, 255]);
    expect(mouseReport(7, 500, -500), [7, 127, 129, 0, 0]); // clamped to a signed byte
    expect(mouseReport(9, 0, 0), [1, 0, 0, 0, 0]); // only 3 buttons
  });

  test('keyboard report: modifiers and padding', () {
    expect(keyboardReport(modCtrl | modShift, [0x29]), [3, 0, 0x29, 0, 0, 0, 0, 0]);
    expect(keyboardReport(0, const []), [0, 0, 0, 0, 0, 0, 0, 0]);
    expect(keyboardReport(0, [1, 2, 3, 4, 5, 6, 7]).length, 8);
  });

  test('consumer report is little endian', () {
    expect(consumerReport(0xCD), [0xCD, 0]);
    expect(consumerReport(0x0192), [0x92, 0x01]);
  });

  test('key names map to USB HID usages', () {
    expect(hidKeyUsage('a'), 0x04);
    expect(hidKeyUsage('z'), 0x1D);
    expect(hidKeyUsage('1'), 0x1E);
    expect(hidKeyUsage('0'), 0x27);
    expect(hidKeyUsage('enter'), 0x28);
    expect(hidKeyUsage('f1'), 0x3A);
    expect(hidKeyUsage('f12'), 0x45);
    expect(hidKeyUsage('up'), 0x52);
    expect(hidKeyUsage('nonsense'), isNull);
    expect(hidModifierBit('win'), modWin);
    expect(hidModifierBit('x'), 0);
    expect(hidConsumerUsage('playpause'), 0xCD);
    expect(hidConsumerUsage('volup'), 0xE9);
  });

  test('every key the app can send has a usage', () {
    const names = [
      'esc', 'tab', 'enter', 'backspace', 'delete', 'home', 'end', 'pgup', 'pgdn', 'space',
      'up', 'down', 'left', 'right', 'f1', 'f2', 'f3', 'f4', 'f5', 'f6', 'f7', 'f8', 'f9', 'f10', 'f11', 'f12',
    ];
    for (final n in names) {
      expect(hidKeyUsage(n), isNotNull, reason: n);
    }
    for (final m in ['prev', 'playpause', 'next', 'voldown', 'mute', 'volup', 'stop']) {
      expect(hidConsumerUsage(m), isNotNull, reason: m);
    }
  });

  test('characters: shift for capitals and symbols', () {
    expect(hidForChar('a'), (0, 0x04));
    expect(hidForChar('A'), (modShift, 0x04));
    expect(hidForChar('1'), (0, 0x1E));
    expect(hidForChar('!'), (modShift, 0x1E));
    expect(hidForChar(')'), (modShift, 0x27));
    expect(hidForChar('@'), (modShift, 0x1F));
    expect(hidForChar(' '), (0, 0x2C));
    expect(hidForChar('\n'), (0, 0x28));
    expect(hidForChar('?'), (modShift, 0x38));
    expect(hidForChar('/'), (0, 0x38));
    expect(hidForChar('\u09ac'), isNull); // no Bengali on a US keyboard layout
  });

  test('all printable ASCII can be typed', () {
    for (var c = 0x20; c < 0x7F; c++) {
      expect(hidForChar(String.fromCharCode(c)), isNotNull, reason: String.fromCharCode(c));
    }
  });
}
