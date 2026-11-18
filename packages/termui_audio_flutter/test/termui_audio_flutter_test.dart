import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termui_audio_flutter/src/ogg_xiph_detector.dart';
import 'package:termui_audio_flutter/src/ogg_xiph_file_reader.dart';
import 'package:termui_audio_flutter/termui_audio_flutter.dart';

final class _FakeAudioBuffer implements AudioBuffer {
  const _FakeAudioBuffer(this.hash);

  @override
  final int hash;
}

final class _FakeAudioBus implements AudioBus {
  _FakeAudioBus(this.id);

  @override
  final int id;

  double volume = 1.0;

  @override
  void setVolume(double value) {
    volume = value;
  }
}

final class _RecordingFlutterAudioEngine extends FlutterAudioEngine {
  _RecordingFlutterAudioEngine({super.visualizationIdleTimeout});

  final List<String> calls = [];
  final List<_FakeAudioBus> createdBuses = [];
  final List<int> destroyedBusIds = [];
  final List<(int busId, int filterId)> attachedFilters = [];
  final List<(int busId, int filterId, int paramId, double value)>
  filterParams = [];
  final List<(int busId, int voiceId)> annexedVoices = [];
  final List<bool> visualizationCalls = [];
  int disposeAudioDataCalls = 0;
  Float32List? nextWaveformSamples;
  bool throwOnAnnex = false;
  AudioBus? lastPlayedBus;
  bool? lastPlayedPaused;
  int _nextVoiceId = 1;
  int _nextBusId = 100;
  final Set<int> activeVoiceIds = {};

  @override
  bool get isInitialized => true;

  @override
  bool isVoiceActive(int voiceId) =>
      activeVoiceIds.contains(voiceId) || super.isVoiceActive(voiceId);

  @override
  AudioBus createBus() {
    final bus = _FakeAudioBus(_nextBusId++);
    createdBuses.add(bus);
    calls.add('createBus(${bus.id})');
    return bus;
  }

  @override
  void destroyBus(AudioBus bus) {
    destroyedBusIds.add(bus.id);
    calls.add('destroyBus(${bus.id})');
  }

  @override
  void attachFilterToBus(AudioBus bus, int filterId) {
    attachedFilters.add((bus.id, filterId));
    calls.add('attachFilter(bus:${bus.id}, ft:$filterId)');
  }

  @override
  void setFilterParameter(
    AudioBus bus,
    int filterId,
    int paramId,
    double value,
  ) {
    filterParams.add((bus.id, filterId, paramId, value));
    calls.add(
      'setFilterParam(bus:${bus.id}, ft:$filterId, pm:$paramId, v:$value)',
    );
  }

  @override
  void annexVoiceToBus(AudioBus bus, int voiceId) {
    if (throwOnAnnex) throw StateError('annex failed');
    annexedVoices.add((bus.id, voiceId));
    calls.add('annexVoice(bus:${bus.id}, voice:$voiceId)');
  }

  @override
  void setEngineRelativePlaySpeed(int voiceId, double speed) {
    calls.add('setEngineSpeed(voice:$voiceId, speed:$speed)');
  }

  @override
  void stop(AudioVoice voice) {
    activeVoiceIds.remove(voice.id);
    super.stop(voice);
  }

  @override
  void stopEngineVoice(int voiceId) {
    calls.add('stopEngineVoice(voice:$voiceId)');
  }

  @override
  AudioVoice play(
    AudioBuffer buffer, {
    bool loop = false,
    AudioBus? bus,
    bool paused = false,
  }) {
    lastPlayedBus = bus;
    lastPlayedPaused = paused;
    final id = _nextVoiceId++;
    activeVoiceIds.add(id);
    calls.add('play(hash:${buffer.hash}, bus:${bus?.id}, paused:$paused)');
    return AudioVoice(id, Completer<void>().future);
  }

  @override
  void seek(AudioVoice voice, Duration position) {
    calls.add('seek(voice:${voice.id}, ms:${position.inMilliseconds})');
  }

