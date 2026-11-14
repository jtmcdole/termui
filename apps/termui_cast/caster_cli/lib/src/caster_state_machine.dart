import 'dart:math';

import 'package:hierarchical_state_machine/hierarchical_state_machine.dart';

/// States of the caster connection lifecycle HSM.
enum CasterLifecycleState {
  /// Top-level composite root state.
  root,

  /// Initial unstarted state.
  idle,

  /// Opening WebSocket transport and awaiting `AuthAcceptedFrame`.
  connecting,

  /// Authenticated and registered with the relay server.
  streaming,

  /// Waiting for jittered backoff before reconnecting.
  reconnectBackoff,

  /// Terminal state after child exit or explicit stop.
  terminated,
}

/// Events driving [CasterConnectionMachine].
enum CasterLifecycleEvent {
  /// Begin initial connection attempt.
  start,

  /// Handshake and session registration succeeded.
  connected,

  /// Connection or handshake failed.
  connectionFailed,

  /// Active transport closed while child process is still running.
  disconnected,

  /// Backoff timer elapsed; ready to retry connection.
  retryTimerFired,

  /// Force an immediate reconnect check-in and reset backoff attempts.
  checkIn,

  /// Child process exited or service was stopped.
  stop,
}

/// Hierarchical state machine governing caster connection and jittered backoff.
final class CasterConnectionMachine {
  final Random _random;
  final Duration _baseDelay;
  final Duration _maxDelay;
  late final Machine<CasterLifecycleState, CasterLifecycleEvent> _machine;
  CasterLifecycleState _activeLeaf = .idle;
  int _reconnectAttempt = 0;

  /// Creates a caster connection state machine.
  CasterConnectionMachine({
    Random? random,
    Duration baseDelay = const Duration(milliseconds: 200),
    Duration maxDelay = const Duration(seconds: 10),
  }) : _random = random ?? Random(),
       _baseDelay = baseDelay,
       _maxDelay = maxDelay {
    final blueprint =
        MachineBlueprint<CasterLifecycleState, CasterLifecycleEvent>(
          name: 'caster-connection',
          root: .composite(
            id: .root,
            initial: .idle,
            on: {.stop: .to(target: .terminated)},
            children: [
              .composite(
                id: .idle,
                entry: _enterIdle,
                on: {.start: .to(target: .connecting)},
              ),
              .composite(
                id: .connecting,
                entry: _enterConnecting,
                on: {
                  .connected: .to(target: .streaming, action: _resetAttempts),
                  .connectionFailed: .to(
                    target: .reconnectBackoff,
                    action: _incrementAttempts,
                  ),
                  .disconnected: .to(
                    target: .reconnectBackoff,
                    action: _incrementAttempts,
                  ),
                  .checkIn: .to(target: .connecting, action: _resetAttempts),
                },
              ),
              .composite(
                id: .streaming,
                entry: _enterStreaming,
                on: {
                  .disconnected: .to(
                    target: .reconnectBackoff,
                    action: _incrementAttempts,
                  ),
                  .checkIn: .to(target: .connecting, action: _resetAttempts),
                },
              ),
              .composite(
                id: .reconnectBackoff,
                entry: _enterBackoff,
                on: {
                  .retryTimerFired: .to(target: .connecting),
                  .checkIn: .to(target: .connecting, action: _resetAttempts),
                },
              ),
              .composite(id: .terminated, entry: _enterTerminated),
            ],
          ),
        );
    final (compiled, _) = blueprint.compile();
    _machine = compiled!..start();
  }

  void _enterIdle() => _activeLeaf = .idle;
  void _enterConnecting() => _activeLeaf = .connecting;
  void _enterStreaming() => _activeLeaf = .streaming;
  void _enterBackoff() => _activeLeaf = .reconnectBackoff;
  void _enterTerminated() => _activeLeaf = .terminated;

  void _resetAttempts(CasterLifecycleEvent? _, Object? _) {
    _reconnectAttempt = 0;
  }

  void _incrementAttempts(CasterLifecycleEvent? _, Object? _) {
    _reconnectAttempt++;
  }

  /// Active leaf state of the connection machine.
  CasterLifecycleState get state => _activeLeaf;

  /// Consecutive failed reconnect attempts since last successful stream.
  int get reconnectAttempt => _reconnectAttempt;

  /// Computes the next jittered backoff delay.
  Duration nextBackoffDelay() {
    final shift = (_reconnectAttempt - 1).clamp(0, 10);
    final cappedMs = min(
      _maxDelay.inMilliseconds,
      _baseDelay.inMilliseconds * (1 << shift),
    );
    final jitterFactor = 0.5 + _random.nextDouble() * 0.5;
    final delayMs = max(1, (cappedMs * jitterFactor).round());
    return Duration(milliseconds: delayMs);
  }

  /// Dispatches [event] to the underlying `Machine` and awaits settlement.
  Future<bool> dispatch(CasterLifecycleEvent event) => _machine.handle(event);

  /// Halts the state machine.
  void dispose() {
    _machine.stop();
  }
}
