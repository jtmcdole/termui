import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_caster_cli/termui_caster_cli.dart';
import 'package:test/test.dart';

final class _FakeUploadPty implements PtySession {
  final StreamController<Uint8List> _output = StreamController<Uint8List>(
    sync: true,
  );
  final Completer<int> _exitCode = Completer<int>();
  final List<String> writtenStrings = [];

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  @override
  void writeBytes(Uint8List bytes) {
    writtenStrings.add(utf8.decode(bytes));
  }

  @override
  void resize(int cols, int rows, {int pixelWidth = 0, int pixelHeight = 0}) {}

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCode.isCompleted) _exitCode.complete(0);
    unawaited(_output.close());
    return true;
  }

  void emitOutput(String text) {
    _output.add(Uint8List.fromList(utf8.encode(text)));
  }
}

void main() {
  group('FileUploadReceiver.sanitizeFileName & formatUploadedPathForPty', () {
    test(
      'strips path traversal, forbidden chars, trailing dots/spaces, and Windows device names',
      () {
        check(
          FileUploadReceiver.sanitizeFileName('../../etc/passwd'),
        ).equals('passwd');
        check(
          FileUploadReceiver.sanitizeFileName(r'C:\Users\demo\report.pdf'),
        ).equals('report.pdf');
        check(
          FileUploadReceiver.sanitizeFileName('bad<>:"|?*\x00name.txt. . '),
        ).equals('bad________name.txt');
        check(
          FileUploadReceiver.sanitizeFileName('cmd&%PATH%!^;`\$inject.sh'),
        ).equals('cmd__PATH______inject.sh');
        check(FileUploadReceiver.sanitizeFileName('...')).equals('upload.bin');
        check(FileUploadReceiver.sanitizeFileName('')).equals('upload.bin');
        check(
          FileUploadReceiver.sanitizeFileName('NUL.txt'),
        ).equals('_NUL.txt');
        check(FileUploadReceiver.sanitizeFileName('com1')).equals('_com1');

        final longName = '${'é' * 150}.txt';
        final truncated = FileUploadReceiver.sanitizeFileName(longName);
        check(utf8.encode(truncated).length).isLessOrEqual(200);
        check(truncated.endsWith('.txt')).isTrue();
      },
    );

    test(
      'formats POSIX and Windows paths with shell quoting and bracketed paste',
      () {
        check(
          FileUploadReceiver.formatUploadedPathForPty(
            '/tmp/termui_cast_uploads/s1/demo.txt',
            isWindows: false,
            bracketedPaste: false,
          ),
        ).equals('/tmp/termui_cast_uploads/s1/demo.txt ');

        check(
          FileUploadReceiver.formatUploadedPathForPty(
            "/tmp/it's a file.txt",
            isWindows: false,
            bracketedPaste: true,
          ),
        ).equals("\x1b[200~'/tmp/it'\\''s a file.txt' \x1b[201~");

        check(
          FileUploadReceiver.formatUploadedPathForPty(
            r"C:\Temp\it's a file (1).txt",
            isWindows: true,
            bracketedPaste: false,
          ),
        ).equals('"C:\\Temp\\it\'s a file (1).txt" ');
      },
    );
  });

  group('FileUploadReceiver staging, verification, and error handling', () {
    late Directory tempDir;
    const sessionId = SessionId('upload-sess');

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('termui_upload_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'stages .part file, verifies SHA-256, resolves name collisions, and supports 0-byte files',
      () {
        final receiver = FileUploadReceiver(
          sessionId: sessionId,
          uploadDir: tempDir,
        );
        final payload = Uint8List.fromList(utf8.encode('hello world!'));
        final digest = Uint8List.fromList(sha256.convert(payload).bytes);

        final readyAck = receiver.handleStart(
          FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 1,
            fileName: 'notes.txt',
            totalBytes: payload.length,
          ),
        );
        check(readyAck.status).equals(FileUploadStatus.ready);
        check(readyAck.nextOffset).equals(0);

        final chunk1 = receiver.handleChunk(
          FileUploadChunkFrame(
            sessionId: sessionId,
            transferId: 1,
            offset: 0,
            data: Uint8List.sublistView(payload, 0, 5),
          ),
        );
        check(chunk1.status).equals(FileUploadStatus.chunkAck);
        check(chunk1.nextOffset).equals(5);

        final chunk2 = receiver.handleChunk(
          FileUploadChunkFrame(
            sessionId: sessionId,
            transferId: 1,
            offset: 5,
            data: Uint8List.sublistView(payload, 5),
          ),
        );
        check(chunk2.status).equals(FileUploadStatus.chunkAck);
        check(chunk2.nextOffset).equals(payload.length);

        final (endAck, path1) = receiver.handleEnd(
          FileUploadEndFrame(
            sessionId: sessionId,
            transferId: 1,
            sha256: digest,
          ),
        );
        check(endAck.status).equals(FileUploadStatus.completed);
        check(path1).equals(p.join(tempDir.path, 'notes.txt'));
        check(File(path1!).readAsStringSync()).equals('hello world!');

        // Uploading a second file (0-byte) with the same name resolves to "notes (1).txt".
        final emptyDigest = Uint8List.fromList(
          sha256.convert(const <int>[]).bytes,
        );
        check(
          receiver
              .handleStart(
                const FileUploadStartFrame(
                  sessionId: sessionId,
                  transferId: 2,
                  fileName: 'notes.txt',
                  totalBytes: 0,
                ),
              )
              .status,
        ).equals(FileUploadStatus.ready);
        final (endAck2, path2) = receiver.handleEnd(
          FileUploadEndFrame(
            sessionId: sessionId,
            transferId: 2,
            sha256: emptyDigest,
          ),
        );
        check(endAck2.status).equals(FileUploadStatus.completed);
        check(path2).equals(p.join(tempDir.path, 'notes (1).txt'));
        check(File(path2!).lengthSync()).equals(0);
      },
    );

    test(
      'rejects disabled receiver, oversized files, bad offsets, bad SHA-256, and cleans up .part on abort',
      () {
        final disabled = FileUploadReceiver(
          sessionId: sessionId,
          uploadDir: tempDir,
          enabled: false,
        );
        check(
          disabled
              .handleStart(
                const FileUploadStartFrame(
                  sessionId: sessionId,
                  transferId: 1,
                  fileName: 'a.txt',
                  totalBytes: 1,
                ),
              )
              .status,
        ).equals(FileUploadStatus.rejected);

        final receiver = FileUploadReceiver(
          sessionId: sessionId,
          uploadDir: tempDir,
          maxUploadBytes: 8,
        );
        check(
          receiver
              .handleStart(
                const FileUploadStartFrame(
                  sessionId: sessionId,
                  transferId: 2,
                  fileName: 'big.bin',
                  totalBytes: 9,
                ),
              )
              .status,
        ).equals(FileUploadStatus.rejected);

        // Out-of-order chunk offset is rejected and deletes .part file.
        check(
          receiver
              .handleStart(
                const FileUploadStartFrame(
                  sessionId: sessionId,
                  transferId: 3,
                  fileName: 'bad_offset.bin',
                  totalBytes: 4,
                ),
              )
              .status,
        ).equals(FileUploadStatus.ready);
        check(
          receiver
              .handleChunk(
                FileUploadChunkFrame(
                  sessionId: sessionId,
                  transferId: 3,
                  offset: 2,
                  data: Uint8List.fromList([1, 2]),
                ),
              )
              .status,
        ).equals(FileUploadStatus.rejected);
        check(tempDir.listSync()).isEmpty();

        // SHA-256 mismatch is rejected and deletes .part file.
        check(
          receiver
              .handleStart(
                const FileUploadStartFrame(
                  sessionId: sessionId,
                  transferId: 4,
                  fileName: 'bad_hash.bin',
                  totalBytes: 2,
                ),
              )
              .status,
        ).equals(FileUploadStatus.ready);
        receiver.handleChunk(
          FileUploadChunkFrame(
            sessionId: sessionId,
            transferId: 4,
            offset: 0,
            data: Uint8List.fromList([0xAA, 0xBB]),
          ),
        );
        final (badHashAck, badHashPath) = receiver.handleEnd(
          FileUploadEndFrame(
            sessionId: sessionId,
            transferId: 4,
            sha256: Uint8List(32),
          ),
        );
        check(badHashAck.status).equals(FileUploadStatus.rejected);
        check(badHashPath).isNull();
        check(tempDir.listSync()).isEmpty();

        // Client abort cleans up .part file.
        receiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 5,
            fileName: 'aborted.bin',
            totalBytes: 4,
          ),
        );
        final (abortAck, _) = receiver.handleEnd(
          FileUploadEndFrame(
            sessionId: sessionId,
            transferId: 5,
            sha256: Uint8List(0),
            aborted: true,
          ),
        );
        check(abortAck.status).equals(FileUploadStatus.rejected);
        check(tempDir.listSync()).isEmpty();
      },
    );

    test(
      'sweeps only same-session stale .part files once on first start, rejects leaf symlink uploadDir, and allows uploadDir under symlink parent',
      () {
        final staleSameSessionPart = File(
          p.join(tempDir.path, '.upload-${sessionId.value}-99.part'),
        )..writeAsStringSync('orphaned-same-session');
        final siblingSessionPart = File(
          p.join(tempDir.path, '.upload-other-sess-99.part'),
        )..writeAsStringSync('in-flight-other-session');
        final keepFile = File(p.join(tempDir.path, 'existing.txt'))
          ..writeAsStringSync('keep');

        final receiver = FileUploadReceiver(
          sessionId: sessionId,
          uploadDir: tempDir,
        );
        final startAck = receiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 10,
            fileName: 'fresh.txt',
            totalBytes: 0,
          ),
        );
        check(startAck.status).equals(FileUploadStatus.ready);
        check(staleSameSessionPart.existsSync()).isFalse();
        check(siblingSessionPart.existsSync()).isTrue();
        check(keepFile.existsSync()).isTrue();
        receiver.abortAll();

        // Subsequent start on the same receiver instance does not sweep again.
        final postSweepPart = File(
          p.join(tempDir.path, '.upload-${sessionId.value}-100.part'),
        )..writeAsStringSync('keep-after-first-sweep');
        final secondStartAck = receiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 10,
            fileName: 'fresh2.txt',
            totalBytes: 0,
          ),
        );
        check(secondStartAck.status).equals(FileUploadStatus.ready);
        check(postSweepPart.existsSync()).isTrue();
        receiver.abortAll();

        // Rejects symlink leaf uploadDir, but allows real directory inside symlink parent (e.g. macOS /tmp -> private/tmp).
        final realTarget = Directory(p.join(tempDir.path, 'real_target'))
          ..createSync();
        final symlinkDirPath = p.join(tempDir.path, 'symlink_uploads');
        Link(symlinkDirPath).createSync(realTarget.path);

        final symlinkReceiver = FileUploadReceiver(
          sessionId: sessionId,
          uploadDir: Directory(symlinkDirPath),
        );
        final symlinkAck = symlinkReceiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 11,
            fileName: 'escape.txt',
            totalBytes: 0,
          ),
        );
        check(symlinkAck.status).equals(FileUploadStatus.rejected);
        check(symlinkAck.message).isNotNull().contains('symlink');

        final parentSymlinkReceiver = FileUploadReceiver(
          sessionId: sessionId,
          uploadDir: Directory(p.join(symlinkDirPath, 'nested')),
        );
        final parentSymlinkAck = parentSymlinkReceiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 12,
            fileName: 'allowed_under_symlink_parent.txt',
            totalBytes: 0,
          ),
        );
        check(parentSymlinkAck.status).equals(FileUploadStatus.ready);
        parentSymlinkReceiver.abortAll();
      },
    );
  });

  group('CasterConfig and CasterService upload integration', () {
    test(
      'parses --[no-]upload, --upload-dir, --max-upload-bytes and injects completed path into PTY',
      () async {
        final cfg = CasterConfig.fromArgs(const [
          '--no-upload',
          '--upload-dir',
          '/tmp/custom_uploads',
          '--max-upload-bytes',
          '1048576',
          '--',
          'zsh',
        ])!;
        check(cfg.uploadEnabled).isFalse();
        check(cfg.uploadDirPath).equals('/tmp/custom_uploads');
        check(cfg.maxUploadBytes).equals(1048576);

        final envCfg = CasterConfig.fromArgs(
          const ['--', 'zsh'],
          environment: const {
            'TERMUI_CAST_UPLOAD': 'false',
            'TERMUI_CAST_UPLOAD_DIR': '/var/tmp/uploads',
            'TERMUI_CAST_MAX_UPLOAD_BYTES': '4096',
          },
        )!;
        check(envCfg.uploadEnabled).isFalse();
        check(envCfg.uploadDirPath).equals('/var/tmp/uploads');
        check(envCfg.maxUploadBytes).equals(4096);

        final tempDir = await Directory.systemTemp.createTemp(
          'caster_svc_upload_',
        );
        addTearDown(() => tempDir.delete(recursive: true));

        final pty = _FakeUploadPty();
        final serverCtrl = StreamChannelController<Uint8List>();
        const sessionId = SessionId('svc-upload');
        final service = CasterService(
          config: CasterConfig(
            sessionId: sessionId,
            title: 'zsh',
            uploadDirPath: tempDir.path,
            command: const ['zsh'],
          ),
          pty: pty,
          isWindows: false,
          channelOpener: () async => serverCtrl.local,
        );

        final sentByCaster = <CastMessage>[];
        serverCtrl.foreign.stream.listen((raw) {
          final decoded = BufferFrameCodec.decode(raw);
          sentByCaster.add(decoded);
          if (decoded is AuthFrame) {
            serverCtrl.foreign.sink.add(
              BufferFrameCodec.encode(const AuthAcceptedFrame(role: .caster)),
            );
          }
        });

        await service.start();
        await pumpEventQueue();
        // Enable bracketed paste mode on the authoritative terminal.
        pty.emitOutput('\x1b[?2004h');
        await pumpEventQueue();

        final data = Uint8List.fromList(utf8.encode('drop-payload'));
        final digest = Uint8List.fromList(sha256.convert(data).bytes);

        serverCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadStartFrame(
              sessionId: sessionId,
              transferId: 9,
              fileName: 'my file.txt',
              totalBytes: data.length,
            ),
          ),
        );
        serverCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadChunkFrame(
              sessionId: sessionId,
              transferId: 9,
              offset: 0,
              data: data,
            ),
          ),
        );
        serverCtrl.foreign.sink.add(
          BufferFrameCodec.encode(
            FileUploadEndFrame(
              sessionId: sessionId,
              transferId: 9,
              sha256: digest,
            ),
          ),
        );
        await pumpEventQueue();

        final acks = [...sentByCaster.whereType<FileUploadAckFrame>()];
        check([
          for (final a in acks) a.status,
        ]).deepEquals(const <FileUploadStatus>[.ready, .chunkAck, .completed]);
        final expectedPath = p.join(tempDir.path, 'my file.txt');
        check(File(expectedPath).readAsStringSync()).equals('drop-payload');
        check(
          pty.writtenStrings,
        ).contains("\x1b[200~'$expectedPath' \x1b[201~");

        await service.stop(killPty: true);
      },
    );
  });

  _defineLazyDefaultUploadDirTests();
}

