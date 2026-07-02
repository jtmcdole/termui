import 'package:test/test.dart';
import 'package:termui_hotreload/termui_hotreload.dart';

void main() {
  group('TermuiHotReload', () {
    test('enable() works gracefully with or without VM service', () async {
      final reloader = await TermuiHotReload.enable();
      await reloader?.disable();
    });
  });
}
