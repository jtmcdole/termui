import 'dart:async';
import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Adapts a cross-platform [WebSocketChannel] into a binary `StreamChannel<Uint8List>`.
///
/// Binary frames and stream errors are forwarded synchronously without closing
/// the adapted stream on error.
StreamChannel<Uint8List> adaptBinaryWebSocketChannel(WebSocketChannel channel) {
  channel.sink.done.ignore();
  final incoming = _adaptIncomingStream(channel.stream);
  final outgoing = StreamController<Uint8List>(sync: true);
  outgoing.stream.listen(
    (bytes) {
      try {
        channel.sink.add(bytes);
      } on Object {
        // Ignore late writes after the underlying WebSocket sink has closed.
      }
    },
    onError: (Object error, StackTrace stackTrace) {
      try {
        channel.sink.addError(error, stackTrace);
      } on Object {
        // Ignore errors forwarded after the underlying WebSocket sink has closed.
      }
    },
    onDone: () => unawaited(channel.sink.close().catchError((Object _) {})),
  );
  return StreamChannel<Uint8List>(incoming, outgoing.sink);
}

Stream<Uint8List> _adaptIncomingStream(Stream<Object?> source) {
  late final StreamController<Uint8List> controller;
  StreamSubscription<Object?>? subscription;
  controller = StreamController<Uint8List>(
    sync: true,
    onListen: () {
      subscription = source.listen(
        (event) {
          switch (event) {
            case final Uint8List bytes:
              controller.add(bytes);
            case final List<int> bytes:
              controller.add(Uint8List.fromList(bytes));
            default:
              controller.addError(
                const ProtocolFormatException(
                  'Expected binary WebSocket frame.',
                ),
              );
          }
        },
        onError: controller.addError,
        onDone: () => unawaited(controller.close()),
      );
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () => subscription?.cancel(),
  );
  return controller.stream;
}