void _defineLazyDefaultUploadDirTests() {
  group('FileUploadReceiver lazy default directory & dispose cleanup', () {
    test(
      'idle and --no-upload receivers create 0 temp directories, and dispose() removes empty auto-created default directory',
      () {
        const sessionId = SessionId('lazy-temp-sess');
        Set<String> listUploadRoots() => {
          for (final entity in Directory.systemTemp.listSync(
            followLinks: false,
          ))
            if (p.basename(entity.path).startsWith('termui_cast_uploads_'))
              entity.path,
        };

        final before = listUploadRoots();

        // 1. Idle enabled receiver and disabled (--no-upload) receiver create 0 temp directories.
        final idleReceiver = FileUploadReceiver(sessionId: sessionId);
        final disabledReceiver = FileUploadReceiver(
          sessionId: sessionId,
          enabled: false,
        );
        final disabledAck = disabledReceiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 1,
            fileName: 'nope.txt',
            totalBytes: 4,
          ),
        );
        check(disabledAck.status).equals(FileUploadStatus.rejected);
        check(listUploadRoots().difference(before)).isEmpty();
        idleReceiver.dispose();
        disabledReceiver.dispose();

        // 2. First enabled handleStart lazily creates the default temp directory, and dispose() removes it when empty.
        final activeReceiver = FileUploadReceiver(sessionId: sessionId);
        final startAck = activeReceiver.handleStart(
          const FileUploadStartFrame(
            sessionId: sessionId,
            transferId: 2,
            fileName: 'staged.txt',
            totalBytes: 4,
          ),
        );
        check(startAck.status).equals(FileUploadStatus.ready);
        final createdDir = activeReceiver.uploadDir;
        final createdRoot = createdDir.parent;
        check(createdDir.existsSync()).isTrue();
        check(
          p.basename(createdRoot.path).startsWith('termui_cast_uploads_'),
        ).isTrue();

        // dispose() aborts the in-flight .part file and deletes both empty sessionDir and autoRoot.
        activeReceiver.dispose();
        check(createdDir.existsSync()).isFalse();
        check(createdRoot.existsSync()).isFalse();
      },
    );
  });
}
