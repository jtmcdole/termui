import 'dart:async';
import 'dart:collection';
import 'dart:math';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';

/// Zero-history registry routing live buffer frames, input, and resizes.
final class SessionRegistry {
  /// Maximum concurrent in-flight scrollback requests allowed per client per session.
  static const int maxInFlightScrollbackPerClient = 4;

  /// Maximum concurrent active file uploads allowed per client per session.
  static const int maxActiveUploadsPerClient = 1;

  /// Default duration before an unanswered scrollback request expires lazily.
  static const Duration defaultScrollbackRequestTimeout = Duration(seconds: 10);

  /// Default idle duration before an active file upload transfer expires lazily.
  static const Duration defaultUploadTimeout = Duration(seconds: 30);

  /// Default maximum session renames permitted per client within [defaultRenameRateWindow].
  static const int defaultMaxRenamesPerWindow = 4;

  /// Default sliding rate-limit window for client session renames.
  static const Duration defaultRenameRateWindow = Duration(seconds: 1);

  /// Maximum queued outbound frames per peer before slow-consumer eviction.
  final int maxOutboundFrames;

  /// Maximum queued outbound bytes per peer before slow-consumer eviction.
  final int maxOutboundBytes;

  /// Duration after which an unanswered scrollback request is lazily evicted.
  final Duration scrollbackRequestTimeout;

  /// Idle duration after which an unprogressed file upload transfer is aborted.
  final Duration uploadTimeout;

  /// Maximum session renames allowed per client within [renameRateWindow].
  final int maxRenamesPerWindow;

  /// Sliding window duration used to rate-limit client session renames.
  final Duration renameRateWindow;

  final Clock _clock;
  final Map<SessionId, _LiveSession> _sessions = {};
  final Set<CasterPeer> _casters = {};
  final Set<ClientPeer> _clients = {};

  /// Creates a stateless session registry.
  SessionRegistry({
    this.maxOutboundFrames = 64,
    this.maxOutboundBytes = 8 * 1024 * 1024,
    this.scrollbackRequestTimeout = defaultScrollbackRequestTimeout,
    this.uploadTimeout = defaultUploadTimeout,
    this.maxRenamesPerWindow = defaultMaxRenamesPerWindow,
    this.renameRateWindow = defaultRenameRateWindow,
    Clock clock = const Clock(),
  }) : _clock = clock;

  /// Current directory snapshot of registered live sessions.
  List<SessionSummary> get sessions => [
    for (final entry in _sessions.values) entry.toSummary(),
  ];

  /// Number of connected viewer clients currently registered.
  int get connectedClientCount => _clients.length;

  /// Creates a bounded outbound pump for a newly authenticated caster.
  CasterPeer registerCasterPeer({
    required StreamSink<Uint8List> sink,
    Future<void> Function(int code, String reason)? closeWithCode,
  }) {
    late final CasterPeer peer;
    final pump = _BoundedPeerPump(
      sink: sink,
      maxFrames: maxOutboundFrames,
      maxBytes: maxOutboundBytes,
      closeWithCode: closeWithCode,
      onEvict: () => detachCasterPeer(peer),
    );
    peer = CasterPeer._(pump);
    _casters.add(peer);
    pump.start();
    return peer;
  }

  /// Creates a bounded outbound pump for a newly authenticated viewer client.
  ClientPeer registerClientPeer({
    required StreamSink<Uint8List> sink,
    Future<void> Function(int code, String reason)? closeWithCode,
  }) {
    late final ClientPeer peer;
    final pump = _BoundedPeerPump(
      sink: sink,
      maxFrames: maxOutboundFrames,
      maxBytes: maxOutboundBytes,
      closeWithCode: closeWithCode,
      onEvict: () => detachClientPeer(peer),
    );
    peer = ClientPeer._(pump);
    _clients.add(peer);
    pump.start();
    return peer;
  }

  /// Registers a live PTY session owned by [caster], or performs seamless
  /// caster takeover when `frame.resumeToken` matches the live session's non-zero token.
  bool registerSession(CasterPeer caster, RegisterSessionFrame frame) {
    if (caster.sessionId != null) {
      _rejectDuplicateSession(caster, frame.sessionId);
      return false;
    }
    final existing = _sessions[frame.sessionId];
    if (existing != null) {
      if (!_matchesNonZeroResumeToken(
        existing.resumeToken,
        frame.resumeToken,
      )) {
        _rejectDuplicateSession(caster, frame.sessionId);
        return false;
      }
      _takeOverSession(existing, caster, frame);
      return true;
    }
    caster.sessionId = frame.sessionId;
    _sessions[frame.sessionId] = _LiveSession(
      id: frame.sessionId,
      initialTitle: frame.title,
      cols: frame.cols,
      rows: frame.rows,
      resumeToken: Uint8List.fromList(frame.resumeToken),
      caster: caster,
    );
    _broadcastDirectory();
    return true;
  }

  void _rejectDuplicateSession(CasterPeer caster, SessionId sessionId) {
    caster.sendMessage(
      ErrorFrame(
        code: 'duplicate_session',
        message: 'Session ${sessionId.value} is already registered',
      ),
    );
  }

  void _takeOverSession(
    _LiveSession session,
    CasterPeer newCaster,
    RegisterSessionFrame frame,
  ) {
    final oldCaster = session.caster;
    oldCaster.sessionId = null;
    detachCasterPeer(oldCaster);
    session.abortInFlightStateOnTakeover();
    session.caster = newCaster;
    newCaster.sessionId = session.id;
    session.cols = frame.cols;
    session.rows = frame.rows;
    session.lastSeq = null;

    if (session.subscribers.isEmpty) {
      session.clearRequestedSize();
    } else {
      session.awaitingKeyframe.addAll(session.subscribers);
      newCaster.sendMessage(
        SubscriberCountFrame(
          sessionId: session.id,
          subscriberCount: session.subscribers.length,
        ),
      );
      final (:cols, :rows) = session.effectiveMinSize();
      session.requestedCols = cols;
      session.requestedRows = rows;
      newCaster.sendMessage(
        ResizeFrame(sessionId: session.id, cols: cols, rows: rows),
      );
      newCaster.sendMessage(RequestKeyframeFrame(sessionId: session.id));
    }
    _syncTakeoverTitle(session, newCaster, frame.title);
    _broadcastDirectory();
  }

