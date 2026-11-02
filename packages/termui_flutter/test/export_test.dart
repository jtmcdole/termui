import 'package:flutter_test/flutter_test.dart';
import 'package:termui_flutter/termui_flutter.dart';

void main() {
  test('waitForFontsToLoad is exported by public API', () {
    // This will fail to compile if the function is not exported.
    expect(waitForFontsToLoad, isNotNull);
  });

  test('saveFile rejects path traversal and invalid file names', () async {
    for (final invalid in ['', '.', '..', '../secret.txt', r'..\secret.txt']) {
      await expectLater(
        saveFile(invalid, const [1, 2, 3]),
        throwsArgumentError,
        reason: 'Expected ArgumentError for basename="$invalid"',
      );
    }
  });
}
