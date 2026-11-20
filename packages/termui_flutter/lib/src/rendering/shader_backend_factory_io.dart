import 'shader_backend.dart';
import 'shader_backend_disabled.dart';
import 'shader_backend_gpu.dart';
import 'shader_spec.dart';

/// Creates the native/VM [TerminalShaderBackend], falling back cleanly to
/// [DisabledShaderBackend] when `flutter_gpu` is unavailable, disabled, or
/// throws during initialization.
TerminalShaderBackend createPlatformShaderBackend({
  ShaderBackendKind? override,
  TerminalShaderBackend? Function()? desktopGpuFactory,
  TerminalShaderBackend? Function()? webGl2Factory,
}) {
  if (override == ShaderBackendKind.disabled ||
      override == ShaderBackendKind.webGl2) {
    return const DisabledShaderBackend();
  }
  final factory = desktopGpuFactory ?? FlutterGpuShaderBackend.tryCreate;
  try {
    return factory() ?? const DisabledShaderBackend();
  } on Object {
    return const DisabledShaderBackend();
  }
}
