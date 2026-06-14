import 'package:termui/ui/ui.dart' show Buffer, Offset;
import 'package:test/test.dart';
import 'package:termui_recorder/termui_recorder.dart';

import 'finders.dart';
import 'tester.dart';

/// Extension to seamlessly integrate `TerminalTester` with `package:test` matchers.
extension TerminalTesterExpectations on TerminalTester {
  /// Asserts that a finder matches the expected outcome.
  /// If it fails, dumps a high-fidelity ANSI screenshot to the console.
  void expectUI(Finder finder, Matcher matcher, {String? reason}) {
    try {
      expect(finder, matcher, reason: reason);
    } on TestFailure {
      print('\n\x1b[31m====== TERMUI TEST FAILURE ======\x1b[0m');
      print('\x1b[33mFAILED FINDER:\x1b[0m $finder');

      print(screenshot());

      print('\x1b[31m=================================\x1b[0m\n');

      // Rethrow to let package:test register the failure
      rethrow;
    }
  }

  /// Take a screenshot of the current buffer.
  String screenshot() {
    final sb = StringBuffer();
    sb.writeln('\n\x1b[36m--- TERMINAL SCREENSHOT ${backend.size} ---\x1b[0m');

    // Dump the visual buffer
    final activeBuffer = buffer ?? _generateSnapshotBuffer();
    sb.writeln(AnsiScreenshot.capture(activeBuffer));

    // If you want to dump the element tree, you can add that here too!
    // print('\n\x1b[36m--- ELEMENT TREE ---\x1b[0m');
    // print(dumpTree());

    sb.writeln('\n\x1b[36m--- END TERMINAL SCREENSHOT ---\x1b[0m');

    return '$sb';
  }

  /// Forces the current element tree to paint into a fresh buffer for debugging.
  Buffer _generateSnapshotBuffer() {
    // 1. Grab your terminal's known dimensions
    final w = backend.size.x > 0 ? backend.size.x : 80;
    final h = backend.size.y > 0 ? backend.size.y : 24;

    // 2. Create a blank canvas
    final snapshot = Buffer(w, h);

    // 3. Find your root element (your tester likely has a reference to this)
    // For example: tester.rootElement, runner.root, or similar
    final root = rootElement;

    if (root != null) {
      // 4. Force the tree to paint exactly as it exists right now
      root.paint(snapshot, Offset.zero);
    }

    return snapshot;
  }
}
