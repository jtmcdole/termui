import 'package:flutter/services.dart'
    show MethodChannel, MissingPluginException, PlatformException;

import 'automation_models.dart';

/// Native `fterm/window` [MethodChannel] bridge implementing
/// [AutomationWindowBridge].
///
/// Only outbound [MethodChannel.invokeMapMethod] calls are issued on the shared
/// `fterm/window` channel; incoming platform callbacks (such as
/// `windowSizeMoveChanged`) remain exclusively owned by `FtermShellScaffold`.
final class MethodChannelWindowBridge implements AutomationWindowBridge {
  /// Default native window method channel shared with desktop runners.
  static const MethodChannel defaultChannel = MethodChannel('fterm/window');

  /// Underlying [MethodChannel] used for outbound `getBounds`/`setBounds` calls.
  final MethodChannel channel;

  /// Creates a [MethodChannelWindowBridge] backed by [channel].
  const MethodChannelWindowBridge({this.channel = defaultChannel});

  @override
  Future<WindowBoundsSnapshot> getBounds() => _invokeSnapshot('getBounds');

  @override
  Future<WindowBoundsSnapshot> setBounds(WindowBoundsRequest request) =>
      _invokeSnapshot('setBounds', request.toJson());

  Future<WindowBoundsSnapshot> _invokeSnapshot(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      final response = await channel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
      return WindowBoundsSnapshot.fromChannelMap(response);
    } on MissingPluginException {
      return WindowBoundsSnapshot.unsupported;
    } on PlatformException {
      return WindowBoundsSnapshot.unsupported;
    }
  }
}
