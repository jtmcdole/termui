import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';

import 'token_auth.dart';

/// Callback running an external process and returning its [ProcessResult].
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

/// Parsed RSA private key parameters (`n`, `e`, `d`) from a PKCS#8 or PKCS#1 PEM.
final class RsaPrivateKey {
  /// RSA modulus `n`.
  final BigInt modulus;

  /// RSA public exponent `e`.
  final BigInt publicExponent;

  /// RSA private exponent `d`.
  final BigInt privateExponent;

  /// Key length in bytes (`ceil(modulus.bitLength / 8)`).
  final int byteLength;

  /// Creates a validated [RsaPrivateKey].
  RsaPrivateKey({
    required this.modulus,
    required this.publicExponent,
    required this.privateExponent,
  }) : byteLength = (modulus.bitLength + 7) >> 3 {
    if (modulus.bitLength < 1024 ||
        !modulus.isOdd ||
        publicExponent <= BigInt.one ||
        privateExponent <= BigInt.zero) {
      throw const FormatException(
        'RSA private key requires an odd modulus >= 1024 bits and positive exponents.',
      );
    }
  }

  // Strips PKCS#1/PKCS#8 private key headers, footers, and whitespace.
  static final RegExp _pemArmorOrWhitespace = RegExp(
    r'-----(?:BEGIN|END) (?:RSA )?PRIVATE KEY-----|\s+',
  );

  static const List<int> _rsaEncryptionOid = <int>[
    0x2a,
    0x86,
    0x48,
    0x86,
    0xf7,
    0x0d,
    0x01,
    0x01,
    0x01,
  ];

  static const List<int> _sha256DigestInfoPrefix = <int>[
    0x30,
    0x31,
    0x30,
    0x0d,
    0x06,
    0x09,
    0x60,
    0x86,
    0x48,
    0x01,
    0x65,
    0x03,
    0x04,
    0x02,
    0x01,
    0x05,
    0x00,
    0x04,
    0x20,
  ];

  /// Parses a PKCS#8 (`BEGIN PRIVATE KEY`) or PKCS#1 (`BEGIN RSA PRIVATE KEY`) PEM.
  factory RsaPrivateKey.fromPem(String pem) {
    final isPkcs1 = pem.contains('-----BEGIN RSA PRIVATE KEY-----');
    final isPkcs8 = pem.contains('-----BEGIN PRIVATE KEY-----');
    if (!isPkcs1 && !isPkcs8) {
      throw const FormatException(
        'Expected PKCS#8 (BEGIN PRIVATE KEY) or PKCS#1 (BEGIN RSA PRIVATE KEY) PEM.',
      );
    }
    final cleaned = pem.replaceAll(_pemArmorOrWhitespace, '');
    if (cleaned.isEmpty) {
      throw const FormatException('Empty RSA private key PEM.');
    }
    final Uint8List der;
    try {
      der = base64Decode(cleaned);
    } on FormatException catch (e) {
      throw FormatException('Invalid base64 in RSA private key PEM: $e');
    }
    final pkcs1Bytes = isPkcs1 ? der : _extractPkcs1FromPkcs8(der);
    return _parsePkcs1RsaKey(pkcs1Bytes);
  }

  /// Signs [message] using `RSASSA-PKCS1-v1_5` with `SHA-256` (`RS256`).
  Uint8List signRs256(List<int> message) {
    final digest = sha256.convert(message).bytes;
    final tLen = _sha256DigestInfoPrefix.length + digest.length;
    final psLen = byteLength - tLen - 3;
    final em = Uint8List(byteLength);
    em[0] = 0x00;
    em[1] = 0x01;
    em.fillRange(2, 2 + psLen, 0xff);
    em[2 + psLen] = 0x00;
    em.setRange(
      3 + psLen,
      3 + psLen + _sha256DigestInfoPrefix.length,
      _sha256DigestInfoPrefix,
    );
    em.setRange(byteLength - digest.length, byteLength, digest);

    final m = _bytesToBigInt(em);
    final s = m.modPow(privateExponent, modulus);
    return _bigIntToFixedBytes(s, byteLength);
  }

  static Uint8List _extractPkcs1FromPkcs8(Uint8List der) {
    final seq = _readAsn1Element(der, 0, expectedTag: 0x30);
    final body = seq.content;
    final v = _readAsn1Element(body, 0, expectedTag: 0x02);
    final alg = _readAsn1Element(body, v.nextOffset, expectedTag: 0x30);
    final oid = _readAsn1Element(alg.content, 0, expectedTag: 0x06);
    if (!_bytesEqual(oid.content, _rsaEncryptionOid)) {
      throw const FormatException('PKCS#8 private key is not an RSA key.');
    }
    final octets = _readAsn1Element(body, alg.nextOffset, expectedTag: 0x04);
    return octets.content;
  }

