import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_channel_adapter.dart';

/// Opens a browser-compatible binary WebSocket channel to [uri].
Future<StreamChannel<Uint8List>> openPlatformClientWebSocket(
  Uri uri, {
  IapTokenProvider? iapTokenProvider,
}) async {
  if (iapTokenProvider != null) {
    throw UnsupportedError(
      'Cloud Run IAP bearer headers are unsupported in Web browsers.',
    );
  }
  final channel = WebSocketChannel.connect(uri);
  await channel.ready;
  return adaptBinaryWebSocketChannel(channel);
}