  void _syncTakeoverTitle(
    _LiveSession session,
    CasterPeer newCaster,
    String registeredTitle,
  ) {
    final pinned = session.pinnedTitle;
    if (pinned != null) {
      if (pinned != registeredTitle) {
        newCaster.sendMessage(
          RenameSessionFrame(sessionId: session.id, title: pinned),
        );
      }
      return;
    }
    if (session.displayTitle != registeredTitle) {
      newCaster.sendMessage(
        RenameSessionFrame(
          sessionId: session.id,
          title: session.displayTitle,
          clearPin: true,
        ),
      );
    }
  }

  /// Updates the display title or clears the pinned title of `frame.sessionId`,
  /// forwards [frame] to the owning caster, and broadcasts [SessionDirectoryFrame].
  bool renameSession(ClientPeer client, RenameSessionFrame frame) {
    if (!_clients.contains(client)) return false;
    final session = _sessions[frame.sessionId];
    if (session == null) {
      client.sendMessage(
        ErrorFrame(
          code: 'rename_rejected',
          message: 'Unknown session ${frame.sessionId.value}',
        ),
      );
      return false;
    }
    if (frame.clearPin) {
      return _clearSessionPin(client, session);
    }
    if (frame.title == session.pinnedTitle) return true;
    if (!_consumeRenameQuotaOrReject(client)) return false;
    session.pinnedTitle = frame.title;
    session.caster.sendMessage(frame);
    _broadcastDirectory();
    return true;
  }

  bool _clearSessionPin(ClientPeer client, _LiveSession session) {
    if (session.pinnedTitle == null) return true;
    if (!_consumeRenameQuotaOrReject(client)) return false;
    session.pinnedTitle = null;
    session.caster.sendMessage(
      RenameSessionFrame(
        sessionId: session.id,
        title: session.displayTitle,
        clearPin: true,
      ),
    );
    _broadcastDirectory();
    return true;
  }

  bool _consumeRenameQuotaOrReject(ClientPeer client) {
    final allowed = client._tryConsumeRenameQuota(
      _clock.now(),
      maxRenames: maxRenamesPerWindow,
      window: renameRateWindow,
    );
    if (!allowed) {
      client.sendMessage(
        const ErrorFrame(
          code: 'rename_rejected',
          message: 'Session rename rate limit exceeded',
        ),
      );
    }
    return allowed;
  }

  /// Updates the live shell title (`OSC 0`/`OSC 2`) for [caster]'s session,
  /// fans out [ShellTitleFrame] to subscribers, and broadcasts a directory
  /// update when the tab is not user-pinned.
  bool updateCasterShellTitle(CasterPeer caster, ShellTitleFrame frame) {
    final session = _lookupCasterSession(caster);
    if (session == null || frame.sessionId != session.id) return false;
    final clean = sanitizeShellTitle(frame.title);
    if (clean == session.shellTitle) return true;
    session.shellTitle = clean;
    if (session.subscribers.isNotEmpty) {
      final encoded = BufferFrameCodec.encode(
        ShellTitleFrame(sessionId: session.id, title: clean),
      );
      _fanOutDroppable(session, encoded);
    }
    if (session.pinnedTitle == null) {
      _broadcastDirectoryDroppable();
    }
    return true;
  }

  /// Validates and forwards a raw `0x18` [BellFrame] from [caster] to its
  /// subscribed clients zero-copy, dropping under outbound pressure.
  bool forwardCasterBellBytes(CasterPeer caster, Uint8List rawFrame) {
    final session = _lookupCasterSession(caster);
    if (session == null) return false;
    if (!BufferFrameCodec.inspectRelayBellFrame(
      rawFrame,
      expectedSession: session.id,
    )) {
      return false;
    }
    _fanOutDroppable(session, rawFrame);
    return true;
  }

  /// Validates and forwards a [BellFrame] from [caster] to its subscribed
  /// clients, dropping under outbound pressure.
  bool forwardCasterBell(
    CasterPeer caster,
    BellFrame frame, {
    Uint8List? rawBytes,
  }) {
    final session = _lookupCasterSession(caster);
    if (session == null || frame.sessionId != session.id) return false;
    if (session.subscribers.isEmpty) return true;
    _fanOutDroppable(session, rawBytes ?? BufferFrameCodec.encode(frame));
    return true;
  }

  /// Validates and forwards a raw `0x19` [AudioFrame] from [caster] to its
  /// subscribed clients without inflating compressed payloads, dropping for any
  /// subscriber under outbound backpressure so audio bursts never trigger `1008`.
  bool forwardCasterAudioBytes(CasterPeer caster, Uint8List rawFrame) {
    final session = _lookupCasterSession(caster);
    if (session == null) return false;
    if (!BufferFrameCodec.inspectRelayAudioFrame(
      rawFrame,
      expectedSession: session.id,
    )) {
      return false;
    }
    _fanOutDroppable(session, rawFrame);
    return true;
  }

  /// Validates and forwards an [AudioFrame] from [caster] to its subscribed
  /// clients, dropping on subscriber outbound pressure without triggering `1008`.
  bool forwardCasterAudio(
    CasterPeer caster,
    AudioFrame frame, {
    Uint8List? rawBytes,
  }) {
    final session = _lookupCasterSession(caster);
    if (session == null || frame.sessionId != session.id) return false;
    if (session.subscribers.isEmpty) return true;
    _fanOutDroppable(session, rawBytes ?? BufferFrameCodec.encode(frame));
    return true;
  }

  void _fanOutDroppable(_LiveSession session, Uint8List encoded) {
    if (session.subscribers.isEmpty) return;
    for (final subscriber in [...session.subscribers]) {
      if (subscriber._drainAndCheckOutboundPressure() ||
          !subscriber._pump.canFit(encoded.length)) {
        continue;
      }
      subscriber._pump.enqueue(encoded);
    }
  }

