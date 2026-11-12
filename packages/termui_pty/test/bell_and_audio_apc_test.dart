import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:termui_pty/termui_pty.dart';
import 'package:test/test.dart';

List<String> _encodeChunkedClipApc({
  required int clipId,
  required String format,
  required Uint8List bytes,
  double volume = 1.0,
  double pan = 0.0,
  bool loop = false,
  int chunkSize = 4096,
}) {
  final b64 = base64Encode(bytes);
  final loopFlag = loop ? 1 : 0;
  final frames = <String>[];
  for (var offset = 0; offset < b64.length; offset += chunkSize) {
    final end = math.min(offset + chunkSize, b64.length);
    final chunk = b64.substring(offset, end);
    final more = end < b64.length ? 1 : 0;
    if (offset == 0) {
      frames.add(
        '\x1b_Aa=clip,i=$clipId,fmt=$format,v=$volume,p=$pan,'
        'l=$loopFlag,m=$more;$chunk\x1b\\',
      );
    } else {
      frames.add('\x1b_Ai=$clipId,m=$more;$chunk\x1b\\');
    }
  }
  return frames;
}

void main() {
  group('VirtualTerminal BEL and Audio APC', () {
    test(
      'BEL dispatches onBell without dirtying cells or invoking buffer listeners',
      () {
        var bellCount = 0;
        var listenerCalls = 0;
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onBell: () => bellCount++,
        )..addListener(() => listenerCalls++);

        vt.writeString('ABC');
        expect(listenerCalls, equals(1));
        expect(bellCount, equals(0));

        // Standalone BEL fires onBell without triggering buffer listener.
        vt.writeString('\x07');
        expect(bellCount, equals(1));
        expect(listenerCalls, equals(1));
        expect(vt.cursorX, equals(3));

        // BEL inside synchronized output mode still fires onBell cleanly.
        vt.writeString('\x1b[?2026h\x07\x1b[?2026l');
        expect(bellCount, equals(2));

        // BEL terminating an OSC sequence must NOT trigger onBell.
        vt.writeString('\x1b]2;Shell Title\x07');
        expect(bellCount, equals(2));
        expect(vt.windowTitle, equals('Shell Title'));
        vt.dispose();
      },
    );

    test(
      'Audio APC decodes tone, stop, and normalized sine without dirtying screen',
      () {
        final events = <TerminalAudioEvent>[];
        var listenerCalls = 0;
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onAudioEvent: events.add,
        )..addListener(() => listenerCalls++);

        vt.writeString(
          '\x1b_Aa=tone,w=sine,f=440,d=250,v=0.8,p=-0.25;\x1b\\'
          '\x1b_Aa=tone,w=sin,f=880,d=100,v=2.0,p=-3.0;\x1b\\'
          '\x1b_Aa=stop,i=7;\x1b\\'
          '\x1b_Aa=stop;\x1b\\',
        );

        expect(listenerCalls, equals(0));
        expect(events, hasLength(4));
        expect(
          events[0],
          equals(
            const TerminalToneAudioEvent(
              waveform: 'sine',
              frequencyHz: 440.0,
              duration: Duration(milliseconds: 250),
              volume: 0.8,
              pan: -0.25,
            ),
          ),
        );
        expect(
          events[1],
          equals(
            const TerminalToneAudioEvent(
              waveform: 'sine',
              frequencyHz: 880.0,
              duration: Duration(milliseconds: 100),
              volume: 1.0,
              pan: -1.0,
            ),
          ),
        );
        expect(events[2], equals(const TerminalStopAudioEvent(clipId: 7)));
        expect(events[3], equals(const TerminalStopAudioEvent()));
        vt.dispose();
      },
    );

    test(
      'round-trips 2 MiB chunked clip upload (4096-char frames) without cell dirtying',
      () {
        final events = <TerminalAudioEvent>[];
        var listenerCalls = 0;
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onAudioEvent: events.add,
        )..addListener(() => listenerCalls++);

        final payload = Uint8List.fromList([
          for (var i = 0; i < AudioApcHandler.maxClipBytes; i++) i & 0xFF,
        ]);
        final frames = _encodeChunkedClipApc(
          clipId: 12,
          format: 'ogg',
          bytes: payload,
          volume: 0.65,
          pan: 0.4,
          loop: true,
        );
        for (final frame in frames) {
          vt.writeString(frame);
        }

        expect(listenerCalls, equals(0));
        expect(events, hasLength(1));
        final clip = events.single as TerminalClipAudioEvent;
        expect(clip.clipId, equals(12));
        expect(clip.format, equals('ogg'));
        expect(clip.volume, equals(0.65));
        expect(clip.pan, equals(0.4));
        expect(clip.loop, isTrue);
        expect(clip.bytes, equals(payload));
        vt.dispose();
      },
    );

    test(
      'rejects > 2 MiB clip upload cleanly while keeping parser healthy',
      () {
        final events = <TerminalAudioEvent>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onAudioEvent: events.add,
        );

        final oversized = Uint8List(AudioApcHandler.maxClipBytes + 1);
        for (final frame in _encodeChunkedClipApc(
          clipId: 99,
          format: 'wav',
          bytes: oversized,
        )) {
          vt.writeString(frame);
        }
        expect(events, isEmpty);

        // Valid event afterward still parses cleanly.
        vt.writeString('\x1b_Aa=tone,w=sine,f=523.25,d=50;\x1b\\');
        expect(events, hasLength(1));
        expect(events.single, isA<TerminalToneAudioEvent>());
        vt.dispose();
      },
    );

    test('enforces max 8 concurrent uploads by evicting oldest pending ID', () {
      final events = <TerminalAudioEvent>[];
      final handler = AudioApcHandler(onAudioEvent: events.add);

      for (var id = 1; id <= 9; id++) {
        handler.handleApc('Aa=clip,i=$id,fmt=wav,m=1;AQID');
      }
      expect(handler.pendingUploadCount, equals(8));

      // Upload 1 was evicted when upload 9 started.
      handler.handleApc('Ai=1,m=0;BAUG');
      expect(events, isEmpty);

      for (var id = 2; id <= 9; id++) {
        handler.handleApc('Ai=$id,m=0;BAUG');
      }
      expect(events, hasLength(8));
    });

    test('RIS (ESC c) and dispose reset pending chunked audio uploads', () {
      final events = <TerminalAudioEvent>[];
      final vt = VirtualTerminal(
        width: 20,
        height: 5,
        onAudioEvent: events.add,
      );

      // Begin partial upload, then trigger RIS full reset.
      vt.writeString('\x1b_Aa=clip,i=55,fmt=mp3,m=1;AQID\x1b\\');
      vt.writeString('\x1bc');
      vt.writeString('\x1b_Ai=55,m=0;BAUG\x1b\\');
      expect(events, isEmpty);

      // Begin partial upload, then call dispose().
      vt.writeString('\x1b_Aa=clip,i=56,fmt=mp3,m=1;AQID\x1b\\');
      vt.dispose();
      vt.writeString('\x1b_Ai=56,m=0;BAUG\x1b\\');
      expect(events, isEmpty);
    });

    test(
      'clamps extreme tone duration and frequency before microsecond conversion',
      () {
        final events = <TerminalAudioEvent>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onAudioEvent: events.add,
        );
        addTearDown(vt.dispose);

        vt.writeString(
          '\x1b_Aa=tone,w=sine,f=1e308,d=1e308;\x1b\\'
          '\x1b_Aa=tone,w=sine,f=5,d=50;\x1b\\',
        );

        expect(
          events,
          equals([
            const TerminalToneAudioEvent(
              waveform: 'sine',
              frequencyHz: 20000.0,
              duration: Duration(seconds: 10),
            ),
            const TerminalToneAudioEvent(
              waveform: 'sine',
              frequencyHz: 20.0,
              duration: Duration(milliseconds: 50),
            ),
          ]),
        );
      },
    );

    test(
      'alternate screen transitions reset pending chunked audio uploads',
      () {
        final events = <TerminalAudioEvent>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onAudioEvent: events.add,
        );
        addTearDown(vt.dispose);

        vt.writeString('\x1b_Aa=clip,i=71,fmt=mp3,m=1;AQID\x1b\\');
        vt.writeString('\x1b[?1049h');
        vt.writeString('\x1b_Ai=71,m=0;BAUG\x1b\\');
        expect(events, isEmpty);

        vt.writeString('\x1b_Aa=clip,i=72,fmt=mp3,m=1;AQID\x1b\\');
        vt.writeString('\x1b[?1049l');
        vt.writeString('\x1b_Ai=72,m=0;BAUG\x1b\\');
        expect(events, isEmpty);
      },
    );

    test(
      'rejects invalid or out-of-range explicit clip IDs without aliasing auto-ID or stop-all',
      () {
        final events = <TerminalAudioEvent>[];
        final handler = AudioApcHandler(onAudioEvent: events.add);

        // Invalid / out-of-range explicit stop IDs must be ignored, not stop-all.
        handler.handleApc('Aa=stop,i=0;');
        handler.handleApc('Aa=stop,i=-3;');
        handler.handleApc('Aa=stop,i=4294967296;');
        handler.handleApc('Aa=stop,i=2147483648;');
        handler.handleApc('Aa=stop,i=bad;');
        expect(events, isEmpty);

        // Omitted i= on stop still emits global stop-all.
        handler.handleApc('Aa=stop;');
        expect(events, equals([const TerminalStopAudioEvent()]));
        events.clear();

        // Invalid / out-of-range explicit clip IDs must be ignored.
        handler.handleApc('Aa=clip,i=0,fmt=wav,m=0;AQID');
        handler.handleApc('Aa=clip,i=4294967296,fmt=wav,m=0;AQID');
        handler.handleApc('Aa=clip,i=2147483648,fmt=wav,m=0;AQID');
        handler.handleApc('Aa=clip,i=bad,fmt=wav,m=0;AQID');
        expect(events, isEmpty);

        // Omitted i= on clip allocates an auto-ID in 0x80000001..0xFFFFFFFF.
        handler.handleApc('Aa=clip,fmt=wav,m=0;AQID');
        expect(events, hasLength(1));
        final clip = events.single as TerminalClipAudioEvent;
        expect(clip.clipId, greaterThanOrEqualTo(0x80000001));
      },
    );
  });
}
