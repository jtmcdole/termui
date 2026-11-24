import 'dart:typed_data';

import 'shadertoy_glsl_shim.dart';

/// Result of compiling a Ghostty Shadertoy `.glsl` shader into an Impeller
/// `.shaderbundle` FlatBuffer payload.
final class CompiledShaderBundle {
  /// Compiled `.shaderbundle` FlatBuffer bytes ready for
  /// `gpu.ShaderLibrary.fromBytes`.
  final ByteData bytes;

  /// Static analysis report extracted from the user Shadertoy source.
  final ShadertoyGlslAnalysis analysis;

  /// Lowercase hexadecimal SHA-256 cache key for this compiled bundle.
  final String cacheKey;

  /// Whether [bytes] were served from the on-disk SHA-256 cache without
  /// spawning `impellerc`.
  final bool fromCache;

  /// Creates a compiled shader bundle result.
  const CompiledShaderBundle({
    required this.bytes,
    required this.analysis,
    required this.cacheKey,
    required this.fromCache,
  });
}