  /// Validates and forwards a live buffer frame (`0x09` or `0x0A`) from
  /// [caster] without storing history, returning `false` when invalid.
  bool forwardCasterBufferBytes(CasterPeer caster, Uint8List rawFrame) {
    final session = _lookupCasterSession(caster);
    if (session == null) return false;

    final info = BufferFrameCodec.inspectRelayBufferFrame(
      rawFrame,
      expectedSession: session.id,
    );
    if (info == null) return false;

    if (info.isSnapshot) {
      _forwardSnapshot(session, info.seq, info.cols, info.rows, rawFrame);
    } else {
      _forwardDelta(session, info.seq, rawFrame);
    }
    return true;
  }

  /// Validates and forwards a [ClipboardFrame] from [caster] to its subscribed clients.
  ///
  /// When [rawBytes] is provided by a caller that already decoded and validated
  /// [frame], those wire bytes are forwarded directly without re-encoding.
  bool forwardCasterClipboard(
    CasterPeer caster,
    ClipboardFrame frame, {
    Uint8List? rawBytes,
  }) {
    final session = _lookupCasterSession(caster);
    if (session == null || frame.sessionId != session.id) return false;
    if (session.subscribers.isEmpty) return true;
    final encoded = rawBytes ?? BufferFrameCodec.encode(frame);
    for (final subscriber in [...session.subscribers]) {
      subscriber._pump.enqueue(encoded);
    }
    return true;
  }

  /// Notifies all connected clients that [caster]'s session ended with [exitCode] and [reason].
  void closeCasterSession(
    CasterPeer caster,
    int exitCode, {
    required SessionCloseReason reason,
  }) {
    final sessionId = caster.sessionId;
    if (sessionId == null) return;
    final session = _sessions.remove(sessionId);
    caster.sessionId = null;
    if (session == null) return;

    session.scrollbackRequests.clear();
    session.uploadTransfers.clear();
    session.clientUploadTransferIds.clear();
    for (final subscriber in [...session.subscribers]) {
      subscriber._subscriptions.remove(sessionId);
      subscriber._inFlightScrollback.remove(sessionId);
      subscriber._activeUploads.remove(sessionId);
    }
    if (_clients.isNotEmpty) {
      final closedBytes = BufferFrameCodec.encode(
        SessionClosedFrame(
          sessionId: sessionId,
          reason: reason,
          exitCode: exitCode,
        ),
      );
      for (final client in [..._clients]) {
        client._pump.enqueue(closedBytes);
      }
    }
    _broadcastDirectory();
  }

  /// Detaches [caster] and notifies connected clients if its session was still open.
  void detachCasterPeer(CasterPeer caster, {bool closeSink = true}) {
    _casters.remove(caster);
    closeCasterSession(caster, -1, reason: .disconnected);
    caster._pump.detach(closeSink: closeSink);
  }

  /// Subscribes [client] to [frame]'s session, recomputes smallest-viewport
  /// sizing, and requests a fresh keyframe.
  void subscribeClient(ClientPeer client, SubscribeSessionFrame frame) {
    final session = _sessions[frame.sessionId];
    if (session == null) {
      client.sendMessage(
        ErrorFrame(
          code: 'unknown_session',
          message: 'Unknown session ${frame.sessionId.value}',
        ),
      );
      return;
    }

    final wasEmpty = session.subscribers.isEmpty;
    final added = session.subscribers.add(client);
    session.awaitingKeyframe.add(client);
    client._subscriptions.add(frame.sessionId);
    if (frame.cols > 0 && frame.rows > 0) {
      session.subscriberViewports[client] = (
        cols: frame.cols,
        rows: frame.rows,
      );
    }

    if (added) {
      session.caster.sendMessage(
        SubscriberCountFrame(
          sessionId: session.id,
          subscriberCount: session.subscribers.length,
        ),
      );
      if (session.shellTitle.isNotEmpty) {
        client.sendMessage(
          ShellTitleFrame(sessionId: session.id, title: session.shellTitle),
        );
      }
    }

    _dispatchSubscribeSizeAndKeyframe(session, wasEmpty: wasEmpty);
    _broadcastDirectory();
  }

  void _dispatchSubscribeSizeAndKeyframe(
    _LiveSession session, {
    required bool wasEmpty,
  }) {
    final (:cols, :rows) = session.effectiveMinSize();
    if (wasEmpty) {
      session.requestedCols = cols;
      session.requestedRows = rows;
      session.caster.sendMessage(
        ResizeFrame(sessionId: session.id, cols: cols, rows: rows),
      );
      session.caster.sendMessage(RequestKeyframeFrame(sessionId: session.id));
      return;
    }
    final sizeChanged =
        session.requestedCols != cols || session.requestedRows != rows;
    if (sizeChanged) {
      session.requestedCols = cols;
      session.requestedRows = rows;
      session.caster.sendMessage(
        ResizeFrame(sessionId: session.id, cols: cols, rows: rows),
      );
    }
    if (!sizeChanged || (cols == session.cols && rows == session.rows)) {
      session.caster.sendMessage(RequestKeyframeFrame(sessionId: session.id));
    }
  }

  /// Unsubscribes [client] from [sessionId] and restores larger dimensions when
  /// a smaller viewer leaves.
  void unsubscribeClient(ClientPeer client, SessionId sessionId) {
    client._subscriptions.remove(sessionId);
    client._inFlightScrollback.remove(sessionId);
    final session = _sessions[sessionId];
    if (session == null || !session.subscribers.remove(client)) {
      client._activeUploads.remove(sessionId);
      return;
    }
    session.subscriberViewports.remove(client);
    session.awaitingKeyframe.remove(client);
    session.scrollbackRequests.removeWhere(
      (_, entry) => identical(entry.client, client),
    );
    session.abortUploadTransfersForClient(client);
    client._activeUploads.remove(sessionId);

    session.caster.sendMessage(
      SubscriberCountFrame(
        sessionId: session.id,
        subscriberCount: session.subscribers.length,
      ),
    );
    _reconcileSizeAfterSubscriberRemoved(session);
    _broadcastDirectory();
  }

