import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

import 'cast_client_repository.dart';
import 'models.dart';

/// Coordinates sequential, ack-paced multi-file uploads from the viewer client.
final class FileUploadCoordinator {
  /// Default client-side cap per uploaded file (`256 MiB`).
  static const int maxUploadBytes = 256 * 1024 * 1024;

  /// Maximum bytes read and transmitted per [FileUploadChunkFrame] (`64 KiB`).
  static const int chunkSizeBytes = FileUploadChunkFrame.maxChunkBytes;

  static final RegExp _controlOrSlash = RegExp(r'[\x00-\x1F\x7F-\x9F/\\]');

  /// Backing client repository used to transmit upload frames.
  final CastClientRepository repository;

  /// Callback invoked whenever [progress] updates or clears.
  final void Function() onProgressChanged;

  /// Callback invoked with a user-facing error summary when an upload is rejected.
  final void Function(String message) onError;

  /// Timeout waiting for a single [FileUploadAckFrame] from the relay/caster.
  final Duration ackTimeout;

  FileUploadProgress? _progress;
  _InFlightTransfer? _inFlight;
  ({SessionId sessionId, int transferId})? _activeTransfer;
  int _nextTransferId = 1;
  int _runEpoch = 0;
  bool _cancelled = false;

  /// Creates a file upload coordinator.
  FileUploadCoordinator({
    required this.repository,
    required this.onProgressChanged,
    required this.onError,
    this.ackTimeout = const Duration(seconds: 30),
  });

  /// Active upload progress snapshot, or `null` when idle.
  FileUploadProgress? get progress => _progress;

  /// Session currently receiving an upload batch, or `null` when idle.
  SessionId? get activeSessionId => _activeTransfer?.sessionId;

  /// Whether a file upload batch is currently in progress.
  bool get isUploading => _progress != null;

