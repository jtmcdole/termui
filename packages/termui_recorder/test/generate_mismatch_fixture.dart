import 'dart:io';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/style.dart';
import 'package:termui_recorder/termui_recorder.dart';

void main() {
  final expectedBuffer = Buffer.blank(30, 5);
  expectedBuffer.writeString(0, 0, '=== EXPECTED SCREEN ===', Style.empty);
  expectedBuffer.writeString(0, 2, 'Item 1: Active', Style.empty);
  expectedBuffer.writeString(0, 3, 'Item 2: Inactive', Style.empty);

  final actualBuffer = Buffer.blank(30, 5);
  actualBuffer.writeString(0, 0, '=== EXPECTED SCREEN ===', Style.empty);
  actualBuffer.writeString(0, 2, 'Item 1: FAILED', Style.empty); // Mismatch here
  actualBuffer.writeString(0, 3, 'Item 2: Active', Style.empty); // Mismatch here

  final fixtureDir = Directory('test/fixtures');
  if (!fixtureDir.existsSync()) {
    fixtureDir.createSync(recursive: true);
  }

  final goldenPath = 'test/fixtures/golden_mismatch_demo.ansi';
  final goldenFile = File(goldenPath);
  goldenFile.writeAsStringSync(AnsiScreenshot.capture(expectedBuffer));

  // Run the matcher, it will fail and write the files
  final matcher = matchesAnsiGolden(goldenPath);
  final state = {};
  final matched = matcher.matches(actualBuffer, state);
  print('Matched: $matched');
  print('Failure output:\n${state['failure']}');
}
