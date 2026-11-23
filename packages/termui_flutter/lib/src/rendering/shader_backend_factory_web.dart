import 'shader_backend.dart';
import 'shader_backend_disabled.dart';
import 'shader_backend_web.dart';
import 'shader_spec.dart';

/// Creates the Flutter Web [TerminalShaderBackend], falling back cleanly to
/// [DisabledShaderBackend] when WebGL2 or `OffscreenCanvas` is unavailable,
/// disabled, or throws during initialization.
TerminalShaderBackend createPlatformShaderBackend({
  ShaderBackendKind? override,
  TerminalShaderBackend? Function()? desktopGpuFactory,
  TerminalShaderBackend? Function()? webGl2Factory,
}) {
  if (override == ShaderBackendKind.disabled ||
      override == ShaderBackendKind.flutterGpu) {
    return const DisabledShaderBackend();
  }
  final factory = webGl2Factory ?? WebGl2ShaderBackend.tryCreate;
  try {
    return factory() ?? const DisabledShaderBackend();
  } on Object {
    return const DisabledShaderBackend();
  }
}