  static bool _bytesEqual(Uint8List a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static RsaPrivateKey _parsePkcs1RsaKey(Uint8List pkcs1Der) {
    final seq = _readAsn1Element(pkcs1Der, 0, expectedTag: 0x30);
    final body = seq.content;
    final v = _readAsn1Element(body, 0, expectedTag: 0x02);
    final n = _readAsn1Element(body, v.nextOffset, expectedTag: 0x02);
    final e = _readAsn1Element(body, n.nextOffset, expectedTag: 0x02);
    final d = _readAsn1Element(body, e.nextOffset, expectedTag: 0x02);
    return RsaPrivateKey(
      modulus: _bytesToBigInt(n.content),
      publicExponent: _bytesToBigInt(e.content),
      privateExponent: _bytesToBigInt(d.content),
    );
  }

  static ({Uint8List content, int nextOffset}) _readAsn1Element(
    Uint8List bytes,
    int offset, {
    required int expectedTag,
  }) {
    if (offset >= bytes.length || bytes[offset] != expectedTag) {
      throw FormatException(
        'Expected ASN.1 tag 0x${expectedTag.toRadixString(16)} at offset $offset.',
      );
    }
    final lenInfo = _readAsn1Length(bytes, offset + 1);
    final end = lenInfo.contentOffset + lenInfo.length;
    if (end > bytes.length) {
      throw const FormatException('ASN.1 element exceeds buffer bounds.');
    }
    return (
      content: Uint8List.sublistView(bytes, lenInfo.contentOffset, end),
      nextOffset: end,
    );
  }

  static ({int length, int contentOffset}) _readAsn1Length(
    Uint8List bytes,
    int offset,
  ) {
    if (offset >= bytes.length) {
      throw const FormatException('Truncated ASN.1 length.');
    }
    final first = bytes[offset];
    if ((first & 0x80) == 0) {
      return (length: first, contentOffset: offset + 1);
    }
    final numBytes = first & 0x7f;
    if (numBytes == 0 || numBytes > 4 || offset + 1 + numBytes > bytes.length) {
      throw const FormatException('Invalid ASN.1 multi-byte length.');
    }
    var len = 0;
    for (var i = 0; i < numBytes; i++) {
      len = (len << 8) | bytes[offset + 1 + i];
    }
    return (length: len, contentOffset: offset + 1 + numBytes);
  }

  static BigInt _bytesToBigInt(Uint8List bytes) {
    var result = BigInt.zero;
    for (var i = 0; i < bytes.length; i++) {
      result = (result << 8) | BigInt.from(bytes[i]);
    }
    return result;
  }

  static Uint8List _bigIntToFixedBytes(BigInt value, int length) {
    final out = Uint8List(length);
    var temp = value;
    final mask = BigInt.from(0xff);
    for (var i = length - 1; i >= 0; i--) {
      out[i] = (temp & mask).toInt();
      temp = temp >> 8;
    }
    return out;
  }
}

/// Validated Google Cloud Service Account JSON key material for `RS256` JWT signing.
final class IapServiceAccountKey {
  /// Service account `client_email` (`iss` and `sub` claim).
  final String clientEmail;

  /// Optional key identifier (`kid` header claim).
  final String? privateKeyId;

  /// Parsed RSA private key.
  final RsaPrivateKey privateKey;

  /// Creates a validated [IapServiceAccountKey].
  IapServiceAccountKey({
    required this.clientEmail,
    this.privateKeyId,
    required this.privateKey,
  });

  /// Parses a Google Cloud Service Account JSON key string.
  factory IapServiceAccountKey.fromJsonString(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw FormatException('Invalid JSON in service account key file: $e');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException(
        'Service account key file must be a JSON object.',
      );
    }
    final clientEmail = '${decoded['client_email'] ?? ''}'.trim();
    final privateKeyPem = '${decoded['private_key'] ?? ''}'.trim();
    final privateKeyId = '${decoded['private_key_id'] ?? ''}'.trim();
    if (clientEmail.isEmpty || privateKeyPem.isEmpty) {
      throw const FormatException(
        'Service account key JSON is missing client_email or private_key.',
      );
    }
    return IapServiceAccountKey(
      clientEmail: clientEmail,
      privateKeyId: privateKeyId.isEmpty ? null : privateKeyId,
      privateKey: RsaPrivateKey.fromPem(privateKeyPem),
    );
  }

