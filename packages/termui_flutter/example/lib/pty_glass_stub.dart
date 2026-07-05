import 'package:termui/termui.dart';

Future<void> runPtyGlassDemo(
  dynamic terminal, {
  void Function(Buffer)? onFrameRedrawn,
}) async {
  // No-op for web since pty2 requires dart:ffi
}
