import 'dart:async';
import 'package:termui/termui.dart';

/// The state of connection to an asynchronous computation.
enum ConnectionState {
  /// Not currently connected to any asynchronous computation.
  none,

  /// Connected to an asynchronous computation and awaiting interaction.
  waiting,

  /// Connected to an active asynchronous computation.
  active,

  /// Connected to a terminated asynchronous computation.
  done,
}

/// Immutable representation of the most recent interaction with an asynchronous computation.
class AsyncSnapshot<T> {
  /// Current state of connection to the asynchronous computation.
  final ConnectionState connectionState;

  /// The latest data received by the asynchronous computation.
  final T? data;

  /// The latest error received by the asynchronous computation.
  final Object? error;

  const AsyncSnapshot._(this.connectionState, this.data, this.error);

  /// Creates an [AsyncSnapshot] in [ConnectionState.none] with null data and error.
  const AsyncSnapshot.nothing() : this._(ConnectionState.none, null, null);

  /// Creates an [AsyncSnapshot] in [ConnectionState.waiting] with null data and error.
  const AsyncSnapshot.waiting() : this._(ConnectionState.waiting, null, null);

  /// Creates an [AsyncSnapshot] in the specified [state] and with the specified [data].
  const AsyncSnapshot.withData(ConnectionState state, T data)
    : this._(state, data, null);

  /// Creates an [AsyncSnapshot] in the specified [state] and with the specified [error].
  const AsyncSnapshot.withError(ConnectionState state, Object error)
    : this._(state, null, error);

  /// Returns whether this snapshot contains a non-null [data] value.
  bool get hasData => data != null;

  /// Returns whether this snapshot contains a non-null [error] value.
  bool get hasError => error != null;

  /// Returns a copy of this snapshot in the given [state].
  AsyncSnapshot<T> inState(ConnectionState state) =>
      AsyncSnapshot<T>._(state, data, error);
}

/// Widget that builds itself based on the latest snapshot of interaction with a [Stream].
class StreamBuilder<T> extends StatefulWidget {
  /// The asynchronous computation to which this builder is currently connected.
  final Stream<T>? stream;

  /// The data that will be used to create the initial snapshot.
  final T? initialData;

  /// The build strategy currently used by this builder.
  final Widget Function(BuildContext context, AsyncSnapshot<T> snapshot)
  builder;

  /// Creates a new [StreamBuilder] that builds itself based on the latest
  /// snapshot of interaction with the specified [stream] and whose build
  /// strategy is given by [builder].
  const StreamBuilder({
    super.key,
    this.stream,
    this.initialData,
    required this.builder,
  });

  @override
  State<StreamBuilder<T>> createState() => _StreamBuilderState<T>();
}

class _StreamBuilderState<T> extends State<StreamBuilder<T>> {
  StreamSubscription<T>? _subscription;
  late AsyncSnapshot<T> _summary;

  @override
  void initState() {
    super.initState();
    _summary = widget.initialData != null
        ? AsyncSnapshot<T>.withData(
            ConnectionState.none,
            widget.initialData as T,
          )
        : AsyncSnapshot<T>.nothing();
    _subscribe();
  }

  @override
  void didUpdateWidget(StreamBuilder<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stream != widget.stream) {
      if (_subscription != null) {
        _unsubscribe();
        _summary = _summary.inState(ConnectionState.none);
      }
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _subscribe() {
    if (widget.stream != null) {
      _subscription = widget.stream!.listen(
        (data) {
          setState(() {
            _summary = AsyncSnapshot<T>.withData(ConnectionState.active, data);
          });
        },
        onError: (Object error) {
          setState(() {
            _summary = AsyncSnapshot<T>.withError(
              ConnectionState.active,
              error,
            );
          });
        },
        onDone: () {
          setState(() {
            _summary = _summary.inState(ConnectionState.done);
          });
        },
      );
      _summary = _summary.inState(ConnectionState.waiting);
    }
  }

  void _unsubscribe() {
    if (_subscription != null) {
      _subscription!.cancel();
      _subscription = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _summary);
  }
}