  void _reconcileSizeAfterSubscriberRemoved(_LiveSession session) {
    if (session.subscribers.isEmpty) {
      session.clearRequestedSize();
      return;
    }
    if (session.subscriberViewports.isEmpty) return;
    final (:cols, :rows) = session.effectiveMinSize();
    if (session.requestedCols == cols && session.requestedRows == rows) return;
    session.requestedCols = cols;
    session.requestedRows = rows;
    session.caster.sendMessage(
      ResizeFrame(sessionId: session.id, cols: cols, rows: rows),
    );
  }

  /// Routes [frame] from a subscribed [client] to the target caster.
  void forwardClientInput(ClientPeer client, InputFrame frame) {
    final session = _sessions[frame.sessionId];
    if (session == null || !session.subscribers.contains(client)) return;
    if (session.caster._drainAndCheckOutboundPressure()) {
      client.sendMessage(
        const ErrorFrame(
          code: 'caster_busy',
          message: 'Caster input queue is full; keystroke dropped.',
        ),
      );
      return;
    }
    session.caster.sendMessage(frame);
  }

  /// Forwards a client [AudioWaveformReplyFrame] to the owning caster when
  /// [client] is subscribed, dropping silently under caster outbound pressure.
  bool forwardClientWaveformReply(
    ClientPeer client,
    AudioWaveformReplyFrame frame, {
    Uint8List? rawBytes,
  }) {
    final session = _sessions[frame.sessionId];
    if (session == null || !session.subscribers.contains(client)) return false;
    final encoded = rawBytes ?? BufferFrameCodec.encode(frame);
    if (session.caster._drainAndCheckOutboundPressure() ||
        !session.caster._pump.canFit(encoded.length)) {
      return false;
    }
    session.caster._pump.enqueue(encoded);
    return true;
  }

  /// Records [client]'s viewport dimensions and forwards a [ResizeFrame] when
  /// the session's `min(cols, rows)` across active subscribers changes.
  void forwardClientResize(ClientPeer client, ResizeFrame frame) {
    final session = _sessions[frame.sessionId];
    if (session == null || !session.subscribers.contains(client)) return;

    session.subscriberViewports[client] = (cols: frame.cols, rows: frame.rows);
    final (:cols, :rows) = session.effectiveMinSize();
    if (session.requestedCols == cols && session.requestedRows == rows) return;

    session.requestedCols = cols;
    session.requestedRows = rows;
    session.caster.sendMessage(
      ResizeFrame(sessionId: session.id, cols: cols, rows: rows),
    );
  }

  /// Requests an immediate keyframe on [sessionId] when [client] is subscribed.
  void forwardKeyframeRequest(ClientPeer client, SessionId sessionId) {
    final session = _sessions[sessionId];
    if (session == null || !session.subscribers.contains(client)) return;
    final shouldRequest = session.awaitingKeyframe.isEmpty;
    session.awaitingKeyframe.add(client);
    if (shouldRequest) {
      session.caster.sendMessage(RequestKeyframeFrame(sessionId: sessionId));
    }
  }

  /// Forwards a [RequestScrollbackFrame] from [client] to the session caster,
  /// capping in-flight requests per `(client, session)` at
  /// [maxInFlightScrollbackPerClient].
  bool forwardScrollbackRequest(
    ClientPeer client,
    RequestScrollbackFrame frame,
  ) {
    final session = _sessions[frame.sessionId];
    if (session == null || !session.subscribers.contains(client)) return false;

    final now = _clock.now();
    session.evictExpiredScrollbackRequests(now);

    final inFlight = client._inFlightScrollback[frame.sessionId] ?? 0;
    if (inFlight >= maxInFlightScrollbackPerClient) return false;

    final relayReqId = session.allocateScrollbackRequestId();
    session.scrollbackRequests[relayReqId] = (
      client: client,
      clientRequestId: frame.requestId,
      expiresAt: now.add(scrollbackRequestTimeout),
    );
    client._inFlightScrollback[frame.sessionId] = inFlight + 1;
    session.caster.sendMessage(
      RequestScrollbackFrame(
        sessionId: session.id,
        requestId: relayReqId,
        clearSeq: frame.clearSeq,
        startLine: frame.startLine,
        count: frame.count,
      ),
    );
    return true;
  }

  /// Unicasts a raw `0x11` [ScrollbackChunkFrame] from [caster] exclusively to
  /// the subscribed [ClientPeer] that originated its `requestId` without
  /// inflating or re-compressing the scrollback rows.
  bool forwardCasterScrollbackChunkBytes(
    CasterPeer caster,
    Uint8List rawFrame,
  ) {
    final session = _lookupCasterSession(caster);
    if (session == null) return false;
    final relayReqId = BufferFrameCodec.inspectRelayScrollbackChunkRequestId(
      rawFrame,
      expectedSession: session.id,
    );
    if (relayReqId == null) return false;
    final pending = session.scrollbackRequests.remove(relayReqId);
    if (pending == null) return true;

    pending.client._decrementInFlightScrollback(session.id);
    if (!session.subscribers.contains(pending.client)) return true;

    final rewritten = BufferFrameCodec.rewriteScrollbackChunkRequestId(
      rawFrame,
      expectedSession: session.id,
      newRequestId: pending.clientRequestId,
    );
    if (rewritten == null) return false;
    pending.client._pump.enqueue(rewritten);
    return true;
  }

  /// Unicasts a [ScrollbackChunkFrame] from [caster] exclusively to the
  /// subscribed [ClientPeer] that originated `frame.requestId`.
  bool forwardCasterScrollbackChunk(
    CasterPeer caster,
    ScrollbackChunkFrame frame, {
    Uint8List? rawBytes,
  }) {
    final session = _lookupCasterSession(caster);
    if (session == null || frame.sessionId != session.id) return false;
    final pending = session.scrollbackRequests.remove(frame.requestId);
    if (pending == null) return true;

    pending.client._decrementInFlightScrollback(session.id);
    if (!session.subscribers.contains(pending.client)) return true;

    if (rawBytes != null) {
      final rewritten = BufferFrameCodec.rewriteScrollbackChunkRequestId(
        rawBytes,
        expectedSession: session.id,
        newRequestId: pending.clientRequestId,
      );
      if (rewritten != null) {
        pending.client._pump.enqueue(rewritten);
        return true;
      }
    }
    pending.client.sendMessage(
      ScrollbackChunkFrame(
        sessionId: session.id,
        requestId: pending.clientRequestId,
        clearSeq: frame.clearSeq,
        startLine: frame.startLine,
        rows: frame.rows,
      ),
    );
    return true;
  }

