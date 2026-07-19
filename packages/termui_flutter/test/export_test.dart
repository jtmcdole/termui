import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  test('waitForFontsToLoad is exported by public API', () {
    // This will fail to compile if the function is not exported.
    expect(waitForFontsToLoad, isNotNull);
  });
}