  /// Reads and parses a Google Cloud Service Account JSON key file from [path].
  factory IapServiceAccountKey.fromFileSync(String path) {
    final String raw;
    try {
      raw = File(path).readAsStringSync();
    } on FileSystemException catch (e) {
      throw FormatException(
        'Failed to read --iap-key-file "$path": ${e.message}',
      );
    }
    return IapServiceAccountKey.fromJsonString(raw);
  }
}

/// Mints and caches short-lived Google Cloud IAP service account JWTs either
/// locally in pure Dart from an [IapServiceAccountKey] (`--iap-key-file`)
/// or via `gcloud iam service-accounts sign-jwt` (`--iap-service-account`).
final class IapJwtSigner {
  /// Target service account email (`<name>@<project>.iam.gserviceaccount.com`) for `gcloud`.
  final String? serviceAccount;

  /// Pre-parsed service account RSA key for local `RS256` signing without `gcloud`.
  final IapServiceAccountKey? serviceAccountKey;

  /// Exact `https://` audience URL for the IAP-protected endpoint.
  final String targetAudienceUrl;

  /// Lifetime of each signed JWT (`<= 1 hour` per IAP specification).
  final Duration ttl;

  /// Minimum remaining lifetime before minting a fresh JWT on reconnect.
  final Duration refreshMargin;

  /// Maximum duration allowed for an external `gcloud` signing invocation.
  final Duration signTimeout;

  /// Executable invoked for `gcloud` signing when no custom [ProcessRunner] is provided.
  final String gcloudExecutable;

  final Clock _clock;
  final ProcessRunner? _customProcessRunner;

  String? _cachedJwt;
  int? _cachedExpEpochSeconds;
  Future<String>? _inFlightJwt;

  /// Creates an IAP JWT signer for either [serviceAccount] or [serviceAccountKey].
  IapJwtSigner({
    String? serviceAccount,
    this.serviceAccountKey,
    required this.targetAudienceUrl,
    this.ttl = const Duration(minutes: 55),
    this.refreshMargin = const Duration(minutes: 5),
    this.signTimeout = const Duration(seconds: 10),
    this.gcloudExecutable = 'gcloud',
    Clock clock = const Clock(),
    ProcessRunner? processRunner,
  }) : serviceAccount = _normalizeOptional(serviceAccount),
       _clock = clock,
       _customProcessRunner = processRunner {
    if ((this.serviceAccount == null) == (serviceAccountKey == null)) {
      throw ArgumentError(
        'Exactly one of serviceAccount or serviceAccountKey must be provided.',
      );
    }
    if (this.serviceAccount != null &&
        !TokenAuthenticator.isValidServiceAccountEmail(this.serviceAccount!)) {
      throw ArgumentError.value(
        this.serviceAccount,
        'serviceAccount',
        'Invalid GCP service account email.',
      );
    }
    if (ttl <= Duration.zero ||
        ttl > const Duration(hours: 1) ||
        refreshMargin < Duration.zero ||
        refreshMargin >= ttl) {
      throw ArgumentError(
        'Expected 0 <= refreshMargin < ttl <= 1 hour, got ttl=$ttl, refreshMargin=$refreshMargin.',
      );
    }
    if (signTimeout <= Duration.zero) {
      throw ArgumentError.value(
        signTimeout,
        'signTimeout',
        'Must be positive.',
      );
    }
  }

