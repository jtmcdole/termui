@TestOn('chrome')
library;

import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:example_flutter/src/tui_player/trace_parser_web.dart';

void main() {
  test('Parses large trace without hanging', () async {
    final events = [];
    for (int i = 0; i < 66000; i++) {
      events.add({
        "name": "swapper",
        "ph": "X",
        "cat": "__metadata",
        "ts": 1234567890 + i,
        "dur": 100,
        "tid": 0,
        "args": {"a": 1, "b": "hello"},
      });
    }
    final jsonStr = jsonEncode({"traceEvents": events});
    final bytes = Uint8List.fromList(utf8.encode(jsonStr));

    final watch = Stopwatch()..start();
    final parsed = await parseTraceEvents(bytes, 'trace.json');
    watch.stop();

    expect(parsed.length, 66000);
    // ignore: avoid_print
    print('Parsed in \${watch.elapsedMilliseconds}ms');
    expect(
      watch.elapsedMilliseconds < 5000,
      true,
      reason: 'Parsing took too long',
    );
  });
}