  /// Forwards a [FileUploadStartFrame] from [client] to the session caster,
  /// capping active uploads per `(client, session)` at
  /// [maxActiveUploadsPerClient] and assigning a collision-free relay transfer ID.
  bool forwardFileUploadStart(ClientPeer client, FileUploadStartFrame frame) {
    final session = _sessions[frame.sessionId];
    if (session == null || !session.subscribers.contains(client)) return false;

    final now = _clock.now();
    session.evictExpiredUploadTransfers(now);

    final activeCount = client._activeUploads[frame.sessionId] ?? 0;
    final duplicateClientId = session.clientUploadTransferIds.containsKey((
      client,
      frame.transferId,
    ));
    if (activeCount >= maxActiveUploadsPerClient || duplicateClientId) {
      client.sendMessage(
        FileUploadAckFrame(
          sessionId: session.id,
          transferId: frame.transferId,
          status: .rejected,
          nextOffset: 0,
          message: 'Maximum active uploads exceeded for this session.',
        ),
      );
      return false;
    }

    final relayTransferId = session.allocateUploadTransferId();
    final transfer = _ActiveUploadTransfer(
      client: client,
      clientTransferId: frame.transferId,
      relayTransferId: relayTransferId,
      expiresAt: now.add(uploadTimeout),
    );
    session.uploadTransfers[relayTransferId] = transfer;
    session.clientUploadTransferIds[(client, frame.transferId)] =
        relayTransferId;
    client._activeUploads[frame.sessionId] = activeCount + 1;
    session.caster.sendMessage(
      FileUploadStartFrame(
        sessionId: session.id,
        transferId: relayTransferId,
        fileName: frame.fileName,
        totalBytes: frame.totalBytes,
      ),
    );
    return true;
  }

  /// Forwards a [FileUploadChunkFrame] from [client] to the session caster
  /// using the active relay transfer ID and refreshes the idle expiry deadline.
  bool forwardFileUploadChunk(ClientPeer client, FileUploadChunkFrame frame) {
    final now = _clock.now();
    final resolved = _resolveActiveUploadTransfer(
      client,
      frame.sessionId,
      frame.transferId,
      now,
    );
    if (resolved == null) return false;
    final (session, transfer) = resolved;
    if (session.caster._drainAndCheckOutboundPressure()) {
      // Omit FileUploadEndFrame(aborted: true) while caster pump is pressured to avoid triggering _evictSlowConsumer at 64 frames; caster's 30s idle upload sweep cleans up.
      session.removeUploadTransfer(transfer.relayTransferId);
      client.sendMessage(
        FileUploadAckFrame(
          sessionId: session.id,
          transferId: transfer.clientTransferId,
          status: .rejected,
          nextOffset: 0,
          message: 'Caster input queue is full; upload aborted.',
        ),
      );
      return false;
    }

    transfer.expiresAt = now.add(uploadTimeout);
    session.caster.sendMessage(
      FileUploadChunkFrame(
        sessionId: session.id,
        transferId: transfer.relayTransferId,
        offset: frame.offset,
        data: frame.data,
      ),
    );
    return true;
  }

  /// Forwards a [FileUploadEndFrame] from [client] to the session caster,
  /// releasing the relay transfer entry immediately when [FileUploadEndFrame.aborted] is `true`.
  bool forwardFileUploadEnd(ClientPeer client, FileUploadEndFrame frame) {
    final now = _clock.now();
    final resolved = _resolveActiveUploadTransfer(
      client,
      frame.sessionId,
      frame.transferId,
      now,
    );
    if (resolved == null) return false;
    final (session, transfer) = resolved;

    if (frame.aborted) {
      session.removeUploadTransfer(transfer.relayTransferId);
    } else {
      transfer.expiresAt = now.add(uploadTimeout);
    }
    session.caster.sendMessage(
      FileUploadEndFrame(
        sessionId: session.id,
        transferId: transfer.relayTransferId,
        sha256: frame.sha256,
        aborted: frame.aborted,
      ),
    );
    return true;
  }

  (_LiveSession, _ActiveUploadTransfer)? _resolveActiveUploadTransfer(
    ClientPeer client,
    SessionId sessionId,
    int clientTransferId,
    DateTime now,
  ) {
    final session = _sessions[sessionId];
    if (session == null || !session.subscribers.contains(client)) return null;
    session.evictExpiredUploadTransfers(now);
    final relayTransferId =
        session.clientUploadTransferIds[(client, clientTransferId)];
    if (relayTransferId == null) return null;
    final transfer = session.uploadTransfers[relayTransferId];
    return transfer == null ? null : (session, transfer);
  }

  /// Unicasts a [FileUploadAckFrame] from [caster] exclusively to the
  /// subscribed [ClientPeer] that originated `frame.transferId`.
  bool forwardCasterFileUploadAck(CasterPeer caster, FileUploadAckFrame frame) {
    final session = _lookupCasterSession(caster);
    if (session == null || frame.sessionId != session.id) return false;

    final now = _clock.now();
    session.evictExpiredUploadTransfers(now);

    final transfer = session.uploadTransfers[frame.transferId];
    if (transfer == null) return true;

    final isTerminal = frame.status == .completed || frame.status == .rejected;
    if (isTerminal) {
      session.removeUploadTransfer(frame.transferId);
    } else {
      transfer.expiresAt = now.add(uploadTimeout);
    }
    if (!session.subscribers.contains(transfer.client)) return true;

    transfer.client.sendMessage(
      FileUploadAckFrame(
        sessionId: session.id,
        transferId: transfer.clientTransferId,
        status: frame.status,
        nextOffset: frame.nextOffset,
        message: frame.message,
      ),
    );
    return true;
  }