  @override
  void setPaused(AudioVoice voice, bool paused) {
    calls.add('setPaused(voice:${voice.id}, paused:$paused)');
  }

  @override
  void scheduleStop(AudioVoice voice, Duration duration) {
    calls.add('scheduleStop(voice:${voice.id}, ms:${duration.inMilliseconds})');
  }

  @override
  void setEngineVisualizationEnabled(bool enabled) {
    visualizationCalls.add(enabled);
    calls.add('setVisualizationEnabled($enabled)');
  }

  @override
  Float32List? readEngineWaveformSamples() => nextWaveformSamples;

  @override
  void disposeEngineAudioData() {
    disposeAudioDataCalls += 1;
    calls.add('disposeEngineAudioData');
  }

  final List<({int maxBufferSize, bool releaseConsumed, Duration buffering})>
  createdBufferStreams = [];
  final Map<int, BytesBuilder> streamedBytesByHash = {};
  final List<int> chunkSizes = [];
  final Set<int> endedBufferHashes = {};
  final List<int> disposedBufferHashes = [];
  final List<(String pathId, int length, bool stream)> engineMemLoads = [];
  final List<(String path, bool stream)> engineFileLoads = [];
  int? throwOnAddStreamChunkCall;
  int _addStreamChunkCalls = 0;
  int _nextBufferHash = 500;

  @override
  Future<AudioBuffer> createBufferStream({
    int maxBufferSize = 4 * 1024 * 1024,
    bool releaseConsumed = false,
    Duration bufferingTimeNeeds = const Duration(milliseconds: 500),
    int sampleRate = 48000,
    int channels = 2,
  }) async {
    final hash = _nextBufferHash++;
    createdBufferStreams.add((
      maxBufferSize: maxBufferSize,
      releaseConsumed: releaseConsumed,
      buffering: bufferingTimeNeeds,
    ));
    streamedBytesByHash[hash] = BytesBuilder(copy: false);
    calls.add('createBufferStream(hash:$hash)');
    return _FakeAudioBuffer(hash);
  }

  @override
  void addStreamData(AudioBuffer buffer, Uint8List chunk) {
    _addStreamChunkCalls += 1;
    if (throwOnAddStreamChunkCall == _addStreamChunkCalls) {
      throw StateError('addStreamData failed');
    }
    chunkSizes.add(chunk.length);
    streamedBytesByHash[buffer.hash]?.add(Uint8List.fromList(chunk));
    calls.add('addStreamData(hash:${buffer.hash}, len:${chunk.length})');
  }

  @override
  void setStreamEnded(AudioBuffer buffer) {
    endedBufferHashes.add(buffer.hash);
    calls.add('setStreamEnded(hash:${buffer.hash})');
  }

  @override
  Future<void> disposeBuffer(AudioBuffer buffer) async {
    disposedBufferHashes.add(buffer.hash);
    calls.add('disposeBuffer(hash:${buffer.hash})');
  }

  @override
  Future<AudioBuffer> loadEngineMem(
    String pathId,
    Uint8List bytes, {
    bool stream = false,
  }) async {
    final hash = _nextBufferHash++;
    engineMemLoads.add((pathId, bytes.length, stream));
    calls.add('loadEngineMem($pathId, len:${bytes.length}, stream:$stream)');
    return _FakeAudioBuffer(hash);
  }

  @override
  Future<AudioBuffer> loadEngineFile(String path, {bool stream = false}) async {
    final hash = _nextBufferHash++;
    engineFileLoads.add((path, stream));
    calls.add('loadEngineFile($path, stream:$stream)');
    return _FakeAudioBuffer(hash);
  }
}

Uint8List _buildOggPage(List<int> payload) {
  final fullSegments = payload.length ~/ 255;
  final remainder = payload.length % 255;
  final segments = <int>[...List<int>.filled(fullSegments, 255), remainder];
  return Uint8List.fromList([
    ...'OggS'.codeUnits,
    ...List<int>.filled(22, 0),
    segments.length,
    ...segments,
    ...payload,
  ]);
}

