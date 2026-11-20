import 'shader_backend.dart';
import 'shader_backend_factory_io.dart'
    if (dart.library.js_interop) 'shader_backend_factory_web.dart'
    as impl;
import 'shader_spec.dart';

/// Creates the platform-appropriate [TerminalShaderBackend], falling back
/// cleanly to `DisabledShaderBackend` when custom GPU shader execution is
/// unavailable or explicitly disabled.
///
/// Pass [override] to force a specific [ShaderBackendKind] (for example,
/// [ShaderBackendKind.disabled] as a runtime rollback switch). Optional
/// [desktopGpuFactory] and [webGl2Factory] hooks allow tests and platform
/// integrations to inject custom backend constructors.
TerminalShaderBackend createTerminalShaderBackend({
  ShaderBackendKind? override,
  TerminalShaderBackend? Function()? desktopGpuFactory,
  TerminalShaderBackend? Function()? webGl2Factory,
}) => impl.createPlatformShaderBackend(
  override: override,
  desktopGpuFactory: desktopGpuFactory,
  webGl2Factory: webGl2Factory,
);
