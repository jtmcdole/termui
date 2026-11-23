import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('CastMessage wire round-trips', () {
    test('encodes and decodes every non-buffer CastMessage variant', () {
      const idA = SessionId('pty-alpha');
      const idB = SessionId('pty-beta');
      check(idA.isValid).isTrue();
      check(const SessionId('').isValid).isFalse();
      check(
        parseCastWebSocketUri('ws://127.0.0.1:8420/v1/client').host,
      ).equals('127.0.0.1');
      check(
        parseCastWebSocketUri('https://relay.run.app/v1/client').toString(),
      ).equals('wss://relay.run.app/v1/client');
      check(
        parseCastWebSocketUri(
          'https://relay.run.app/#token=secret',
          defaultPath: '/v1/client',
        ).toString(),
      ).equals('wss://relay.run.app/v1/client');
      check(
        parseCastWebSocketUri(
          'https://relay.run.app/v1/caster',
          defaultPath: '/v1/client',
          normalizeCasterPath: true,
        ).toString(),
      ).equals('wss://relay.run.app/v1/client');
      check(
        parseCastWebSocketUri(
          'relay.run.app',
          defaultPath: '/v1/client',
        ).toString(),
      ).equals('wss://relay.run.app/v1/client');
      check(
        parseCastWebSocketUri(
          'localhost:8420',
          defaultPath: '/v1/client',
        ).toString(),
      ).equals('ws://localhost:8420/v1/client');
      check(
        parseCastWebSocketUri(
          '[::1]:8420',
          defaultPath: '/v1/client',
        ).toString(),
      ).equals('ws://[::1]:8420/v1/client');
      check(() => parseCastWebSocketUri('ws://')).throws<FormatException>();
      check(
        () => parseCastWebSocketUri('http://127.0.0.1:8420'),
      ).throws<FormatException>();
      check(
        () => parseCastWebSocketUri('ws://https://relay.run.app'),
      ).throws<FormatException>();
      check(
        () => parseCastWebSocketUri('wss://https://relay.run.app/v1/client'),
      ).throws<FormatException>();
      check(() => parseCastWebSocketUri('bad host')).throws<FormatException>();
      check(
        () => parseCastWebSocketUri('relay.run.app:'),
      ).throws<FormatException>();
      check(() => parseCastWebSocketUri('ws:')).throws<FormatException>();

      final resumeToken = Uint8List.fromList(
        List<int>.generate(16, (i) => i + 1),
      );
      final messages = <CastMessage>[
        const AuthFrame(role: .caster, token: 'secret-caster'),
        const AuthAcceptedFrame(role: .client),
        RegisterSessionFrame(
          sessionId: idA,
          title: 'zsh - main',
          cols: 120,
          rows: 40,
          resumeToken: resumeToken,
        ),
        const SessionDirectoryFrame(
          sessions: [
            SessionSummary(
              id: idA,
              title: 'zsh - main',
              cols: 120,
              rows: 40,
              subscriberCount: 2,
              isUserPinned: true,
            ),
            SessionSummary(id: idB, title: 'htop', cols: 80, rows: 24),
          ],
        ),
        const SubscribeSessionFrame(sessionId: idA, cols: 100, rows: 30),
        const UnsubscribeSessionFrame(sessionId: idA),
        const SubscriberCountFrame(sessionId: idA, subscriberCount: 3),
        const RequestKeyframeFrame(sessionId: idB),
        InputFrame(
          sessionId: idA,
          data: Uint8List.fromList([0x1b, 0x5b, 0x41]),
        ),
        const ResizeFrame(sessionId: idA, cols: 132, rows: 43),
        const SessionClosedFrame(
          sessionId: idB,
          exitCode: -1,
          reason: .disconnected,
        ),
        const RenameSessionFrame(sessionId: idA, title: 'renamed 🚀'),
        const RenameSessionFrame(sessionId: idB, title: '', clearPin: true),
        const ShellTitleFrame(sessionId: idA, title: 'nvim main.dart'),
        const ShellTitleFrame(sessionId: idB, title: ''),
        const BellFrame(sessionId: idA),
        const AudioFrame(
          sessionId: idA,
          payload: CastToneAudioPayload(
            waveform: 'sine',
            frequencyHz: 440.0,
            duration: Duration(milliseconds: 120),
            volume: 0.6,
            pan: -0.5,
            busId: 2,
          ),
        ),
        AudioFrame(
          sessionId: idA,
          payload: CastClipAudioPayload(
            clipId: 7,
            format: 'wav',
            bytes: Uint8List.fromList([0x52, 0x49, 0x46, 0x46]),
            volume: 0.9,
            pan: 0.25,
            loop: true,
            startOffset: const Duration(milliseconds: 125),
            busId: 2,
          ),
        ),
        const AudioFrame(
          sessionId: idA,
          payload: CastBusAudioPayload(
            op: 'fade',
            busId: 2,
            filterId: 7,
            paramId: 2,
            value: 0.85,
            duration: Duration(milliseconds: 300),
          ),
        ),
        AudioFrame(
          sessionId: idA,
          payload: CastStreamAudioPayload(
            op: 'chunk',
            streamId: 5,
            seq: 2,
            chunkBytes: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
          ),
        ),
        const AudioFrame(
          sessionId: idB,
          payload: CastStopAudioPayload(clipId: 7),
        ),
        const AudioFrame(sessionId: idB, payload: CastStopAudioPayload()),
        const AudioFrame(
          sessionId: idA,
          payload: CastUpdateAudioPayload(
            clipId: 7,
            volume: 0.45,
            pan: -0.6,
            seekPosition: Duration(milliseconds: 500),
            paused: false,
            speed: 1.25,
            preservePitch: true,
          ),
        ),
        const AudioFrame(
          sessionId: idA,
          payload: CastWaveformQueryAudioPayload(requestId: 33),
        ),
        AudioWaveformReplyFrame(
          sessionId: idA,
          requestId: 33,
          samples: Float32List.fromList(
            List<double>.generate(256, (i) => (i - 128) / 128.0),
          ),
        ),
        KittyImageChunkFrame(
          sessionId: idA,
          imageId: 0x80000001,
          version: 2,
          pixelWidth: 2,
          pixelHeight: 2,
          gridCols: 1,
          gridRows: 1,
          format: 32,
          encoding: KittyChunkEncoding.raw,
          totalDecodedBytes: 16,
          totalWireBytes: 16,
          chunkIndex: 0,
          chunkCount: 1,
          data: Uint8List(16),
        ),
        const ShaderFrame(
          sessionId: idA,
          payload: CastResetShaderPayload(target: 'all'),
        ),
        const ErrorFrame(code: 'auth_failed', message: 'Invalid bearer token'),
        const ClipboardFrame(sessionId: idA, text: 'hello 🚀'),
        const ClipboardFrame(sessionId: idB, readBlocked: true),
        const RequestScrollbackFrame(
          sessionId: idA,
          requestId: 9,
          clearSeq: 2,
          startLine: 128,
          count: 64,
        ),
        const ScrollbackChunkFrame(
          sessionId: idA,
          requestId: 9,
          clearSeq: 2,
          startLine: 128,
          rows: [],
        ),
        const FileUploadStartFrame(
          sessionId: idA,
          transferId: 11,
          totalBytes: 512,
          fileName: 'demo.txt',
        ),
        FileUploadChunkFrame(
          sessionId: idA,
          transferId: 11,
          offset: 0,
          data: Uint8List.fromList([0x41, 0x42]),
        ),
        FileUploadEndFrame(
          sessionId: idA,
          transferId: 11,
          sha256: Uint8List(32),
        ),
        const FileUploadAckFrame(
          sessionId: idA,
          transferId: 11,
          status: .completed,
          nextOffset: 512,
          message: '/tmp/demo.txt',
        ),
      ];

      for (final message in messages) {
        final bytes = BufferFrameCodec.encode(message);
        check(
          BufferFrameCodec.inspectRelayBufferFrame(bytes, expectedSession: idA),
        ).isNull();
        final roundTripped = BufferFrameCodec.decode(bytes);
        check(roundTripped.runtimeType).equals(message.runtimeType);

        switch (roundTripped) {
          case AuthFrame(:final role, :final token):
            check(role).equals(CastRole.caster);
            check(token).equals('secret-caster');
          case AuthAcceptedFrame(:final role):
            check(role).equals(CastRole.client);
          case RegisterSessionFrame(
            :final sessionId,
            :final title,
            :final cols,
            :final rows,
            resumeToken: final decodedToken,
          ):
            check(sessionId).equals(idA);
            check(title).equals('zsh - main');
            check(cols).equals(120);
            check(rows).equals(40);
            check(decodedToken).deepEquals(resumeToken);
          case SessionDirectoryFrame(:final sessions):
            check(sessions).length.equals(2);
            check(sessions[0]).equals(
              const SessionSummary(
                id: idA,
                title: 'zsh - main',
                cols: 120,
                rows: 40,
                subscriberCount: 2,
                isUserPinned: true,
              ),
            );
            check(sessions[0].hashCode).equals(
              const SessionSummary(
                id: idA,
                title: 'zsh - main',
                cols: 120,
                rows: 40,
                subscriberCount: 2,
                isUserPinned: true,
              ).hashCode,
            );
            check(sessions[1].isUserPinned).isFalse();
          case SubscribeSessionFrame(
            :final sessionId,
            :final cols,
            :final rows,
          ):
            check(sessionId).equals(idA);
            check(cols).equals(100);
            check(rows).equals(30);
          case UnsubscribeSessionFrame(:final sessionId):
            check(sessionId).equals(idA);
          case SubscriberCountFrame(:final sessionId, :final subscriberCount):
            check(sessionId).equals(idA);
            check(subscriberCount).equals(3);
          case RequestKeyframeFrame(:final sessionId):
            check(sessionId).equals(idB);
          case InputFrame(:final sessionId, :final data):
            check(sessionId).equals(idA);
            check(data).deepEquals([0x1b, 0x5b, 0x41]);
          case ResizeFrame(:final sessionId, :final cols, :final rows):
            check(sessionId).equals(idA);
            check(cols).equals(132);
            check(rows).equals(43);
          case SessionClosedFrame(
            :final sessionId,
            :final reason,
            :final exitCode,
          ):
            check(sessionId).equals(idB);
            check(reason).equals(SessionCloseReason.disconnected);
            check(exitCode).equals(-1);
          case RenameSessionFrame(
            :final sessionId,
            :final title,
            :final clearPin,
          ):
            if (clearPin) {
              check(sessionId).equals(idB);
              check(title).equals('');
            } else {
              check(sessionId).equals(idA);
              check(title).equals('renamed 🚀');
            }
          case ShellTitleFrame(:final sessionId, :final title):
            if (title.isEmpty) {
              check(sessionId).equals(idB);
            } else {
              check(sessionId).equals(idA);
              check(title).equals('nvim main.dart');
            }
          case BellFrame(:final sessionId):
            check(sessionId).equals(idA);
            check(
              BufferFrameCodec.inspectRelayBellFrame(
                bytes,
                expectedSession: idA,
              ),
            ).isTrue();
          case AudioFrame(:final sessionId, :final payload):
            check(
              BufferFrameCodec.inspectRelayAudioFrame(
                bytes,
                expectedSession: sessionId,
              ),
            ).isTrue();
            switch (payload) {
              case CastToneAudioPayload():
                check(sessionId).equals(idA);
                const expectedTone = CastToneAudioPayload(
                  waveform: 'sine',
                  frequencyHz: 440.0,
                  duration: Duration(milliseconds: 120),
                  volume: 0.6,
                  pan: -0.5,
                  busId: 2,
                );
                check(payload).equals(expectedTone);
                check(payload.hashCode).equals(expectedTone.hashCode);
              case CastClipAudioPayload(
                :final clipId,
                :final format,
                :final bytes,
                :final volume,
                :final pan,
                :final loop,
                :final startOffset,
                :final busId,
              ):
                check(sessionId).equals(idA);
                check(clipId).equals(7);
                check(format).equals('wav');
                check(bytes).deepEquals([0x52, 0x49, 0x46, 0x46]);
                check(volume).equals(0.9);
                check(pan).equals(0.25);
                check(loop).isTrue();
                check(startOffset).equals(const Duration(milliseconds: 125));
                check(busId).equals(2);
              case CastBusAudioPayload():
                check(sessionId).equals(idA);
                const expectedBus = CastBusAudioPayload(
                  op: 'fade',
                  busId: 2,
                  filterId: 7,
                  paramId: 2,
                  value: 0.85,
                  duration: Duration(milliseconds: 300),
                );
                check(payload).equals(expectedBus);
                check(payload.hashCode).equals(expectedBus.hashCode);
              case CastStopAudioPayload(:final clipId):
                check(sessionId).equals(idB);
                final expectedStop = CastStopAudioPayload(clipId: clipId);
                check(payload).equals(expectedStop);
                check(payload.hashCode).equals(expectedStop.hashCode);
              case CastUpdateAudioPayload(
                :final clipId,
                :final volume,
                :final pan,
              ):
                check(sessionId).equals(idA);
                check(clipId).equals(7);
                check(volume).equals(0.45);
                check(pan).equals(-0.6);
                const expectedUpdate = CastUpdateAudioPayload(
                  clipId: 7,
                  volume: 0.45,
                  pan: -0.6,
                  seekPosition: Duration(milliseconds: 500),
                  paused: false,
                  speed: 1.25,
                  preservePitch: true,
                );
                check(payload).equals(expectedUpdate);
                check(payload.hashCode).equals(expectedUpdate.hashCode);
              case CastStreamAudioPayload():
                check(sessionId).equals(idA);
                final expectedStream = CastStreamAudioPayload(
                  op: 'chunk',
                  streamId: 5,
                  seq: 2,
                  chunkBytes: Uint8List.fromList([0xAA, 0xBB, 0xCC]),
                );
                check(payload).equals(expectedStream);
                check(payload.hashCode).equals(expectedStream.hashCode);
              case CastWaveformQueryAudioPayload(:final requestId):
                check(sessionId).equals(idA);
                check(requestId).equals(33);
                const expectedWave = CastWaveformQueryAudioPayload(
                  requestId: 33,
                );
                check(payload).equals(expectedWave);
                check(payload.hashCode).equals(expectedWave.hashCode);
            }
          case AudioWaveformReplyFrame(
            :final sessionId,
            :final requestId,
            :final samples,
          ):
            check(sessionId).equals(idA);
            check(requestId).equals(33);
            check(samples.length).equals(256);
            check(samples[200]).isCloseTo((200 - 128) / 128.0, 1e-6);
          case KittyImageChunkFrame(
            :final sessionId,
            :final imageId,
            :final version,
            :final totalWireBytes,
          ):
            check(sessionId).equals(idA);
            check(imageId).equals(0x80000001);
            check(version).equals(2);
            check(totalWireBytes).equals(16);
          case ShaderFrame(:final sessionId, :final payload):
            check(sessionId).equals(idA);
            check(payload).equals(const CastResetShaderPayload(target: 'all'));
          case ErrorFrame(:final code, :final message):
            check(code).equals('auth_failed');
            check(message).equals('Invalid bearer token');
          case ClipboardFrame(
            :final sessionId,
            :final text,
            :final readBlocked,
          ):
            if (readBlocked) {
              check(sessionId).equals(idB);
              check(text).equals('');
            } else {
              check(sessionId).equals(idA);
              check(text).equals('hello 🚀');
            }
          case RequestScrollbackFrame(
            :final sessionId,
            :final requestId,
            :final clearSeq,
            :final startLine,
            :final count,
          ):
            check(sessionId).equals(idA);
            check(requestId).equals(9);
            check(clearSeq).equals(2);
            check(startLine).equals(128);
            check(count).equals(64);
          case ScrollbackChunkFrame(
            :final sessionId,
            :final requestId,
            :final clearSeq,
            :final startLine,
            :final rows,
          ):
            check(sessionId).equals(idA);
            check(requestId).equals(9);
            check(clearSeq).equals(2);
            check(startLine).equals(128);
            check(rows).isEmpty();
          case FileUploadStartFrame(
            :final sessionId,
            :final transferId,
            :final totalBytes,
            :final fileName,
          ):
            check(sessionId).equals(idA);
            check(transferId).equals(11);
            check(totalBytes).equals(512);
            check(fileName).equals('demo.txt');
          case FileUploadChunkFrame(
            :final sessionId,
            :final transferId,
            :final offset,
            :final data,
          ):
            check(sessionId).equals(idA);
            check(transferId).equals(11);
            check(offset).equals(0);
            check(data).deepEquals([0x41, 0x42]);
          case FileUploadEndFrame(
            :final sessionId,
            :final transferId,
            :final sha256,
            :final aborted,
          ):
            check(sessionId).equals(idA);
            check(transferId).equals(11);
            check(sha256).length.equals(32);
            check(aborted).isFalse();
          case FileUploadAckFrame(
            :final sessionId,
            :final transferId,
            :final status,
            :final nextOffset,
            :final message,
          ):
            check(sessionId).equals(idA);
            check(transferId).equals(11);
            check(status).equals(FileUploadStatus.completed);
            check(nextOffset).equals(512);
            check(message).equals('/tmp/demo.txt');
          case BufferSnapshotFrame() || BufferDeltaFrame():
            fail('Unexpected buffer frame in control message test');
        }
      }
    });

    test(
      'ScrollbackWindow equality, hashCode, and wrappedRows bitset helpers',
      () {
        const a = ScrollbackWindow(clearSeq: 1, oldestLine: 5, totalLines: 20);
        const b = ScrollbackWindow(clearSeq: 1, oldestLine: 5, totalLines: 20);
        const c = ScrollbackWindow(clearSeq: 2, oldestLine: 5, totalLines: 20);
        check(a).equals(b);
        check(a.hashCode).equals(b.hashCode);
        check(a).not((it) => it.equals(c));

        check(wrappedRowsByteLength(0)).equals(0);
        check(wrappedRowsByteLength(-3)).equals(0);
        check(wrappedRowsByteLength(1)).equals(1);
        check(wrappedRowsByteLength(8)).equals(1);
        check(wrappedRowsByteLength(9)).equals(2);
        check(wrappedRowsByteLength(24)).equals(3);

        final packed = packWrappedRows(10, (r) => r == 0 || r == 7 || r == 9);
        check(packed).deepEquals([0x81, 0x02]);
        check(unpackWrappedRow(packed, 10, -1)).isFalse();
        check(unpackWrappedRow(packed, 10, 10)).isFalse();
        check(unpackWrappedRow(Uint8List(0), 10, 0)).isFalse();
        check(unpackWrappedRow(packed, 10, 0)).isTrue();
        check(unpackWrappedRow(packed, 10, 1)).isFalse();
        check(unpackWrappedRow(packed, 10, 7)).isTrue();
        check(unpackWrappedRow(packed, 10, 8)).isFalse();
        check(unpackWrappedRow(packed, 10, 9)).isTrue();
      },
    );
  });

  group('TokenAuthenticator', () {
    test(
      'verifies caster and client tokens via SHA-256 digests without cross-role leakage',
      () {
        final auth = TokenAuthenticator(
          casterToken: 'caster-secret-123',
          clientToken: 'client-secret-456',
        );
        check(auth.requiresToken(.caster)).isTrue();
        check(auth.requiresToken(.client)).isTrue();

        check(auth.verify(.caster, 'caster-secret-123')).isTrue();
        check(auth.verify(.caster, 'client-secret-456')).isFalse();
        check(auth.verify(.caster, 'caster-secret-124')).isFalse();
        check(auth.verify(.caster, '')).isFalse();

        check(auth.verify(.client, 'client-secret-456')).isTrue();
        check(auth.verify(.client, 'caster-secret-123')).isFalse();
      },
    );

    test(
      'permits empty or arbitrary tokens when role token is unconfigured on loopback',
      () {
        final loopbackAuth = TokenAuthenticator();
        check(loopbackAuth.requiresToken(.caster)).isFalse();
        check(loopbackAuth.requiresToken(.client)).isFalse();
        check(loopbackAuth.verify(.caster, '')).isTrue();
        check(loopbackAuth.verify(.client, 'anything')).isTrue();
      },
    );
  });

  group('validateSessionTitle', () {
    test(
      'trims valid titles and enforces grapheme, UTF-8, and control bounds',
      () {
        check(
          RenameSessionFrame.maxTitleBytes,
        ).equals(BufferFrameCodec.maxTitleBytes);

        final ok = validateSessionTitle('  deploy-prod 🚀  ');
        check(ok.title).equals('deploy-prod 🚀');
        check(ok.error).isNull();

        check(
          validateSessionTitle('   ').error,
        ).equals('Tab name cannot be empty.');
        check(
          validateSessionTitle('bad\x1btitle').error,
        ).equals('Tab name contains unsupported control characters.');
        check(
          validateSessionTitle('bidi\u202etitle').error,
        ).equals('Tab name contains unsupported control characters.');

        final tooManyGraphemes = 'a' * (maxSessionTitleGraphemes + 1);
        check(validateSessionTitle(tooManyGraphemes).error).equals(
          'Tab name must be $maxSessionTitleGraphemes characters or fewer.',
        );

        // 25 ZWJ family graphemes (<= 64 graphemes) exceed 512 UTF-8 bytes (25 * 25 = 625 bytes).
        final tooManyBytes = '👨‍👩‍👧‍👦' * 25;
        check(validateSessionTitle(tooManyBytes).error).equals(
          'Tab name exceeds ${BufferFrameCodec.maxTitleBytes} UTF-8 bytes.',
        );
      },
    );
  });

  group('parseCastWebSocketUri', () {
    test('rejects embedded userInfo credentials', () {
      check(
        () =>
            parseCastWebSocketUri('wss://user:secret@relay.example/v1/client'),
      ).throws<FormatException>();
      check(
        () => parseCastWebSocketUri('wss://token@relay.example/v1/caster'),
      ).throws<FormatException>();
      check(
        parseCastWebSocketUri('wss://relay.example/v1/client').userInfo,
      ).equals('');
    });
  });
}