Uint8List _buildOggOpusBytes({int trailingAudioBytes = 64}) {
  final opusHead = <int>[...'OpusHead'.codeUnits, ...List<int>.filled(11, 0)];
  final audioPayload = List<int>.generate(
    trailingAudioBytes,
    (index) => index & 0xff,
  );
  return Uint8List.fromList([
    ..._buildOggPage(opusHead),
    ..._buildOggPage(audioPayload),
  ]);
}

Uint8List _buildOggFlacBytes() {
  final flacBos = <int>[
    0x7f,
    ...'FLAC'.codeUnits,
    0x01,
    0x00,
    0x00,
    0x01,
    ...'fLaC'.codeUnits,
    ...List<int>.filled(34, 0),
  ];
  return _buildOggPage(flacBos);
}

Uint8List _buildOggVorbisBytes() {
  final vorbisBos = <int>[
    0x01,
    ...'vorbis'.codeUnits,
    ...List<int>.filled(23, 0),
  ];
  return _buildOggPage(vorbisBos);
}

List<int> _extractPcmSamples(Uint8List wavBytes) {
  final bd = ByteData.sublistView(wavBytes, 44);
  final count = bd.lengthInBytes ~/ 2;
  return [for (var i = 0; i < count; i++) bd.getInt16(i * 2, Endian.little)];
}