  /// Detaches [client] from all subscribed sessions and closes its outbound pump.
  void detachClientPeer(ClientPeer client, {bool closeSink = true}) {
    if (!_clients.remove(client)) return;
    final unsubscribed = {...client._subscriptions};
    for (final sessionId in unsubscribed) {
      unsubscribeClient(client, sessionId);
    }
    if (_clients.isEmpty) {
      for (final session in [..._sessions.values]) {
        if (!unsubscribed.contains(session.id) && session.subscribers.isEmpty) {
          session.caster.sendMessage(
            SubscriberCountFrame(sessionId: session.id, subscriberCount: 0),
          );
        }
      }
    }
    client._pump.detach(closeSink: closeSink);
  }

  /// Disposes all active peer pumps and clears the registry.
  Future<void> close() async {
    final liveCasters = [..._casters];
    final liveClients = [..._clients];
    _sessions.clear();
    _casters.clear();
    _clients.clear();
    await [
      for (final caster in liveCasters) caster._pump.shutdown(),
      for (final client in liveClients) client._pump.shutdown(),
    ].wait;
  }

  _LiveSession? _lookupCasterSession(CasterPeer caster) {
    final sessionId = caster.sessionId;
    if (sessionId == null) return null;
    final session = _sessions[sessionId];
    if (session == null || !identical(session.caster, caster)) return null;
    return session;
  }

  void _forwardSnapshot(
    _LiveSession session,
    int seq,
    int cols,
    int rows,
    Uint8List rawFrame,
  ) {
    final dimsChanged = session.cols != cols || session.rows != rows;
    session.cols = cols;
    session.rows = rows;
    if (session.subscribers.isEmpty) {
      session.clearRequestedSize();
    } else if (dimsChanged && session.subscriberViewports.isEmpty) {
      session.requestedCols = cols;
      session.requestedRows = rows;
    }
    final unicastOnly =
        !dimsChanged &&
        session.lastSeq == seq &&
        session.awaitingKeyframe.isNotEmpty;
    session.lastSeq = seq;
    final targets = unicastOnly
        ? [...session.awaitingKeyframe]
        : [...session.subscribers];
    session.awaitingKeyframe.removeAll(targets);
    for (final subscriber in targets) {
      subscriber._pump.enqueue(rawFrame);
    }
    if (dimsChanged) _broadcastDirectory();
  }

  void _forwardDelta(_LiveSession session, int seq, Uint8List rawFrame) {
    session.lastSeq = seq;
    final targets = [
      for (final subscriber in session.subscribers)
        if (!session.awaitingKeyframe.contains(subscriber)) subscriber,
    ];
    for (final subscriber in targets) {
      subscriber._pump.enqueue(rawFrame);
    }
  }

  void _broadcastDirectory() => _broadcastDirectoryBytes(droppable: false);

  void _broadcastDirectoryDroppable() =>
      _broadcastDirectoryBytes(droppable: true);

  void _broadcastDirectoryBytes({required bool droppable}) {
    if (_clients.isEmpty) return;
    final bytes = BufferFrameCodec.encode(
      SessionDirectoryFrame(sessions: sessions),
    );
    for (final client in [..._clients]) {
      if (droppable &&
          (client._drainAndCheckOutboundPressure() ||
              !client._pump.canFit(bytes.length))) {
        continue;
      }
      client._pump.enqueue(bytes);
    }
  }
}

/// Authenticated caster handle managed by [SessionRegistry].
final class CasterPeer {
  final _BoundedPeerPump _pump;

  /// Registered session identifier once `RegisterSessionFrame` succeeds.
  SessionId? sessionId;

  CasterPeer._(this._pump);

  /// Number of outbound frames currently buffered waiting for socket drain.
  int get queuedFrames => _pump.queuedFrames;

  /// Number of outbound bytes currently buffered waiting for socket drain.
  int get queuedBytes => _pump.queuedBytes;

  bool _drainAndCheckOutboundPressure() => _pump.drainAndCheckHighWaterMark();

  /// Encodes and enqueues [message] to this caster.
  void sendMessage(CastMessage message) {
    _pump.enqueue(BufferFrameCodec.encode(message));
  }
}

/// Authenticated viewer client handle managed by [SessionRegistry].
final class ClientPeer {
  final _BoundedPeerPump _pump;
  final Set<SessionId> _subscriptions = {};
  final Map<SessionId, int> _inFlightScrollback = {};
  final Map<SessionId, int> _activeUploads = {};
  final Queue<DateTime> _renameTimestamps = Queue<DateTime>();

  ClientPeer._(this._pump);

  bool _drainAndCheckOutboundPressure() => _pump.drainAndCheckHighWaterMark();

  bool _tryConsumeRenameQuota(
    DateTime now, {
    required int maxRenames,
    required Duration window,
  }) {
    if (maxRenames <= 0) return false;
    while (_renameTimestamps.isNotEmpty &&
        !now.isBefore(_renameTimestamps.first.add(window))) {
      _renameTimestamps.removeFirst();
    }
    if (_renameTimestamps.length >= maxRenames) return false;
    _renameTimestamps.addLast(now);
    return true;
  }

  void _decrementInFlightScrollback(SessionId sessionId) {
    final current = _inFlightScrollback[sessionId];
    if (current == null || current <= 1) {
      _inFlightScrollback.remove(sessionId);
      return;
    }
    _inFlightScrollback[sessionId] = current - 1;
  }

  void _decrementActiveUploads(SessionId sessionId) {
    final current = _activeUploads[sessionId];
    if (current == null || current <= 1) {
      _activeUploads.remove(sessionId);
      return;
    }
    _activeUploads[sessionId] = current - 1;
  }

  /// Encodes and enqueues [message] to this client.
  void sendMessage(CastMessage message) {
    _pump.enqueue(BufferFrameCodec.encode(message));
  }
}

typedef _PendingScrollbackRequest = ({
  ClientPeer client,
  int clientRequestId,
  DateTime expiresAt,
});

