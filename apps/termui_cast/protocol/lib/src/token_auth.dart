import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// Async provider returning a bearer JWT for Cloud Run IAP WebSocket upgrades.
typedef IapTokenProvider = Future<String> Function();

/// Constant-time SHA-256 bearer-token verifier for caster and client peers.
final class TokenAuthenticator {
  // Matches a service account email such as `<name>@<project>.iam.gserviceaccount.com`.
  static final RegExp _serviceAccountPattern = RegExp(
    r'^[A-Za-z0-9._+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$',
  );

  final Uint8List? _casterDigest;
  final Uint8List? _clientDigest;

  /// Creates a token verifier with optional expected secrets per role.
  TokenAuthenticator({String? casterToken, String? clientToken})
    : _casterDigest = _digestOrNull(casterToken),
      _clientDigest = _digestOrNull(clientToken);

  /// Whether authentication requires a non-empty token for [role].
  bool requiresToken(CastRole role) => _expectedDigest(role) != null;

  /// Verifies [candidate] against the configured secret for [role] in constant time.
  bool verify(CastRole role, String candidate) {
    final expected = _expectedDigest(role);
    if (expected == null) return true;
    final actual = sha256.convert(utf8.encode(candidate)).bytes;
    return constantTimeEquals32(expected, actual);
  }

  /// Compares two 32-byte SHA-256 digests without data-dependent branches.
  static bool constantTimeEquals32(List<int> expected, List<int> actual) {
    if (expected.length != 32 || actual.length != 32) return false;
    var diff = 0;
    for (var i = 0; i < 32; i++) {
      diff |= expected[i] ^ actual[i];
    }
    return diff == 0;
  }

  /// Whether [email] has valid service-account email syntax.
  static bool isValidServiceAccountEmail(String email) =>
      _serviceAccountPattern.hasMatch(email);

  /// Derives the canonical `https://` IAP JWT audience URL from a `wss://` [wsUri].
  static String iapAudienceForWebSocketUri(Uri wsUri) {
    if (wsUri.scheme != 'wss' || wsUri.host.isEmpty) {
      throw FormatException(
        'IAP JWT audience requires a wss:// URI with a non-empty host, got "$wsUri".',
      );
    }
    final audienceUri = Uri(
      scheme: 'https',
      host: wsUri.host,
      port: wsUri.hasPort ? wsUri.port : null,
      path: wsUri.path.isEmpty ? '/' : wsUri.path,
    );
    return '$audienceUri';
  }

  Uint8List? _expectedDigest(CastRole role) => switch (role) {
    .caster => _casterDigest,
    .client => _clientDigest,
  };

  static Uint8List? _digestOrNull(String? token) {
    if (token == null || token.isEmpty) return null;
    return Uint8List.fromList(sha256.convert(utf8.encode(token)).bytes);
  }
}