  /// Sanitizes a dropped file's display/wire name to `1..255` UTF-8 bytes.
  static String sanitizeWireFileName(String rawName) {
    final slash = max(rawName.lastIndexOf('/'), rawName.lastIndexOf(r'\'));
    final base = slash >= 0 ? rawName.substring(slash + 1) : rawName;
    final cleaned = base.replaceAll(_controlOrSlash, '_').trim();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') {
      return 'upload.bin';
    }
    if (utf8.encode(cleaned).length <= FileUploadStartFrame.maxFileNameBytes) {
      return cleaned;
    }
    final out = StringBuffer();
    var used = 0;
    for (final rune in cleaned.runes) {
      final s = String.fromCharCode(rune);
      final len = utf8.encode(s).length;
      if (used + len > FileUploadStartFrame.maxFileNameBytes) break;
      out.write(s);
      used += len;
    }
    return out.isEmpty ? 'upload.bin' : '$out';
  }

  /// Uploads [files] sequentially to [sessionId], returning `true` when all complete.
  Future<bool> uploadFiles(
    SessionId sessionId,
    List<DroppedFileSource> files,
  ) async {
    final validFiles = [
      for (final f in files)
        if (!f.isDirectory && f.size >= 0 && f.size <= maxUploadBytes) f,
    ];
    if (isUploading || validFiles.isEmpty) return false;
    final epoch = ++_runEpoch;
    _cancelled = false;
    var overallTotal = 0;
    for (final f in validFiles) {
      overallTotal += f.size;
    }
    var completedBytesBeforeCurrent = 0;

    try {
      for (var i = 0; i < validFiles.length; i++) {
        if (_cancelled || epoch != _runEpoch) return false;
        final file = validFiles[i];
        final wireName = sanitizeWireFileName(file.name);
        _updateProgress(
          FileUploadProgress(
            fileIndex: i + 1,
            fileCount: validFiles.length,
            currentFileName: wireName,
            overallSentBytes: completedBytesBeforeCurrent,
            overallTotalBytes: overallTotal,
          ),
        );
        final ok = await _uploadSingleFile(
          epoch: epoch,
          sessionId: sessionId,
          file: file,
          wireName: wireName,
          fileIndex: i + 1,
          fileCount: validFiles.length,
          completedBytesBeforeCurrent: completedBytesBeforeCurrent,
          overallTotalBytes: overallTotal,
        );
        if (!ok || epoch != _runEpoch) return false;
        completedBytesBeforeCurrent += file.size;
      }
      return true;
    } finally {
      if (epoch == _runEpoch) {
        _inFlight?.cancelTimer();
        _inFlight = null;
        _activeTransfer = null;
        _updateProgress(null);
      }
    }
  }

  Future<bool> _uploadSingleFile({
    required int epoch,
    required SessionId sessionId,
    required DroppedFileSource file,
    required String wireName,
    required int fileIndex,
    required int fileCount,
    required int completedBytesBeforeCurrent,
    required int overallTotalBytes,
  }) async {
    final transferId = _allocateTransferId();
    _activeTransfer = (sessionId: sessionId, transferId: transferId);
    final readyAck = await _sendAndAwaitAck(
      epoch: epoch,
      sessionId: sessionId,
      transferId: transferId,
      send: () => repository.sendFileUploadStart(
        FileUploadStartFrame(
          sessionId: sessionId,
          transferId: transferId,
          fileName: wireName,
          totalBytes: file.size,
        ),
      ),
    );
    if (readyAck == null || readyAck.status != .ready) {
      _reportRejection(readyAck, epoch);
      return false;
    }

    final digestSink = _ClientDigestSink();
    final hashSink = sha256.startChunkedConversion(digestSink);
    var offset = 0;
    while (offset < file.size) {
      if (_cancelled || epoch != _runEpoch) return false;
      final end = min(offset + chunkSizeBytes, file.size);
      final slice = await _readExpectedSlice(
        epoch,
        file,
        offset,
        end,
        sessionId,
        transferId,
        wireName,
      );
      if (slice == null) return false;
      hashSink.add(slice);
      final chunkAck = await _sendAndAwaitAck(
        epoch: epoch,
        sessionId: sessionId,
        transferId: transferId,
        send: () => repository.sendFileUploadChunk(
          FileUploadChunkFrame(
            sessionId: sessionId,
            transferId: transferId,
            offset: offset,
            data: slice,
          ),
        ),
      );
      if (chunkAck == null ||
          chunkAck.status != .chunkAck ||
          chunkAck.nextOffset != end) {
        _reportRejection(chunkAck, epoch);
        return false;
      }
      offset = end;
      _updateProgress(
        FileUploadProgress(
          fileIndex: fileIndex,
          fileCount: fileCount,
          currentFileName: wireName,
          overallSentBytes: completedBytesBeforeCurrent + offset,
          overallTotalBytes: overallTotalBytes,
        ),
      );
    }

    hashSink.close();
    final shaBytes = Uint8List.fromList(digestSink.value!.bytes);
    final completedAck = await _sendAndAwaitAck(
      epoch: epoch,
      sessionId: sessionId,
      transferId: transferId,
      send: () => repository.sendFileUploadEnd(
        FileUploadEndFrame(
          sessionId: sessionId,
          transferId: transferId,
          sha256: shaBytes,
        ),
      ),
    );
    if (completedAck == null || completedAck.status != .completed) {
      _reportRejection(completedAck, epoch);
      return false;
    }
    return true;
  }

  Future<Uint8List?> _readExpectedSlice(
    int epoch,
    DroppedFileSource file,
    int start,
    int end,
    SessionId sessionId,
    int transferId,
    String wireName,
  ) async {
    final Uint8List slice;
    try {
      slice = await file.readSlice(start, end);
    } on Object {
      if (!_cancelled && epoch == _runEpoch) {
        _sendAbortFrame(sessionId, transferId);
        onError('Failed to read dropped file "$wireName".');
      }
      return null;
    }
    if (_cancelled || epoch != _runEpoch) return null;
    if (slice.isEmpty || slice.length != end - start) {
      _sendAbortFrame(sessionId, transferId);
      onError('Failed to read dropped file "$wireName".');
      return null;
    }
    return slice;
  }

  Future<FileUploadAckFrame?> _sendAndAwaitAck({
    required int epoch,
    required SessionId sessionId,
    required int transferId,
    required void Function() send,
  }) {
    if (_cancelled || epoch != _runEpoch) {
      return Future<FileUploadAckFrame?>.value();
    }
    final completer = Completer<FileUploadAckFrame?>();
    final timer = Timer(ackTimeout, () {
      final active = _inFlight;
      if (active == null || !identical(active.completer, completer)) return;
      _inFlight = null;
      _sendAbortFrame(sessionId, transferId);
      if (!completer.isCompleted) {
        completer.complete(
          FileUploadAckFrame(
            sessionId: sessionId,
            transferId: transferId,
            status: .rejected,
            nextOffset: 0,
            message: 'Upload timed out waiting for caster acknowledgment.',
          ),
        );
      }
    });
    _inFlight = _InFlightTransfer(
      sessionId: sessionId,
      transferId: transferId,
      completer: completer,
      timer: timer,
    );
    send();
    return completer.future;
  }

  /// Handles an incoming [FileUploadAckFrame] from the relay server.
  void handleAckFrame(FileUploadAckFrame frame) {
    final active = _inFlight;
    if (active == null ||
        active.sessionId != frame.sessionId ||
        active.transferId != frame.transferId) {
      return;
    }
    _inFlight = null;
    active.cancelTimer();
    if (!active.completer.isCompleted) {
      active.completer.complete(frame);
    }
  }

  /// Cancels the active upload batch and transmits `FileUploadEndFrame(aborted: true)`.
  void cancel() {
    if (!isUploading && _inFlight == null && _activeTransfer == null) return;
    _runEpoch++;
    _cancelled = true;
    final active = _inFlight;
    final currentTransfer = _activeTransfer;
    _inFlight = null;
    _activeTransfer = null;
    active?.cancelTimer();
    if (currentTransfer != null) {
      _sendAbortFrame(currentTransfer.sessionId, currentTransfer.transferId);
    } else if (active != null) {
      _sendAbortFrame(active.sessionId, active.transferId);
    }
    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(null);
    }
    _updateProgress(null);
  }