  static Future<ProcessResult> _runProcessWithTimeout(
    String executable,
    List<String> arguments,
    Duration timeout,
  ) async {
    final process = await Process.start(
      executable,
      arguments,
      runInShell: Platform.isWindows,
    );
    final stdoutFuture = process.stdout
        .transform(systemEncoding.decoder)
        .join()
        .catchError((Object _) => '');
    final stderrFuture = process.stderr
        .transform(systemEncoding.decoder)
        .join()
        .catchError((Object _) => '');
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(
        process.pid,
        exitCode,
        await stdoutFuture,
        await stderrFuture,
      );
    } on TimeoutException {
      if (Platform.isWindows) {
        try {
          await Process.run('taskkill', [
            '/T',
            '/F',
            '/PID',
            '${process.pid}',
          ]).timeout(const Duration(seconds: 5));
        } on Object catch (_) {}
      } else {
        process.kill();
      }
      try {
        await process.exitCode.timeout(const Duration(seconds: 2));
      } on Object catch (_) {}
      rethrow;
    }
  }

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim();
    return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
  }

  /// Returns a valid cached JWT or mints a fresh one when missing or near expiry.
  Future<String> getBearerToken() {
    final nowSec = _clock.now().millisecondsSinceEpoch ~/ 1000;
    final cached = _cachedJwt;
    final expSec = _cachedExpEpochSeconds;
    if (cached != null &&
        expSec != null &&
        nowSec + refreshMargin.inSeconds < expSec) {
      return Future<String>.value(cached);
    }
    final inFlight = _inFlightJwt;
    if (inFlight != null) return inFlight;

    final future = _mintAndCacheJwt(nowSec);
    _inFlightJwt = future;
    return future.whenComplete(() {
      if (identical(_inFlightJwt, future)) {
        _inFlightJwt = null;
      }
    });
  }

  Future<String> _mintAndCacheJwt(int nowSec) async {
    final nextExpSec = nowSec + ttl.inSeconds;
    final key = serviceAccountKey;
    final signedJwt = key != null
        ? _signWithKey(key, nowSec, nextExpSec)
        : await _signWithGcloud(serviceAccount!, nowSec, nextExpSec);

    _cachedJwt = signedJwt;
    _cachedExpEpochSeconds = nextExpSec;
    return signedJwt;
  }

  String _signWithKey(IapServiceAccountKey key, int nowSec, int nextExpSec) {
    final headerMap = <String, Object>{
      'alg': 'RS256',
      'typ': 'JWT',
      'kid': ?key.privateKeyId,
    };
    final claimMap = _buildClaimMap(key.clientEmail, nowSec, nextExpSec);
    final headerB64 = _base64UrlNoPad(utf8.encode(jsonEncode(headerMap)));
    final claimB64 = _base64UrlNoPad(utf8.encode(jsonEncode(claimMap)));
    final signingInput = '$headerB64.$claimB64';
    final signature = key.privateKey.signRs256(utf8.encode(signingInput));
    return '$signingInput.${_base64UrlNoPad(signature)}';
  }

  Future<String> _signWithGcloud(
    String accountEmail,
    int nowSec,
    int nextExpSec,
  ) async {
    final claimJson = jsonEncode(
      _buildClaimMap(accountEmail, nowSec, nextExpSec),
    );
    final tempDir = await Directory.systemTemp.createTemp('termui_cast_iap_');
    try {
      final claimFile = File.fromUri(tempDir.uri.resolve('claim.json'));
      final jwtFile = File.fromUri(tempDir.uri.resolve('output.jwt'));
      final claimPath = claimFile.path;
      final jwtPath = jwtFile.path;
      await claimFile.writeAsString(claimJson, flush: true);

      final args = <String>[
        'iam',
        'service-accounts',
        'sign-jwt',
        '--iam-account=$accountEmail',
        '--quiet',
        claimPath,
        jwtPath,
      ];
      final runner = _customProcessRunner;
      final result = runner != null
          ? await runner(gcloudExecutable, args).timeout(signTimeout)
          : await _runProcessWithTimeout(gcloudExecutable, args, signTimeout);
      if (result.exitCode != 0) {
        final stderrText = '${result.stderr}'.trim();
        throw ProcessException(
          'gcloud',
          <String>['iam', 'service-accounts', 'sign-jwt'],
          stderrText.isEmpty
              ? 'exit code ${result.exitCode}'
              : 'exit code ${result.exitCode}: $stderrText',
          result.exitCode,
        );
      }

      if (!await jwtFile.exists()) {
        throw const FileSystemException(
          'gcloud sign-jwt did not write output.jwt',
        );
      }
      final signedJwt = (await jwtFile.readAsString()).trim();
      if (signedJwt.isEmpty) {
        throw const FormatException('gcloud sign-jwt produced an empty JWT.');
      }
      return signedJwt;
    } finally {
      for (var attempt = 0; attempt < 4; attempt++) {
        try {
          await tempDir.delete(recursive: true);
          break;
        } on FileSystemException catch (_) {
          if (attempt == 3) break;
          await Future<void>.delayed(
            Duration(milliseconds: 25 * (1 << attempt)),
          );
        } on Object catch (_) {
          break;
        }
      }
    }
  }

  Map<String, Object> _buildClaimMap(
    String accountEmail,
    int nowSec,
    int nextExpSec,
  ) => <String, Object>{
    'iss': accountEmail,
    'sub': accountEmail,
    'aud': targetAudienceUrl,
    'iat': nowSec,
    'exp': nextExpSec,
  };

  static String _base64UrlNoPad(List<int> bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}
