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

    test(
      'decodes a=update frames (pan-only, volume-only, both, clamped, invalid ignored) and preserves interleaved clip uploads',
      () {
        final events = <TerminalAudioEvent>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onAudioEvent: events.add,
        );
        addTearDown(vt.dispose);

        // Interleave a=update between m=1 and m=0 chunks of a clip upload.
        final b64 = base64Encode(Uint8List.fromList([1, 2, 3, 4, 5, 6]));
        final half = b64.length ~/ 2;
        vt.writeString(
          '\x1b_Aa=clip,i=2,fmt=wav,m=1;${b64.substring(0, half)}\x1b\\',
        );
        vt.writeString(
          '\x1b_Aa=update,i=1,p=-0.75;\x1b\\'
          '\x1b_Aa=update,i=1,v=0.4;\x1b\\'
          '\x1b_Aa=update,i=1,v=2.0,p=-3.0;\x1b\\'
          '\x1b_Aa=update,i=2,v=0.35,p=0.25;\x1b\\'
          '\x1b_Aa=update,i=0,v=0.5;\x1b\\'
          '\x1b_Aa=update,i=2147483648,v=0.5;\x1b\\'
          '\x1b_Aa=update,i=1;\x1b\\'
          '\x1b_Aa=update,i=1,v=nan,p=inf;\x1b\\',
        );
        vt.writeString('\x1b_Ai=2,m=0;${b64.substring(half)}\x1b\\');

        expect(events, hasLength(4));
        expect(
          events[0],
          equals(const TerminalUpdateAudioEvent(clipId: 1, pan: -0.75)),
        );
        expect(
          events[1],
          equals(const TerminalUpdateAudioEvent(clipId: 1, volume: 0.4)),
        );
        expect(
          events[2],
          equals(
            const TerminalUpdateAudioEvent(clipId: 1, volume: 1.0, pan: -1.0),
          ),
        );
        final clip = events[3] as TerminalClipAudioEvent;
        expect(clip.clipId, equals(2));
        expect(clip.volume, equals(0.35));
        expect(clip.pan, equals(0.25));
        expect(clip.bytes, equals(Uint8List.fromList([1, 2, 3, 4, 5, 6])));
      },
    );

    test(
      'decodes clip startOffset and transport/fade/stop fields both live and mid-upload',
      () {
        final events = <TerminalAudioEvent>[];
        final handler = AudioApcHandler(onAudioEvent: events.add);
        final b64 = base64Encode(Uint8List.fromList([1, 2, 3, 4, 5, 6]));
        final half = b64.length ~/ 2;

        handler.handleApc(
          'Aa=clip,i=4,fmt=ogg,s=250,m=1;${b64.substring(0, half)}',
        );
        handler.handleApc(
          'Aa=update,i=4,s=900,pa=1,sp=1.25,pp=1,fv=0.4:300,fs=0.8:500,st=1200;',
        );
        expect(events, isEmpty);
        handler.handleApc('Ai=4,m=0;${b64.substring(half)}');

        expect(events, hasLength(2));
        final clip = events[0] as TerminalClipAudioEvent;
        expect(clip.startOffset, equals(const Duration(milliseconds: 250)));
        expect(
          events[1],
          equals(
            const TerminalUpdateAudioEvent(
              clipId: 4,
              seekPosition: Duration(milliseconds: 900),
              paused: true,
              speed: 1.25,
              preservePitch: true,
              fadeVolumeTarget: 0.4,
              fadeVolumeDuration: Duration(milliseconds: 300),
              fadeSpeedTarget: 0.8,
              fadeSpeedDuration: Duration(milliseconds: 500),
              scheduleStopDuration: Duration(milliseconds: 1200),
            ),
          ),
        );

        events.clear();
        // Mid-upload explicit v= / sp= clears earlier deferred fv= / fs=.
        handler.handleApc('Aa=clip,i=5,fmt=wav,m=1;${b64.substring(0, half)}');
        handler.handleApc('Aa=update,i=5,fv=0.2:400,fs=0.5:300;');
        handler.handleApc('Aa=update,i=5,v=0.85,sp=1.5;');
        handler.handleApc('Ai=5,m=0;${b64.substring(half)}');
        expect(events, hasLength(2));
        final clearedClip = events[0] as TerminalClipAudioEvent;
        expect(clearedClip.volume, equals(0.85));
        const expectedClearedUpdate = TerminalUpdateAudioEvent(
          clipId: 5,
          speed: 1.5,
        );
        expect(events[1], equals(expectedClearedUpdate));
        expect(events[1].hashCode, equals(expectedClearedUpdate.hashCode));

        events.clear();
        handler.handleApc(
          'Aa=update,i=8,s=100,pa=0,sp=16,pp=0,fv=0.1:50,fs=0.01:75,st=500;',
        );
        handler.handleApc('Aa=update,i=8,sp=-1,fv=bad,fs=1:2:3,s=-5;');
        expect(
          events,
          equals([
            const TerminalUpdateAudioEvent(
              clipId: 8,
              seekPosition: Duration(milliseconds: 100),
              paused: false,
              speed: 8.0,
              preservePitch: false,
              fadeVolumeTarget: 0.1,
              fadeVolumeDuration: Duration(milliseconds: 50),
              fadeSpeedTarget: 0.125,
              fadeSpeedDuration: Duration(milliseconds: 75),
              scheduleStopDuration: Duration(milliseconds: 500),
            ),
          ]),
        );
      },
    );

    test(
      'decodes a=bus lifecycle/filter commands and optional busId on tone and clip frames',
      () {
        final events = <TerminalAudioEvent>[];
        final handler = AudioApcHandler(onAudioEvent: events.add);

        handler.handleApc('Aa=bus,op=create,b=2;');
        handler.handleApc('Aa=bus,op=vol,b=2,v=1.5;');
        handler.handleApc('Aa=bus,op=attach,b=2,ft=7;');
        handler.handleApc('Aa=bus,op=param,b=2,ft=0,pm=2,v=1250.5;');
        handler.handleApc('Aa=bus,op=fade,b=2,ft=7,pm=2,v=0.8,d=400;');
        handler.handleApc('Aa=bus,op=destroy,b=2;');
        handler.handleApc('Aa=tone,w=sine,f=440,d=100,v=0.5,p=0.25,b=2;');

        final b64 = base64Encode(Uint8List.fromList([1, 2, 3, 4]));
        handler.handleApc(
          'Aa=clip,i=11,fmt=wav,v=0.9,p=-0.2,l=1,b=2,m=1;${b64.substring(0, 4)}',
        );
        handler.handleApc('Ai=11,m=0;${b64.substring(4)}');

        // Malformed bus commands and invalid b= on tone/clip are rejected cleanly.
        handler.handleApc('Aa=bus,op=create,b=0;');
        handler.handleApc('Aa=bus,op=bogus,b=2;');
        handler.handleApc('Aa=bus,op=vol,b=2;');
        handler.handleApc('Aa=bus,op=attach,b=2,ft=12;');
        handler.handleApc('Aa=bus,op=param,b=2,ft=0,pm=67,v=1.0;');
        handler.handleApc('Aa=bus,op=fade,b=2,ft=0,pm=0,v=nan,d=100;');
        handler.handleApc('Aa=bus,op=fade,b=2,ft=0,pm=0,v=0.5,d=-5;');
        handler.handleApc('Aa=tone,w=sine,f=440,d=100,b=0;');
        handler.handleApc('Aa=clip,i=12,fmt=wav,b=2147483648,m=0;$b64');

        expect(events, hasLength(8));
        const expectedCreate = TerminalBusAudioEvent(op: 'create', busId: 2);
        expect(events[0], equals(expectedCreate));
        expect(events[0].hashCode, equals(expectedCreate.hashCode));
        expect(
          events[1],
          equals(const TerminalBusAudioEvent(op: 'vol', busId: 2, value: 1.0)),
        );
        expect(
          events[2],
          equals(
            const TerminalBusAudioEvent(op: 'attach', busId: 2, filterId: 7),
          ),
        );
        expect(
          events[3],
          equals(
            const TerminalBusAudioEvent(
              op: 'param',
              busId: 2,
              filterId: 0,
              paramId: 2,
              value: 1250.5,
            ),
          ),
        );
        expect(
          events[4],
          equals(
            const TerminalBusAudioEvent(
              op: 'fade',
              busId: 2,
              filterId: 7,
              paramId: 2,
              value: 0.8,
              duration: Duration(milliseconds: 400),
            ),
          ),
        );
        expect(
          events[5],
          equals(const TerminalBusAudioEvent(op: 'destroy', busId: 2)),
        );
        const expectedTone = TerminalToneAudioEvent(
          waveform: 'sine',
          frequencyHz: 440.0,
          duration: Duration(milliseconds: 100),
          volume: 0.5,
          pan: 0.25,
          busId: 2,
        );
        expect(events[6], equals(expectedTone));
        expect(events[6].hashCode, equals(expectedTone.hashCode));
        final clip = events[7] as TerminalClipAudioEvent;
        expect(clip.clipId, equals(11));
        expect(clip.busId, equals(2));
      },
    );

    test(
      'decodes pass-through a=stream events and a=clip,st= without disturbing pending clip uploads',
      () {
        final events = <TerminalAudioEvent>[];
        final handler = AudioApcHandler(onAudioEvent: events.add);

        // Start a multi-chunk clip upload first.
        final clipB64 = base64Encode(
          Uint8List.fromList([10, 20, 30, 40, 50, 60]),
        );
        handler.handleApc(
          'Aa=clip,i=4,fmt=ogg,v=0.8,p=0.1,l=0,m=1;${clipB64.substring(0, 4)}',
        );
        expect(handler.pendingUploadCount, equals(1));

        // Interleave a=stream open, chunk, end, and a=clip,st=.
        handler.handleApc(
          'Aa=stream,op=open,s=9,max=8388608,rel=1,buf=250,sr=44100,ch=1;',
        );
        final chunkBytes = Uint8List.fromList([0x49, 0x44, 0x33, 1, 2, 3]);
        handler.handleApc(
          'Aa=stream,op=chunk,s=9,seq=0;${base64Encode(chunkBytes)}',
        );
        handler.handleApc('Aa=stream,op=end,s=9,seq=1;');
        handler.handleApc('Aa=clip,i=15,st=9,v=0.6,p=-0.3,l=1,s=50,b=2;');

        // Pending clip upload must still be intact; complete it with m=0 and no i=.
        expect(handler.pendingUploadCount, equals(1));
        handler.handleApc('Am=0;${clipB64.substring(4)}');
        expect(handler.pendingUploadCount, equals(0));

        // Invalid stream / st= inputs are ignored cleanly.
        handler.handleApc('Aa=stream,op=open,s=0;');
        handler.handleApc('Aa=stream,op=open,s=9,max=0;');
        handler.handleApc('Aa=stream,op=chunk,s=9,seq=-1;AAAA');
        handler.handleApc('Aa=stream,op=end,s=9,seq=-2;');
        handler.handleApc('Aa=clip,i=16,st=0;');

        expect(events, hasLength(5));
        const expectedOpen = TerminalStreamAudioEvent(
          op: 'open',
          streamId: 9,
          maxBufferSize: 8388608,
          releaseConsumed: true,
          bufferingTimeNeeds: Duration(milliseconds: 250),
          sampleRate: 44100,
          channels: 1,
        );
        expect(events[0], equals(expectedOpen));
        expect(events[0].hashCode, equals(expectedOpen.hashCode));
        expect(
          events[1],
          equals(
            TerminalStreamAudioEvent(
              op: 'chunk',
              streamId: 9,
              seq: 0,
              chunkBytes: chunkBytes,
            ),
          ),
        );
        expect(
          events[2],
          equals(
            const TerminalStreamAudioEvent(op: 'end', streamId: 9, seq: 1),
          ),
        );
        final streamClip = events[3] as TerminalClipAudioEvent;
        expect(streamClip.clipId, equals(15));
        expect(streamClip.streamId, equals(9));
        expect(streamClip.bytes, isEmpty);
        expect(streamClip.volume, equals(0.6));
        expect(streamClip.pan, equals(-0.3));
        expect(streamClip.loop, isTrue);
        expect(
          streamClip.startOffset,
          equals(const Duration(milliseconds: 50)),
        );
        expect(streamClip.busId, equals(2));

        final finishedClip = events[4] as TerminalClipAudioEvent;
        expect(finishedClip.clipId, equals(4));
        expect(finishedClip.streamId, isNull);
        expect(finishedClip.bytes, equals([10, 20, 30, 40, 50, 60]));
      },
    );
  });
}
