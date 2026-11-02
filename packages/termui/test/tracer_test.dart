import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:test/test.dart';
import 'package:file/memory.dart';
import 'package:termui/perf/isolate_sink.dart';
import 'package:termui/perf/tracer.dart';

void main() {
  group('Tracer Cold Start & IsolateSink Error Resilience', () {
    test('Tracer.start works without prior Tracer.initialize()', () async {
      final memoryFs = MemoryFileSystem();
      const coldTracePath = '/cold/trace.json';
      final eventId = Tracer.registerString('coldStartEvent');

      await Tracer.start(coldTracePath, fs: memoryFs);
      Tracer.record(eventId, Phase.begin, TraceCategory.paint);
      Tracer.record(eventId, Phase.end, TraceCategory.paint);
      await Tracer.stop();

      final contents = utf8.decode(
        memoryFs.file(coldTracePath).readAsBytesSync(),
      );
      final jsonList = [
        for (final e in jsonDecode(contents) as List<Object?>)
          e as Map<String, Object?>,
      ];
      expect(jsonList, hasLength(2));
      expect(jsonList[0]['name'], equals('coldStartEvent'));
      expect(jsonList[0]['ph'], equals('B'));
      expect(jsonList[1]['ph'], equals('E'));
    });

    test(
      'IsolateSink closes cleanly without hanging when opening target path fails',
      () async {
        // Passing an existing directory path as the file path forces openSync to fail.
        final sink = IsolateSink(Directory.systemTemp.path, 0);
        final word0 = (1 << 32) | (1 << 8) | Phase.begin;
        sink.add([word0, 42], ['FailedOpenEvent']);

        await expectLater(
          sink.close().timeout(const Duration(seconds: 5)),
          completes,
        );
      },
    );

    test(
      'IsolateSink accepts non-TypedData List<int> buffers after initialization',
      () async {
        final tempPath =
            '${Directory.systemTemp.path}${Platform.pathSeparator}isolate_list_${Random().nextInt(10000000)}.json';
        final sink = IsolateSink(tempPath, 0);
        try {
          // Allow background isolate initialization to complete so _sendData runs directly.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          final word0 = (1 << 32) | (1 << 8) | Phase.instant;
          sink.add(<int>[word0, 100], ['PlainListEvent']);
          await sink.close();

          final contents = utf8.decode(await File(tempPath).readAsBytes());
          final jsonList = [
            for (final e in jsonDecode(contents) as List<Object?>)
              e as Map<String, Object?>,
          ];
          expect(jsonList, hasLength(1));
          expect(jsonList[0]['name'], equals('PlainListEvent'));
        } finally {
          final f = File(tempPath);
          if (await f.exists()) {
            await f.delete();
          }
        }
      },
    );
  });

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

      final contents = utf8.decode(await file.readAsBytes());
      expect(contents, startsWith('[\n'));
      expect(contents, endsWith('\n]\n'));

      // Parse as JSON
      final jsonList = [
        for (final e in jsonDecode(contents) as List<Object?>)
          e as Map<String, Object?>,
      ];
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

      final jsonList = [
        for (final e
            in jsonDecode(utf8.decode(await file.readAsBytes()))
                as List<Object?>)
          e as Map<String, Object?>,
      ];
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

      final contents = utf8.decode(file.readAsBytesSync());
      expect(contents, startsWith('[\n'));
      expect(contents, endsWith('\n]\n'));

      final jsonList = [
        for (final e in jsonDecode(contents) as List<Object?>)
          e as Map<String, Object?>,
      ];
      expect(jsonList.length, equals(2));
      expect(jsonList[0]['name'], equals('memEvent'));
      expect(jsonList[0]['ph'], equals('B'));
    });

    test(
      'should record and serialize event metadata correctly for IsolateSink',
      () async {
        final localEventId = Tracer.registerString('localEvent');
        await Tracer.start(traceFilePath);
        Tracer.record(
          localEventId,
          Phase.begin,
          TraceCategory.paint,
          metadata: {'key': 'value'},
        );
        await Tracer.stop();

        final localFile = File(traceFilePath);
        expect(await localFile.exists(), isTrue);
        final localContents = utf8.decode(await localFile.readAsBytes());
        final localJsonList = [
          for (final e in jsonDecode(localContents) as List<Object?>)
            e as Map<String, Object?>,
        ];
        expect(localJsonList.length, equals(1));
        expect(localJsonList[0]['name'], equals('localEvent'));
        final localArgs = localJsonList[0]['args'] as Map<String, Object?>?;
        expect(localArgs, isNotNull);
        expect(localArgs!['key'], equals('value'));
      },
    );

    test(
      'should record and serialize event metadata correctly for FileSystemSink',
      () async {
        final memoryFs = MemoryFileSystem();
        final memTracePath = '/mem/trace_meta.json';
        final memEventId = Tracer.registerString('memEvent');
        await Tracer.start(memTracePath, fs: memoryFs);
        Tracer.record(
          memEventId,
          Phase.begin,
          TraceCategory.paint,
          metadata: {'foo': 'bar'},
        );
        await Tracer.stop();

        final memFile = memoryFs.file(memTracePath);
        expect(memFile.existsSync(), isTrue);
        final memContents = utf8.decode(memFile.readAsBytesSync());
        final memJsonList = [
          for (final e in jsonDecode(memContents) as List<Object?>)
            e as Map<String, Object?>,
        ];
        expect(memJsonList.length, equals(1));
        expect(memJsonList[0]['name'], equals('memEvent'));
        final memArgs = memJsonList[0]['args'] as Map<String, Object?>?;
        expect(memArgs, isNotNull);
        expect(memArgs!['foo'], equals('bar'));
      },
    );

    test(
      'Adversarial Metadata: special characters and strings in metadata map',
      () async {
        final eventId = Tracer.registerString('adversarialMetaEvent');
        await Tracer.start(traceFilePath);

        Tracer.record(
          eventId,
          Phase.begin,
          TraceCategory.paint,
          metadata: {
            'closureString': (() => 'hello').toString(),
            'weird': '{"nested": "value", "quote": "\\""}',
            'newline': 'a\nb',
          },
        );
        await Tracer.stop();

        final file = File(traceFilePath);
        expect(await file.exists(), isTrue);
        final contents = utf8.decode(await file.readAsBytes());
        expect(() => jsonDecode(contents), returnsNormally);
      },
    );
  });
}
