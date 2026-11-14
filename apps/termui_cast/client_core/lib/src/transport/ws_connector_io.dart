import 'dart:typed_data';

import 'package:stream_channel/stream_channel.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';

/// Opens a `dart:io` binary WebSocket channel to [uri] with optional Cloud Run
/// IAP bearer token headers.
Future<StreamChannel<Uint8List>> openPlatformClientWebSocket(
  Uri uri, {
  IapTokenProvider? iapTokenProvider,
}) async {
  Map<String, Object>? headers;
  if (iapTokenProvider != null) {
    final bearer = (await iapTokenProvider().timeout(
      const Duration(seconds: 10),
    )).trim();
    if (bearer.isEmpty) {
      throw StateError('IAP token provider returned an empty bearer token.');
    }
    headers = <String, Object>{'Authorization': 'Bearer $bearer'};
  }
  return connectCastWebSocket(uri, headers: headers);
}
