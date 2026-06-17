import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:file/memory.dart';
import 'package:termui/perf/tracer.dart';

void main() {
  group('Tracer Tests', () {
    late String traceFilePath;

    setUp(() async {
      traceFilePath =
          '${Directory.current.path}${Platform.pathSeparator}test_trace_${Random().nextInt(10000000)}.json';
      await Tracer.initialize();
      Tracer.activeCategories = {
        TraceCategory.paint,
        TraceCategory.layout,
        TraceCategory.events,
      };
    });

    tearDown(() async {
      await Tracer.stop();
      final file = File(traceFilePath);
      if (await file.exists()) {
        await file.delete();
      }
    });

    test('should record and serialize events correctly to JSON', () async {
      final drawFrameId = Tracer.registerString('drawFrame');
      final updateLayoutId = Tracer.registerString('updateLayout');

      // Start tracing
      await Tracer.start(traceFilePath);

      // Record some events
      Tracer.record(drawFrameId, Phase.begin, TraceCategory.paint);
      Tracer.record(updateLayoutId, Phase.instant, TraceCategory.layout);
      Tracer.record(drawFrameId, Phase.end, TraceCategory.paint);

      // Stop tracing to flush buffers and close file
      await Tracer.stop();

      // Verify file contents
      final file = File(traceFilePath);
      expect(await file.exists(), isTrue);

      final contents = await file.readAsString();
      expect(contents, startsWith('[\n'));
      expect(contents, endsWith('\n]\n'));

      // Parse as JSON
      final jsonList = jsonDecode(contents) as List<dynamic>;
      expect(jsonList.length, equals(3));

      // Verify first event (drawFrame begin)
      expect(jsonList[0]['name'], equals('drawFrame'));
      expect(jsonList[0]['ph'], equals('B'));
      expect(jsonList[0]['cat'], equals('TUI'));
      expect(jsonList[0]['pid'], equals(1));
      expect(jsonList[0]['ts'], isA<int>());

      // Verify second event (updateLayout instant)
      expect(jsonList[1]['name'], equals('updateLayout'));
      expect(jsonList[1]['ph'], equals('i'));

      // Verify third event (drawFrame end)
      expect(jsonList[2]['name'], equals('drawFrame'));
      expect(jsonList[2]['ph'], equals('E'));
    });

    test('should handle string registration after start', () async {
      await Tracer.start(traceFilePath);

      final dynamicEventId = Tracer.registerString('dynamicEvent');
      Tracer.record(dynamicEventId, Phase.begin, TraceCategory.events);
      Tracer.record(dynamicEventId, Phase.end, TraceCategory.events);

      await Tracer.stop();

      final file = File(traceFilePath);
      expect(await file.exists(), isTrue);

      final jsonList = jsonDecode(await file.readAsString()) as List<dynamic>;
      expect(jsonList.length, equals(2));
      expect(jsonList[0]['name'], equals('dynamicEvent'));
      expect(jsonList[0]['ph'], equals('B'));
    });

    test('should work with MemoryFileSystem', () async {
      final memoryFs = MemoryFileSystem();
      final memTracePath = '/mem/trace.json';

      final memEventId = Tracer.registerString('memEvent');

      await Tracer.start(memTracePath, fs: memoryFs);
      Tracer.record(memEventId, Phase.begin, TraceCategory.events);
      Tracer.record(memEventId, Phase.end, TraceCategory.events);
      await Tracer.stop();

      final file = memoryFs.file(memTracePath);
      expect(file.existsSync(), isTrue);

      final contents = file.readAsStringSync();
      expect(contents, startsWith('[\n'));
      expect(contents, endsWith('\n]\n'));

      final jsonList = jsonDecode(contents) as List<dynamic>;
      expect(jsonList.length, equals(2));
      expect(jsonList[0]['name'], equals('memEvent'));
      expect(jsonList[0]['ph'], equals('B'));
    });
  });
}
