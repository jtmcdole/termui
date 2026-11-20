import 'dart:ui' as ui;

import 'shader_backend.dart';
import 'shader_spec.dart';

/// No-op [TerminalShaderBackend] used when custom GPU shaders are disabled or
/// unavailable (for example, under Skia Desktop, `flutter test` software
/// rendering, unsupported WebGL2 environments, or an explicit runtime
/// override).
///
/// Never invokes Impeller-only `ui.ImageFilter.shader` or native GPU APIs.
final class DisabledShaderBackend implements TerminalShaderBackend {
  /// Creates a no-op disabled shader backend.
  const DisabledShaderBackend();

  @override
  ShaderBackendKind get kind => ShaderBackendKind.disabled;

  @override
  bool get supportsCustomGlsl => false;

  @override
  bool get supportsSyncBackground => false;

  @override
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  }) => Future<CompiledShaderHandle>.value(
    _DisabledShaderHandle(id: id, usesPrevFrame: usesPrevFrame),
  );

  @override
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl) =>
      Future<void>.value();

  @override
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
  }) => null;

  @override
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
  }) => Future<ui.Image?>.value();

  @override
  void dispose() {}
}

final class _DisabledShaderHandle implements CompiledShaderHandle {
  @override
  final String id;

  @override
  final bool usesPrevFrame;

  _DisabledShaderHandle({required this.id, required this.usesPrevFrame});

  @override
  void dispose() {}
}