final class _ActiveUploadTransfer {
  final ClientPeer client;
  final int clientTransferId;
  final int relayTransferId;
  DateTime expiresAt;

  _ActiveUploadTransfer({
    required this.client,
    required this.clientTransferId,
    required this.relayTransferId,
    required this.expiresAt,
  });
}

bool _matchesNonZeroResumeToken(Uint8List expected, Uint8List candidate) {
  if (expected.length != RegisterSessionFrame.resumeTokenByteLength ||
      candidate.length != expected.length) {
    return false;
  }
  var diff = 0;
  var nonZero = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected[i] ^ candidate[i];
    nonZero |= expected[i];
  }
  return diff == 0 && nonZero != 0;
}

final class _LiveSession {
  final SessionId id;
  final String initialTitle;
  String shellTitle = '';
  String? pinnedTitle;
  int cols;
  int rows;
  int? requestedCols;
  int? requestedRows;
  int? lastSeq;
  final Uint8List resumeToken;
  CasterPeer caster;
  final Set<ClientPeer> subscribers = {};
  final Map<ClientPeer, ({int cols, int rows})> subscriberViewports = {};
  final Set<ClientPeer> awaitingKeyframe = {};
  final Map<int, _PendingScrollbackRequest> scrollbackRequests = {};
  final Map<int, _ActiveUploadTransfer> uploadTransfers = {};
  final Map<(ClientPeer, int), int> clientUploadTransferIds = {};
  int _nextScrollbackRequestId = 1;
  int _nextUploadTransferId = 1;

  _LiveSession({
    required this.id,
    required this.initialTitle,
    required this.cols,
    required this.rows,
    required this.resumeToken,
    required this.caster,
  });

  String get effectiveShellTitle =>
      shellTitle.isNotEmpty ? shellTitle : initialTitle;

  String get displayTitle => pinnedTitle ?? effectiveShellTitle;

  bool get isUserPinned => pinnedTitle != null;

  void clearRequestedSize() {
    requestedCols = null;
    requestedRows = null;
  }

  ({int cols, int rows}) effectiveMinSize() {
    if (subscriberViewports.isEmpty) {
      return (cols: cols, rows: rows);
    }
    var minCols = subscriberViewports.values.first.cols;
    var minRows = subscriberViewports.values.first.rows;
    for (final vp in subscriberViewports.values) {
      minCols = min(minCols, vp.cols);
      minRows = min(minRows, vp.rows);
    }
    return (cols: minCols, rows: minRows);
  }

  void abortInFlightStateOnTakeover() {
    for (final entry in scrollbackRequests.values) {
      entry.client._decrementInFlightScrollback(id);
    }
    scrollbackRequests.clear();
    _abortUploadTransfersWhere(
      (_) => true,
      notifyClientRejected: true,
      notifyCasterAborted: false,
      rejectMessage: 'File upload interrupted by caster reconnect.',
    );
  }

  int allocateScrollbackRequestId() {
    while (scrollbackRequests.containsKey(_nextScrollbackRequestId)) {
      _nextScrollbackRequestId = (_nextScrollbackRequestId + 1) & 0x7FFFFFFF;
    }
    final id = _nextScrollbackRequestId;
    _nextScrollbackRequestId = (_nextScrollbackRequestId + 1) & 0x7FFFFFFF;
    return id;
  }

  int allocateUploadTransferId() {
    while (uploadTransfers.containsKey(_nextUploadTransferId) ||
        _nextUploadTransferId == 0) {
      _nextUploadTransferId = (_nextUploadTransferId + 1) & 0x7FFFFFFF;
    }
    final id = _nextUploadTransferId;
    _nextUploadTransferId = (_nextUploadTransferId + 1) & 0x7FFFFFFF;
    return id;
  }

  void removeUploadTransfer(int relayTransferId) {
    final entry = uploadTransfers.remove(relayTransferId);
    if (entry == null) return;
    clientUploadTransferIds.remove((entry.client, entry.clientTransferId));
    entry.client._decrementActiveUploads(id);
  }

  void abortUploadTransfersForClient(ClientPeer client) {
    _abortUploadTransfersWhere(
      (entry) => identical(entry.client, client),
      notifyClientRejected: false,
    );
  }

  void evictExpiredScrollbackRequests(DateTime now) {
    scrollbackRequests.removeWhere((_, entry) {
      if (now.isBefore(entry.expiresAt)) return false;
      entry.client._decrementInFlightScrollback(id);
      return true;
    });
  }

  void evictExpiredUploadTransfers(DateTime now) {
    _abortUploadTransfersWhere(
      (entry) => !now.isBefore(entry.expiresAt),
      notifyClientRejected: true,
    );
  }

  void _abortUploadTransfersWhere(
    bool Function(_ActiveUploadTransfer entry) test, {
    required bool notifyClientRejected,
    bool notifyCasterAborted = true,
    String rejectMessage = 'File upload timed out on relay.',
  }) {
    final matched = [
      for (final entry in uploadTransfers.values)
        if (test(entry)) entry,
    ];
    for (final entry in matched) {
      removeUploadTransfer(entry.relayTransferId);
      if (notifyCasterAborted) {
        caster.sendMessage(
          FileUploadEndFrame(
            sessionId: id,
            transferId: entry.relayTransferId,
            sha256: Uint8List(0),
            aborted: true,
          ),
        );
      }
      if (notifyClientRejected && subscribers.contains(entry.client)) {
        entry.client.sendMessage(
          FileUploadAckFrame(
            sessionId: id,
            transferId: entry.clientTransferId,
            status: .rejected,
            nextOffset: 0,
            message: rejectMessage,
          ),
        );
      }
    }
  }

  SessionSummary toSummary() => SessionSummary(
    id: id,
    title: displayTitle,
    cols: cols,
    rows: rows,
    subscriberCount: subscribers.length,
    isUserPinned: isUserPinned,
  );
}

final class _BoundedPeerPump {
  final StreamSink<Uint8List> sink;
  final int maxFrames;
  final int maxBytes;
  final Future<void> Function(int code, String reason)? closeWithCode;
  final void Function() onEvict;