void main() {
  group('TermuiAudioFlutter & FlutterAudioEngine', () {
    test(
      'TermuiAudioFlutter.register installs FlutterAudioEngine singleton',
      () {
        final registered = TermuiAudioFlutter.register();
        expect(registered, isA<FlutterAudioEngine>());
        expect(TermuiAudio.instance, same(registered));
      },
    );

    test(
      'setRelativePlaySpeed throws when uninitialized and manages per-voice pitch bus when preservePitch is true',
      () async {
        final uninit = FlutterAudioEngine();
        final uninitVoice = AudioVoice(42, Completer<void>().future);
        expect(
          () => uninit.setRelativePlaySpeed(
            uninitVoice,
            1.5,
            preservePitch: true,
          ),
          throwsA(isA<Exception>()),
        );

        final engine = _RecordingFlutterAudioEngine();
        final v1 = engine.play(const _FakeAudioBuffer(1));
        final v2 = engine.play(const _FakeAudioBuffer(2));
        final unknownVoice = AudioVoice(999, Completer<void>().future);
        final pitchFt = FilterType.pitchShift.index;

        // Ended or unknown voices must not allocate a pitch bus or mutate engine speed.
        engine.setRelativePlaySpeed(unknownVoice, 0.5, preservePitch: true);
        expect(engine.createdBuses, isEmpty);
        expect(
          engine.calls.where((c) => c.startsWith('setEngineSpeed(')),
          isEmpty,
        );

        // Non-finite or non-positive speed with preservePitch is ignored.
        engine.setRelativePlaySpeed(v1, 0.0, preservePitch: true);
        engine.setRelativePlaySpeed(v1, double.nan, preservePitch: true);
        expect(engine.createdBuses, isEmpty);

        // 0.5x speed allocates bus once, attaches pitchShift, annexes voice, and sets wet=1.0, shift=2.0.
        engine.setRelativePlaySpeed(v1, 0.5, preservePitch: true);
        expect(engine.createdBuses, hasLength(1));
        final b1 = engine.createdBuses.single;
        expect(engine.attachedFilters, equals([(b1.id, pitchFt)]));
        expect(engine.annexedVoices, equals([(b1.id, v1.id)]));
        expect(
          engine.filterParams,
          equals([(b1.id, pitchFt, 0, 1.0), (b1.id, pitchFt, 1, 2.0)]),
        );

        // 0.25x clamps shift=4.0 (> 3.0) via semitones (+24.0) without reallocating bus.
        engine.setRelativePlaySpeed(v1, 0.25, preservePitch: true);
        expect(engine.createdBuses, hasLength(1));
        expect(engine.filterParams.last.$3, equals(2));
        expect(engine.filterParams.last.$4, closeTo(24.0, 1e-6));

        // Near-1.0x speed bypasses pitchShiftFilter (wet=0.0, shift=1.0).
        engine.setRelativePlaySpeed(v1, 1.0005, preservePitch: true);
        expect(
          engine.filterParams.skip(engine.filterParams.length - 2),
          equals([(b1.id, pitchFt, 0, 0.0), (b1.id, pitchFt, 1, 1.0)]),
        );

        // Subsequent preservePitch: false also bypasses existing pitch bus without disposing mid-flight.
        engine.setRelativePlaySpeed(v1, 1.5, preservePitch: false);
        expect(engine.destroyedBusIds, isEmpty);
        expect(
          engine.filterParams.skip(engine.filterParams.length - 2),
          equals([(b1.id, pitchFt, 0, 0.0), (b1.id, pitchFt, 1, 1.0)]),
        );

        // stop(v1) disposes v1's pitch bus cleanly, and subsequent speed updates on v1 are ignored.
        engine.stop(v1);
        expect(engine.destroyedBusIds, equals([b1.id]));
        final busCountAfterStop = engine.createdBuses.length;
        engine.setRelativePlaySpeed(v1, 0.5, preservePitch: true);
        expect(engine.createdBuses.length, equals(busCountAfterStop));

        // Failed annex rolls back allocated pitch bus immediately.
        engine.throwOnAnnex = true;
        expect(
          () => engine.setRelativePlaySpeed(v2, 0.5, preservePitch: true),
          throwsStateError,
        );
        expect(engine.destroyedBusIds, hasLength(2));
        engine.throwOnAnnex = false;

        // dispose() cleans up any remaining voice pitch buses.
        engine.setRelativePlaySpeed(v2, 2.0, preservePitch: true);
        final b2 = engine.createdBuses.last;
        expect(engine.destroyedBusIds, isNot(contains(b2.id)));
        await engine.dispose();
        expect(engine.destroyedBusIds, contains(b2.id));

        // Base annexVoiceToBus no-ops safely for unregistered non-FlutterAudioBus handles.
        uninit.annexVoiceToBus(_FakeAudioBus(999), 1);
      },
    );

    test(
      'generateWaveformPcmWav produces distinct PCM samples for bounce, fsaw, fsquare vs triangle',
      () {
        final triangleSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.triangle, frequency: 440.0),
        );
        final bounceSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.bounce, frequency: 440.0),
        );
        final fsawSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.fsaw, frequency: 440.0),
        );
        final fsquareSamples = _extractPcmSamples(
          generateWaveformPcmWav(shape: WaveForm.fsquare, frequency: 440.0),
        );

        expect(triangleSamples, isNotEmpty);
        expect(bounceSamples, isNot(equals(triangleSamples)));
        expect(fsawSamples, isNot(equals(triangleSamples)));
        expect(fsquareSamples, isNot(equals(triangleSamples)));
        expect(bounceSamples, isNot(equals(fsawSamples)));
        expect(fsawSamples, isNot(equals(fsquareSamples)));
      },
    );

    test(
      'playSprite forwards AudioBus and seeks/unpauses/schedules stop in order',
      () {
        final engine = _RecordingFlutterAudioEngine();
        const buffer = _FakeAudioBuffer(77);
        final bus = _FakeAudioBus(9);

        final voice = engine.playSprite(
          buffer,
          bus: bus,
          start: const Duration(milliseconds: 120),
          duration: const Duration(milliseconds: 250),
        );

        expect(voice.id, equals(1));
        expect(engine.lastPlayedBus, same(bus));
        expect(engine.lastPlayedPaused, isTrue);
        expect(
          engine.calls,
          equals([
            'play(hash:77, bus:9, paused:true)',
            'seek(voice:1, ms:120)',
            'setPaused(voice:1, paused:false)',
            'scheduleStop(voice:1, ms:250)',
          ]),
        );
      },
    );

    test('dispose cancels pending playSpriteSequence timers cleanly', () {
      fakeAsync((async) {
        final engine = _RecordingFlutterAudioEngine();
        const buffer = _FakeAudioBuffer(88);
        final bus = _FakeAudioBus(3);

        unawaited(
          engine.playSpriteSequence(buffer, const [
            SpriteSegment(
              start: Duration.zero,
              duration: Duration(milliseconds: 80),
            ),
            SpriteSegment(
              start: Duration(milliseconds: 80),
              duration: Duration(milliseconds: 80),
            ),
          ], bus: bus),
        );

        // First segment starts immediately; second segment is scheduled on a tracked timer.
        expect(engine.calls.first, equals('play(hash:88, bus:3, paused:true)'));

        unawaited(engine.dispose());
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 120));

        // Second segment must not fire after dispose() cancels tracked timers.
        expect(
          engine.calls.where((c) => c.startsWith('play(')).length,
          equals(1),
        );
      });
    });

    test('setVoicePan throws when engine is not initialized', () async {
      final engine = FlutterAudioEngine();
      final voice = AudioVoice(7, Completer<void>().future);

      expect(() => engine.setVoicePan(voice, -0.5), throwsA(isA<Exception>()));
      engine.disposeEngineAudioData();
      await engine.dispose();
    });

    test(
      'lazily enables visualization on first waveform read, disables after idle timeout, and supports fetchWaveform/watchWaveform',
      () {
        fakeAsync((async) {
          final engine =
              _RecordingFlutterAudioEngine(
                  visualizationIdleTimeout: const Duration(milliseconds: 120),
                )
                ..nextWaveformSamples = Float32List.fromList(
                  List<double>.generate(256, (i) => i / 256.0),
                );

          expect(engine.visualizationCalls, isEmpty);
          expect(
            () => engine.getWaveform(Float32List(16)),
            throwsArgumentError,
          );

          // First read enables visualization lazily.
          final first = engine.getWaveform();
          expect(first[128], closeTo(0.5, 1e-6));
          expect(engine.visualizationCalls, equals([true]));

          // Read again before idle timeout resets the timer.
          async.elapse(const Duration(milliseconds: 70));
          expect(engine.visualizationCalls, equals([true]));
          Float32List? fetched;
          unawaited(engine.fetchWaveform().then((v) => fetched = v));
          async.flushMicrotasks();
          expect(fetched![128], closeTo(0.5, 1e-6));
          expect(engine.visualizationCalls, equals([true]));

          // Still active before full idle timeout elapses after second read.
          async.elapse(const Duration(milliseconds: 70));
          expect(engine.visualizationCalls, equals([true]));
          expect(engine.disposeAudioDataCalls, equals(0));

          // After full idle timeout since last read: visualization disables & AudioData disposes.
          async.elapse(const Duration(milliseconds: 80));
          expect(engine.visualizationCalls, equals([true, false]));
          expect(engine.disposeAudioDataCalls, equals(1));

          // Next read re-enables visualization.
          engine.getWaveform();
          expect(engine.visualizationCalls, equals([true, false, true]));

          // watchWaveform polls (clamped to >=50ms) and closes cleanly on dispose().
          final watched = <Float32List>[];
          var watchClosed = false;
          final sub = engine
              .watchWaveform(interval: const Duration(milliseconds: 20))
              .listen(watched.add, onDone: () => watchClosed = true);
          async.elapse(const Duration(milliseconds: 130));
          expect(watched, hasLength(2));

          unawaited(engine.dispose());
          async.flushMicrotasks();
          expect(watchClosed, isTrue);
          unawaited(sub.cancel());
          async.flushMicrotasks();
        });
      },
    );

    test(
      'isOggXiphBytes distinguishes Ogg Opus and Ogg FLAC from Ogg Vorbis, WAV, and malformed headers',
      () async {
        expect(isOggXiphBytes(_buildOggOpusBytes()), isTrue);
        expect(isOggXiphBytes(_buildOggFlacBytes()), isTrue);

        // Chained/preceding Ogg page (e.g. Skeleton fishead) followed by OpusHead.
        final chained = Uint8List.fromList([
          ..._buildOggPage([
            ...'fishead\x00'.codeUnits,
            ...List<int>.filled(56, 0),
          ]),
          0xff, // non-page sync byte skipped cleanly
          ..._buildOggOpusBytes(trailingAudioBytes: 16),
        ]);
        expect(isOggXiphBytes(chained), isTrue);

        // Real Kenney CC0 Ogg Opus example asset from termui_audio/example/assets.
        final swishBytes = await File(
          '../termui_audio/example/assets/kenney_swish1.ogg',
        ).readAsBytes();
        expect(isOggXiphBytes(swishBytes), isTrue);

        // Non-Xiph formats and malformed Ogg containers return false.
        expect(isOggXiphBytes(_buildOggVorbisBytes()), isFalse);
        expect(
          isOggXiphBytes(
            generateWaveformPcmWav(shape: WaveForm.triangle, frequency: 440.0),
          ),
          isFalse,
        );
        expect(isOggXiphBytes(Uint8List(0)), isFalse);
        expect(isOggXiphBytes(Uint8List.fromList('OggS'.codeUnits)), isFalse);

        // Truncated segment table and truncated page payload return false safely.
        final truncatedSegTable = Uint8List.fromList([
          ...'OggS'.codeUnits,
          ...List<int>.filled(22, 0),
          20, // claims 20 segments, only 8 bytes follow
          ...List<int>.filled(8, 255),
        ]);
        expect(isOggXiphBytes(truncatedSegTable), isFalse);

        final truncatedPayload = Uint8List.fromList([
          ...'OggS'.codeUnits,
          ...List<int>.filled(22, 0),
          1,
          50, // claims 50-byte payload, only 8 bytes follow
          ...'OpusHead'.codeUnits,
        ]);
        expect(isOggXiphBytes(truncatedPayload), isFalse);
      },
    );

    test(
      'readOggXiphFileBytes reads small and >64 KiB Ogg Xiph files and returns null for Vorbis, short, or missing files',
      () async {
        final tempDir = await Directory.systemTemp.createTemp(
          'termui_audio_flutter_ogg_test_',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final smallOpus = _buildOggOpusBytes(trailingAudioBytes: 512);
        final smallPath = '${tempDir.path}/small.ogg';
        await File(smallPath).writeAsBytes(smallOpus);
        expect(await readOggXiphFileBytes(smallPath), equals(smallOpus));

        final largeOpus = _buildOggOpusBytes(trailingAudioBytes: 90 * 1024);
        final largePath = '${tempDir.path}/large.ogg';
        await File(largePath).writeAsBytes(largeOpus);
        expect(await readOggXiphFileBytes(largePath), equals(largeOpus));

        final vorbisPath = '${tempDir.path}/vorbis.ogg';
        await File(vorbisPath).writeAsBytes(_buildOggVorbisBytes());
        expect(await readOggXiphFileBytes(vorbisPath), isNull);

        final tinyPath = '${tempDir.path}/tiny.ogg';
        await File(tinyPath).writeAsBytes(const [1, 2, 3, 4]);
        expect(await readOggXiphFileBytes(tinyPath), isNull);

        expect(
          await readOggXiphFileBytes('${tempDir.path}/missing.ogg'),
          isNull,
        );
      },
    );

    test(
      'loadMem routes Ogg Opus and Ogg FLAC through preserved BufferStream chunks, rolls back on error, and keeps native loadMem for other codecs',
      () async {
        final uninit = FlutterAudioEngine();
        expect(
          () => uninit.loadMem('swish.ogg', _buildOggOpusBytes()),
          throwsA(isA<Exception>()),
        );

        final engine = _RecordingFlutterAudioEngine();
        final swishBytes = await File(
          '../termui_audio/example/assets/kenney_swish1.ogg',
        ).readAsBytes();

        // Short Ogg Opus clip (kenney_swish1.ogg) bypasses native loadMem (which hits MBOggDecoder::readOpus EOF bug).
        final swishBuffer = await engine.loadMem(
          'kenney_swish1.ogg',
          swishBytes,
        );
        expect(engine.engineMemLoads, isEmpty);
        expect(engine.createdBufferStreams, hasLength(1));
        expect(
          engine.createdBufferStreams.single,
          equals((
            maxBufferSize: 512 * 1024 * 1024,
            releaseConsumed: false,
            buffering: Duration.zero,
          )),
        );
        expect(
          engine.streamedBytesByHash[swishBuffer.hash]?.toBytes(),
          equals(swishBytes),
        );
        expect(engine.endedBufferHashes, contains(swishBuffer.hash));

        // Multi-chunk (> 128 KiB) Ogg Opus stream slices into 128 KiB chunks and preserves exact byte order.
        final multiChunkOpus = _buildOggOpusBytes(
          trailingAudioBytes: 300 * 1024,
        );
        final largeBuffer = await engine.loadMem(
          'large.opus',
          multiChunkOpus,
          stream: true,
        );
        expect(engine.engineMemLoads, isEmpty);
        expect(
          engine.chunkSizes.skip(1),
          everyElement(lessThanOrEqualTo(128 * 1024)),
        );
        expect(
          engine.streamedBytesByHash[largeBuffer.hash]?.toBytes(),
          equals(multiChunkOpus),
        );
        expect(engine.endedBufferHashes, contains(largeBuffer.hash));

        // Non-Xiph formats (Ogg Vorbis, WAV) continue calling loadEngineMem directly.
        final vorbisBytes = _buildOggVorbisBytes();
        await engine.loadMem('track.ogg', vorbisBytes, stream: true);
        expect(
          engine.engineMemLoads,
          equals([('track.ogg', vorbisBytes.length, true)]),
        );

        // Error during chunk feed disposes the partially initialized BufferStream cleanly.
        final failingEngine = _RecordingFlutterAudioEngine()
          ..throwOnAddStreamChunkCall = 2;
        await expectLater(
          () => failingEngine.loadMem('broken.opus', multiChunkOpus),
          throwsStateError,
        );
        expect(failingEngine.disposedBufferHashes, hasLength(1));
        expect(failingEngine.endedBufferHashes, isEmpty);
      },
    );

    test(
      'loadFile routes Ogg Opus files through preserved BufferStream with progress updates and delegates non-Xiph files to native loadFile',
      () async {
        final uninit = FlutterAudioEngine();
        expect(() => uninit.loadFile('missing.wav'), throwsA(isA<Exception>()));

        final tempDir = await Directory.systemTemp.createTemp(
          'termui_audio_flutter_load_file_',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final multiChunkOpus = _buildOggOpusBytes(
          trailingAudioBytes: 200 * 1024,
        );
        final opusFile = File('${tempDir.path}/clip.ogg');
        await opusFile.writeAsBytes(multiChunkOpus);

        final engine = _RecordingFlutterAudioEngine();
        final opusProgress = <double>[];
        final opusBuffer = await engine.loadFile(
          opusFile.path,
          onProgress: opusProgress.add,
        );
        expect(engine.engineFileLoads, isEmpty);
        expect(
          engine.streamedBytesByHash[opusBuffer.hash]?.toBytes(),
          equals(multiChunkOpus),
        );
        expect(engine.endedBufferHashes, contains(opusBuffer.hash));
        expect(opusProgress.first, closeTo(0.1, 1e-6));
        expect(opusProgress.length, greaterThan(2));
        expect(opusProgress.last, closeTo(1.0, 1e-6));

        final wavFile = File('${tempDir.path}/tone.wav');
        await wavFile.writeAsBytes(
          generateWaveformPcmWav(shape: WaveForm.triangle, frequency: 440.0),
        );
        final wavProgress = <double>[];
        await engine.loadFile(
          wavFile.path,
          stream: true,
          onProgress: wavProgress.add,
        );
        expect(engine.engineFileLoads, equals([(wavFile.path, true)]));
        expect(wavProgress, equals([0.1, 1.0]));
      },
    );
  });
}
