import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:file/memory.dart';
import 'package:file/local.dart';
import 'package:termui/perf/tracer.dart';
import 'package:termui/ui/layout.dart';
import 'package:termui/ui/buffer.dart';

class SpyingWidget extends Widget {
  static int runtimeTypeAccessCount = 0;

  const SpyingWidget({super.key});

  @override
  Type get runtimeType {
    runtimeTypeAccessCount++;
    return SpyingWidget;
  }
}

void main() {
  group('Adversarial Framework Tracing & Metadata Tests', () {
    setUp(() async {
      await Tracer.initialize();
      SpyingWidget.runtimeTypeAccessCount = 0;
    });

    tearDown(() async {
      await Tracer.stop();
    });

    test(
      'Performance Regression: runtimeType is accessed when tracing is disabled',
      () {
        // Ensure tracing is disabled
        Tracer.isEnabled = false;
        expect(Tracer.isEnabled, isFalse);

        final widget = SpyingWidget();
        final element = widget.createElement();
        element.mount(null);

        // Perform rebuild and paint
        element.performRebuild();
        final buffer = Buffer.blank(10, 1);
        element.paint(buffer, Offset.zero);

        element.unmount();

        // If the tracing overhead is properly guarded when disabled,
        // runtimeType should never be accessed.
        expect(
          SpyingWidget.runtimeTypeAccessCount,
          equals(0),
          reason:
              'runtimeType should not be accessed when tracing is disabled, otherwise it causes performance regressions',
        );
      },
    );

    test(
      'JSON Compliance (FileSystemSink): special characters in registered strings break JSON parsing',
      () async {
        final memoryFs = MemoryFileSystem();
        const memTracePath = '/mem/trace_adversarial.json';

        // Register a string with JSON-violating characters
        final stringId = Tracer.registerString(
          'Widget"Name\\With\\Quotes\nNewline\tTab',
        );

        await Tracer.start(memTracePath, fs: memoryFs);
        Tracer.record(stringId, Phase.begin, TraceCategory.paint);
        await Tracer.stop();

        final file = memoryFs.file(memTracePath);
        expect(file.existsSync(), isTrue);

        final contents = file.readAsStringSync();

        // Verify that it is valid JSON
        expect(
          () => jsonDecode(contents),
          returnsNormally,
          reason:
              'FileSystemSink tracing output must be fully valid JSON even when strings contain quotes, backslashes, or newlines',
        );
      },
    );

    test(
      'JSON Compliance (IsolateSink): special characters in registered strings break JSON parsing',
      () async {
        final localFs = LocalFileSystem();
        final tempTracePath =
            '${Directory.current.path}${Platform.pathSeparator}test_trace_adversarial.json';
        final tempFile = File(tempTracePath);
        if (tempFile.existsSync()) {
          tempFile.deleteSync();
        }

        try {
          // Register a string with JSON-violating characters
          final stringId = Tracer.registerString(
            'Widget"Name\\With\\Quotes\nNewline\tTab',
          );

          await Tracer.start(tempTracePath, fs: localFs);
          Tracer.record(stringId, Phase.begin, TraceCategory.paint);
          await Tracer.stop();

          expect(tempFile.existsSync(), isTrue);

          final contents = tempFile.readAsStringSync();

          // Verify that it is valid JSON
          expect(
            () => jsonDecode(contents),
            returnsNormally,
            reason:
                'IsolateSink tracing output must be fully valid JSON even when strings contain quotes, backslashes, or newlines',
          );
        } finally {
          if (tempFile.existsSync()) {
            tempFile.deleteSync();
          }
        }
      },
    );
  });
}