  late final _OutboundFrameStream _stream = _OutboundFrameStream();
  Future<void>? _pumpFuture;
  bool _closed = false;

  _BoundedPeerPump({
    required this.sink,
    required this.maxFrames,
    required this.maxBytes,
    required this.closeWithCode,
    required this.onEvict,
  });

  void start() {
    _pumpFuture = sink.addStream(_stream).catchError((Object _) {});
  }

  int get queuedFrames => _stream.queuedFrames;

  int get queuedBytes => _stream.queuedBytes;

  bool canFit(int frameBytes) =>
      !_closed &&
      _stream.queuedFrames + 1 <= maxFrames &&
      _stream.queuedBytes + frameBytes <= maxBytes;

  bool drainAndCheckHighWaterMark() {
    _stream.drainIfReady();
    final frameLimit = (maxFrames * 3) ~/ 4;
    final byteLimit = (maxBytes * 3) ~/ 4;
    return (frameLimit > 0 && queuedFrames >= frameLimit) ||
        (byteLimit > 0 && queuedBytes >= byteLimit);
  }

  bool enqueue(Uint8List frame) {
    if (_closed) return false;
    final accepted = _stream.tryPush(
      frame,
      maxFrames: maxFrames,
      maxBytes: maxBytes,
    );
    if (!accepted) {
      unawaited(_evictSlowConsumer());
    }
    return accepted;
  }

  Future<void> _evictSlowConsumer() async {
    if (_closed) return;
    _closed = true;
    _stream.finishImmediately();
    onEvict();
    await _closeSinkWithCode(1008, 'Outbound frame queue overflow');
  }

  void detach({required bool closeSink}) {
    if (_closed) return;
    _closed = true;
    _stream.finishImmediately();
    if (closeSink) {
      unawaited(_closeRawSink());
    }
  }

  Future<void> shutdown() async {
    if (_closed) return;
    _closed = true;
    _stream.finishImmediately();
    await _closeSinkWithCode(1001, 'Server shutting down');
  }

  Future<void> _closeSinkWithCode(int code, String reason) async {
    final pump = _pumpFuture;
    if (pump != null) {
      await pump;
    }
    final closer = closeWithCode;
    try {
      if (closer != null) {
        await closer(code, reason);
      } else {
        unawaited(sink.close().catchError((Object _) {}));
      }
    } on Object catch (_) {}
  }

  Future<void> _closeRawSink() async {
    final pump = _pumpFuture;
    if (pump != null) {
      await pump;
    }
    try {
      unawaited(sink.close().catchError((Object _) {}));
    } on Object catch (_) {}
  }
}

final class _OutboundFrameStream extends Stream<Uint8List> {
  final Queue<Uint8List> _queue = Queue<Uint8List>();
  int _queuedBytes = 0;
  void Function(Uint8List)? _onData;
  void Function()? _onDone;
  bool _paused = false;
  bool _draining = false;
  bool _delivering = false;
  bool _finished = false;

  bool get _canDrainNow =>
      !_delivering && !_paused && !_finished && _onData != null;

  int get queuedFrames => _queue.length;

  int get queuedBytes => _queuedBytes;

  void drainIfReady() {
    if (_canDrainNow && _queue.isNotEmpty) {
      _drainLoop();
    }
  }

  bool tryPush(
    Uint8List frame, {
    required int maxFrames,
    required int maxBytes,
  }) {
    if (_finished) return false;
    drainIfReady();
    if (_canDrainNow && _queue.isEmpty && frame.length <= maxBytes) {
      _deliverOne(frame);
      return true;
    }
    if (_queue.length >= maxFrames || _queuedBytes + frame.length > maxBytes) {
      return false;
    }
    _queue.addLast(frame);
    _queuedBytes += frame.length;
    _scheduleDrain();
    return true;
  }

  void finishImmediately() {
    if (_finished) return;
    _finished = true;
    _queue.clear();
    _queuedBytes = 0;
    final done = _onDone;
    _onDone = null;
    _onData = null;
    done?.call();
  }

  void _deliverOne(Uint8List frame) {
    _delivering = true;
    try {
      _onData!(frame);
    } finally {
      _delivering = false;
    }
    _scheduleDrain();
  }

  void _scheduleDrain() {
    if (_draining || _delivering || _paused || _finished || _onData == null) {
      return;
    }
    if (_queue.isEmpty) return;
    _draining = true;
    scheduleMicrotask(_drainLoop);
  }

  void _drainLoop() {
    if (_delivering) return;
    _draining = false;
    _delivering = true;
    try {
      while (!_paused && !_finished && _onData != null && _queue.isNotEmpty) {
        final frame = _queue.removeFirst();
        _queuedBytes -= frame.length;
        _onData!(frame);
      }
    } finally {
      _delivering = false;
    }
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onData = onData;
    _onDone = onDone;
    if (_finished) {
      scheduleMicrotask(() => onDone?.call());
    } else {
      _scheduleDrain();
    }
    return _OutboundSubscription(this);
  }
}

final class _OutboundSubscription implements StreamSubscription<Uint8List> {
  final _OutboundFrameStream _owner;
  int _pauseCount = 0;

  _OutboundSubscription(this._owner);

  @override
  bool get isPaused => _pauseCount > 0;

  @override
  void pause([Future<void>? resumeSignal]) {
    _pauseCount++;
    _owner._paused = true;
    resumeSignal?.whenComplete(resume);
  }

  @override
  void resume() {
    if (_pauseCount > 0) _pauseCount--;
    if (_pauseCount == 0) {
      _owner._paused = false;
      _owner.drainIfReady();
      _owner._scheduleDrain();
    }
  }

  @override
  Future<void> cancel() async {
    _owner._onData = null;
    _owner._onDone = null;
    _owner._finished = true;
    _owner._queue.clear();
  }

  @override
  Future<E> asFuture<E>([E? futureValue]) => Completer<E>().future;

  @override
  void onData(void Function(Uint8List data)? handleData) {
    _owner._onData = handleData;
  }

  @override
  void onDone(void Function()? handleDone) {
    _owner._onDone = handleDone;
  }

  @override
  void onError(Function? handleError) {}
}
