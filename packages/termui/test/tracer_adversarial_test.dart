import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:file/memory.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/ui/buffer.dart';
import 'package:termui/ui/widgets/core/widget.dart';
import 'package:termui/ui/widgets/core/element.dart';
import 'package:termui/ui/widgets/core/geometry.dart';

class AdversarialWidget extends Widget {
  int runtimeTypeAccessCount = 0;

  @override
  Type get runtimeType {
    runtimeTypeAccessCount++;
    return super.runtimeType;
  }

  @override
  Element createElement() => AdversarialElement(this);
}

class AdversarialElement extends Element {
  AdversarialElement(AdversarialWidget super.widget);

  @override
  void rebuild() {}

  @override
  Size performLayout(BoxConstraints constraints) => Size.zero;

  @override
  void performPaint(Buffer buffer, Offset offset) {}
}

void main() {
  group('Tracer Adversarial Tests', () {
    late String localTracePath;

    setUp(() async {
      await Tracer.initialize();
      localTracePath =
          '${Directory.current.path}${Platform.pathSeparator}adversarial_trace_${Random().nextInt(10000000)}.json';
    });

    tearDown(() async {
      await Tracer.stop();
      final file = File(localTracePath);
      if (await file.exists()) {
        await file.delete();
      }
    });

    test(
      'Performance Regression: runtimeType accessed when Tracer is disabled',
      () {
        final widget = AdversarialWidget();
        final element = widget.createElement();
        element.mount(null);

        // Verify initial state
        expect(widget.runtimeTypeAccessCount, 0);
        expect(Tracer.isEnabled, isFalse);

        // Trigger rebuild - this should NOT access runtimeType if tracing is disabled
        element.performRebuild();
        expect(
          widget.runtimeTypeAccessCount,
          0,
          reason: 'runtimeType should not be accessed when Tracer is disabled',
        );

        // Trigger paint - this should NOT access runtimeType if tracing is disabled
        final buffer = Buffer.blank(1, 1);
        element.paint(buffer, Offset.zero);
        expect(
          widget.runtimeTypeAccessCount,
          0,
          reason: 'runtimeType should not be accessed when Tracer is disabled',
        );
      },
    );

    test(
      'JSON Injection Vulnerability: special characters in registered strings break FileSystemSink JSON',
      () async {
        final memoryFs = MemoryFileSystem();
        final memTracePath = '/mem/adversarial_trace.json';

        // Start tracing with a string containing double quotes, backslashes, and newlines
        final maliciousStringId = Tracer.registerString(
          'My "malicious" \\ string\nwith newlines',
        );

        await Tracer.start(memTracePath, fs: memoryFs);
        Tracer.record(maliciousStringId, Phase.begin, TraceCategory.paint);
        await Tracer.stop();

        final file = memoryFs.file(memTracePath);
        expect(file.existsSync(), isTrue);

        final contents = file.readAsStringSync();

        // Attempt to decode the JSON - this will throw an exception if the format is invalid
        expect(
          () => jsonDecode(contents),
          returnsNormally,
          reason:
              'FileSystemSink output file should be valid JSON even when strings contain quotes or backslashes',
        );
      },
    );

    test(
      'JSON Injection Vulnerability: special characters in registered strings break IsolateSink JSON',
      () async {
        final maliciousStringId = Tracer.registerString(
          'My "malicious" \\ string\nwith newlines',
        );

        await Tracer.start(localTracePath);
        Tracer.record(maliciousStringId, Phase.begin, TraceCategory.paint);
        await Tracer.stop();

        final file = File(localTracePath);
        expect(await file.exists(), isTrue);

        final contents = await file.readAsString();

        // Attempt to decode the JSON - this will throw an exception if the format is invalid
        expect(
          () => jsonDecode(contents),
          returnsNormally,
          reason:
              'IsolateSink output file should be valid JSON even when strings contain quotes or backslashes',
        );
      },
    );
  });
}