  /// Aborts the active upload locally when the transport disconnects or session closes.
  void abortOnDisconnect([
    String reason = 'Upload interrupted by disconnect.',
  ]) {
    if (!isUploading && _inFlight == null && _activeTransfer == null) return;
    _runEpoch++;
    _cancelled = true;
    final active = _inFlight;
    _inFlight = null;
    _activeTransfer = null;
    active?.cancelTimer();
    if (active != null && !active.completer.isCompleted) {
      active.completer.complete(null);
    }
    _updateProgress(null);
    onError(reason);
  }

  void _sendAbortFrame(SessionId sessionId, int transferId) {
    repository.sendFileUploadEnd(
      FileUploadEndFrame(
        sessionId: sessionId,
        transferId: transferId,
        sha256: Uint8List(0),
        aborted: true,
      ),
    );
  }

  void _reportRejection(FileUploadAckFrame? ack, int epoch) {
    if (_cancelled || epoch != _runEpoch) return;
    final detail = ack?.message.trim() ?? '';
    onError(detail.isEmpty ? 'File upload rejected by caster.' : detail);
  }

  int _allocateTransferId() {
    final id = _nextTransferId;
    _nextTransferId = (_nextTransferId + 1) & 0x7FFFFFFF;
    if (_nextTransferId == 0) _nextTransferId = 1;
    return id;
  }

  void _updateProgress(FileUploadProgress? next) {
    if (identical(_progress, next)) return;
    _progress = next;
    onProgressChanged();
  }
}

final class _InFlightTransfer {
  final SessionId sessionId;
  final int transferId;
  final Completer<FileUploadAckFrame?> completer;
  final Timer timer;

  const _InFlightTransfer({
    required this.sessionId,
    required this.transferId,
    required this.completer,
    required this.timer,
  });

  void cancelTimer() => timer.cancel();
}

final class _ClientDigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
