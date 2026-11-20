import 'dart:ui' as ui;

import 'shader_spec.dart';

/// Opaque handle representing a compiled shader pipeline owned by a
/// [TerminalShaderBackend].
abstract interface class CompiledShaderHandle {
  /// Stable pass identifier associated with this compiled shader.
  String get id;

  /// Whether this compiled shader reads `iPrevFrame` and requires ping-pong
  /// frame persistence.
  bool get usesPrevFrame;

  /// Releases native GPU or WebGL resources held by this handle.
  void dispose();
}

/// Single pass execution record combining a compiled shader handle, its
/// per-frame uniforms, and an optional ping-pong buffer key.
typedef ShaderPassInvocation = ({
  CompiledShaderHandle handle,
  TerminalShaderUniforms uniforms,
  String? prevFrameKey,
});

/// Structured error raised when validating, shimming, or compiling a custom
/// terminal fragment shader fails.
final class ShaderCompileException implements Exception {
  /// Identifier or path of the shader that failed compilation.
  final String shaderId;

  /// Human-readable summary of the compilation failure.
  final String message;

  /// Optional 1-based line number reported by the GLSL compiler.
  final int? lineNumber;

  /// Optional raw compiler log (e.g. `impellerc` stderr or `gl.getShaderInfoLog`).
  final String? compilerLog;

  /// Creates a shader compilation exception.
  const ShaderCompileException({
    required this.shaderId,
    required this.message,
    this.lineNumber,
    this.compilerLog,
  });

  @override
  String toString() {
    final location = lineNumber == null ? '' : ' (line $lineNumber)';
    return 'ShaderCompileException[$shaderId$location]: $message';
  }
}

/// Cross-platform contract implemented by Desktop (`flutter_gpu`), Web
/// (`OffscreenCanvas` WebGL2), and `disabled` shader backends.
abstract interface class TerminalShaderBackend {
  /// Identifies the active backend implementation.
  ShaderBackendKind get kind;

  /// Whether this backend can compile and run custom user GLSL shaders.
  bool get supportsCustomGlsl;

  /// Whether background passes without an `inputImage` can render
  /// synchronously during paint.
  bool get supportsSyncBackground;

  /// Compiles [shadertoyGlsl] into a reusable [CompiledShaderHandle].
  ///
  /// Throws [ShaderCompileException] if validation or GPU compilation fails.
  Future<CompiledShaderHandle> compile(
    String id,
    String shadertoyGlsl, {
    bool usesPrevFrame = false,
  });

  /// Recompiles [shadertoyGlsl] and swaps [handle] in place without tearing
  /// down downstream references.
  ///
  /// On compilation failure, implementations must leave the previously active
  /// shader program intact and throw [ShaderCompileException].
  Future<void> reload(CompiledShaderHandle handle, String shadertoyGlsl);

  /// Synchronous render path for background passes that do not sample
  /// `inputImage` (used on Desktop `flutter_gpu`).
  ui.Image? renderBackgroundSync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? wallpaperImage,
  });

  /// Single-flight async render path for `iChannel0` foreground passes and
  /// scoped region passes.
  Future<ui.Image?> renderPassesAsync({
    required List<ShaderPassInvocation> passes,
    required ui.Size physicalSize,
    ui.Image? inputImage,
    ui.Image? wallpaperImage,
  });

  /// Disposes all compiled handles, framebuffers, and GPU contexts owned by
  /// this backend.
  void dispose();
}
