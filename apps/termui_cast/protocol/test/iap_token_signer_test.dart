@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:termui_cast_protocol/termui_cast_protocol_io.dart';
import 'package:test/test.dart';

const String _ecKeyPem = '''
-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgcnEPuDznhktG/80D
VI1RW5oy4n+z93IGlv9cLtYJuBOhRANCAAT6yG8zLGFj+MjDuYRd1ADtqLt5rTI8
w4exRE3P94LpwktT6JM3sijtRxSUJM5sfrP/nuLlt0ybG+f2ZAfvG8sO
-----END PRIVATE KEY-----
''';

const String _rsaPkcs8KeyPem = '''
-----BEGIN PRIVATE KEY-----
MIICdQIBADANBgkqhkiG9w0BAQEFAASCAl8wggJbAgEAAoGBAKEbjO9lhv9IyH7m
FdUnxE9DeZhlOpUv6m24yYDzGKODSXUKkP5j3ulvCjIlFkRZNtC/zxCEdCFzIy60
jCgWOzgNSi50xrprE4vbPssG5G7Nssv6UX+rY5p2DEmS+Ivy+Szn4xb4KkYlncgm
fXAsTV71MAHHcmh9OXs9T0Hsf4KzAgMBAAECgYAuUtmnTC4Q4UClHEtSyuhrUh94
bkL1+p0Rh3yJE10WRv2sJamjO9wwirkHyhoo9O4J/9zuBufNZmnLWCaksB++fWnH
AuuA9xf7TC/TMUxETYCGrFBAWB2VM+tJn2/7OSdYzLByUZPY4DW3t/74c4TaLk/H
J/tRc3cINOfmwCUgAQJBAMt3XQgEm8QmGnoC1UtUr2iVS8/NIKgF0j1ERPPHLN2E
7rUjHQC3J78CSetCFQzm1NBEELJwI7WqSbEym+raTrMCQQDKtGGi2P+yYW2gxUms
kh3sk2sEHNfA74Gquj+1LduCUX4aR5IKDycKTSJtInY0d5RfJgMgYwfFbvlOKWxZ
n/wBAkAX0lTREIEQOQnWiShh1ntm+jvTC4gsQ+o2hByykfo9wUeVa5QEtmzv3xu6
cJU4WnpGHAH8ckasCVDxbyR0HbUjAkAdGt1SBppgQID/LpSvhKNrTpd1Fbcc6sbR
fsCbASSdh5n1qAUeEKLoZb7lsKcMTYcuSkT0p4N8I70ELgpyq/gBAkB0cyb73k5w
AcUmR6oniiNfTkhtwRerwKrdqSbSjEbxlevwqqQnM1+Kl1vKC0Tyy8WM5yVuQkAJ
EwFSx/7Q3CSd
-----END PRIVATE KEY-----
''';

void main() {
  group('TokenAuthenticator IAP helpers', () {
    test('validates service account email syntax', () {
      check(
        TokenAuthenticator.isValidServiceAccountEmail(
          'caster-mac@proj-123.iam.gserviceaccount.com',
        ),
      ).isTrue();
      check(
        TokenAuthenticator.isValidServiceAccountEmail('dev+iap@example.co'),
      ).isTrue();
      check(TokenAuthenticator.isValidServiceAccountEmail('')).isFalse();
      check(
        TokenAuthenticator.isValidServiceAccountEmail('not-an-email'),
      ).isFalse();
      check(
        TokenAuthenticator.isValidServiceAccountEmail('missing-tld@localhost'),
      ).isFalse();
    });

    test('canonicalizes wss:// URIs to https:// IAP audience URLs', () {
      final omittedPort = TokenAuthenticator.iapAudienceForWebSocketUri(
        Uri.parse('wss://relay.run.app/v1/client'),
      );
      final explicit443 = TokenAuthenticator.iapAudienceForWebSocketUri(
        Uri.parse('wss://Relay.Run.App:443/v1/client'),
      );
      final customPort = TokenAuthenticator.iapAudienceForWebSocketUri(
        Uri.parse('wss://relay.run.app:8443'),
      );

      check(omittedPort).equals('https://relay.run.app/v1/client');
      check(explicit443).equals(omittedPort);
      check(
        TokenAuthenticator.iapAudienceForWebSocketUri(
          Uri.parse('wss://relay.run.app:443/v1/client'),
        ),
      ).equals(omittedPort);
      check(customPort).equals('https://relay.run.app:8443/');

      check(
        () => TokenAuthenticator.iapAudienceForWebSocketUri(
          Uri.parse('ws://127.0.0.1:8420/v1/client'),
        ),
      ).throws<FormatException>();
    });
  });

  group('IapServiceAccountKey and RsaPrivateKey', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('iap_key_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test('parses JSON key file and signs verifiable RS256 JWTs', () async {
      final keyFile = File.fromUri(tempDir.uri.resolve('sa.json'));
      await keyFile.writeAsString(
        jsonEncode(<String, Object>{
          'client_email': 'viewer@proj.iam.gserviceaccount.com',
          'private_key_id': 'kid-abc',
          'private_key': _rsaPkcs8KeyPem,
        }),
      );

      final parsedKey = IapServiceAccountKey.fromFileSync(keyFile.path);
      final signer = IapJwtSigner(
        serviceAccountKey: parsedKey,
        targetAudienceUrl: 'https://relay.run.app/v1/client',
        clock: Clock.fixed(
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000),
        ),
      );
      final IapTokenProvider provider = signer.getBearerToken;
      final jwt = await provider();
      final parts = jwt.split('.');
      check(parts.length).equals(3);

      final header =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))),
              )
              as Map<String, Object?>;
      final claims =
          jsonDecode(
                utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))),
              )
              as Map<String, Object?>;
      check(header['alg']).equals('RS256');
      check(header['kid']).equals('kid-abc');
      check(claims['iss']).equals('viewer@proj.iam.gserviceaccount.com');
      check(claims['sub']).equals('viewer@proj.iam.gserviceaccount.com');
      check(claims['aud']).equals('https://relay.run.app/v1/client');
      check(claims['iat']).equals(1700000000);
      check(claims['exp']).equals(1700000000 + 55 * 60);

      _verifyRs256Signature(parts, RsaPrivateKey.fromPem(_rsaPkcs8KeyPem));
    });

    test('rejects missing files, malformed JSON, and non-RSA keys', () {
      check(
        () => IapServiceAccountKey.fromFileSync(
          File.fromUri(tempDir.uri.resolve('missing.json')).path,
        ),
      ).throws<FormatException>();
      check(
        () => IapServiceAccountKey.fromJsonString('{not-json'),
      ).throws<FormatException>();
      check(
        () => IapServiceAccountKey.fromJsonString('[]'),
      ).throws<FormatException>();
      check(
        () => IapServiceAccountKey.fromJsonString('{"client_email": "a@b.co"}'),
      ).throws<FormatException>();
      check(() => RsaPrivateKey.fromPem(_ecKeyPem)).throws<FormatException>();
    });
  });

  group('IapJwtSigner caching, deduplication, and gcloud runner', () {
    test(
      'caches valid JWTs, deduplicates in-flight calls, and refreshes near expiry',
      () async {
        var nowEpochSec = 1700000000;
        var invocations = 0;
        final gate = Completer<void>();

        final signer = IapJwtSigner(
          serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
          clock: Clock(
            () => DateTime.fromMillisecondsSinceEpoch(nowEpochSec * 1000),
          ),
          processRunner: (executable, arguments) async {
            invocations++;
            await gate.future;
            final jwtPath = arguments.last;
            await File(jwtPath).writeAsString('signed-jwt-$invocations\n');
            return ProcessResult(1, 0, '', '');
          },
        );

        final first = signer.getBearerToken();
        final concurrent = signer.getBearerToken();
        gate.complete();

        final results = await [first, concurrent].wait;
        check(results).deepEquals(['signed-jwt-1', 'signed-jwt-1']);
        check(invocations).equals(1);

        // Still outside 5-minute refreshMargin (49 minutes elapsed of 55m TTL).
        nowEpochSec += 49 * 60;
        check(await signer.getBearerToken()).equals('signed-jwt-1');
        check(invocations).equals(1);

        // Inside 5-minute refreshMargin (51 minutes elapsed of 55m TTL) -> mints fresh token.
        nowEpochSec += 2 * 60;
        check(await signer.getBearerToken()).equals('signed-jwt-2');
        check(invocations).equals(2);
      },
    );

    test('surfaces gcloud non-zero exit codes and timeouts cleanly', () async {
      final failingSigner = IapJwtSigner(
        serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
        targetAudienceUrl: 'https://relay.run.app/v1/client',
        processRunner: (_, _) async =>
            ProcessResult(1, 1, '', 'permission denied'),
      );
      await check(failingSigner.getBearerToken()).throws<ProcessException>();

      final hangingSigner = IapJwtSigner(
        serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
        targetAudienceUrl: 'https://relay.run.app/v1/client',
        signTimeout: const Duration(milliseconds: 20),
        processRunner: (_, _) => Completer<ProcessResult>().future,
      );
      await check(hangingSigner.getBearerToken()).throws<TimeoutException>();
    });

    test(
      'D-06: default subprocess runner kills timed-out tree holding tempDir file and cleans tempDir',
      () async {
        final sandbox = Directory.systemTemp.createTempSync('iap_d06_timeout_');
        addTearDown(() async {
          if (sandbox.existsSync()) {
            await sandbox.delete(recursive: true);
          }
        });

        final sleeperDart = File('${sandbox.path}/sleeper.dart')
          ..writeAsStringSync(
            'import "dart:async";\n'
            'import "dart:io";\n'
            'Future<void> main(List<String> args) async {\n'
            '  final lockHandle = File(args.last).openSync(mode: FileMode.write);\n'
            '  lockHandle.writeStringSync("locked");\n'
            '  await Future<void>.delayed(const Duration(seconds: 30));\n'
            '  lockHandle.closeSync();\n'
            '}\n',
          );

        final String wrapperPath;
        if (Platform.isWindows) {
          wrapperPath = '${sandbox.path}\\fake_gcloud.cmd';
          File(wrapperPath).writeAsStringSync(
            '@echo off\r\n"${Platform.resolvedExecutable}" "${sleeperDart.path}" %*\r\n',
          );
        } else {
          wrapperPath = '${sandbox.path}/fake_gcloud.sh';
          File(wrapperPath).writeAsStringSync(
            '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "${sleeperDart.path}" "\$@"\n',
          );
          Process.runSync('chmod', ['+x', wrapperPath]);
        }

        final existingTempDirs = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where((d) => d.path.contains('termui_cast_iap_'))
            .map((d) => d.path)
            .toSet();

        final signer = IapJwtSigner(
          serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
          gcloudExecutable: wrapperPath,
          signTimeout: const Duration(milliseconds: 900),
        );

        await check(signer.getBearerToken()).throws<TimeoutException>();

        final remainingNewTempDirs = Directory.systemTemp
            .listSync()
            .whereType<Directory>()
            .where(
              (d) =>
                  d.path.contains('termui_cast_iap_') &&
                  !existingTempDirs.contains(d.path),
            )
            .toList();
        check(remainingNewTempDirs).isEmpty();
      },
    );

    test('rejects invalid serviceAccount in IapJwtSigner constructor', () {
      check(
        () => IapJwtSigner(
          serviceAccount: 'not-an-email',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
        ),
      ).throws<ArgumentError>();
      check(
        () => IapJwtSigner(
          serviceAccount: '',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
        ),
      ).throws<ArgumentError>();
    });

    test(
      'preserves default and custom gcloudExecutable with injected processRunner and executes custom script directly',
      () async {
        final seenExecutables = <String>[];
        final defaultRunnerSigner = IapJwtSigner(
          serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
          processRunner: (executable, arguments) async {
            seenExecutables.add(executable);
            await File(arguments.last).writeAsString('jwt-default\n');
            return ProcessResult(1, 0, '', '');
          },
        );
        check(await defaultRunnerSigner.getBearerToken()).equals('jwt-default');
        check(seenExecutables).deepEquals(['gcloud']);

        seenExecutables.clear();
        const customPath =
            '/Users/codefu/dvelopment/google-cloud-sdk/bin/gcloud';
        final customRunnerSigner = IapJwtSigner(
          serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
          gcloudExecutable: customPath,
          processRunner: (executable, arguments) async {
            seenExecutables.add(executable);
            await File(arguments.last).writeAsString('jwt-custom\n');
            return ProcessResult(1, 0, '', '');
          },
        );
        check(await customRunnerSigner.getBearerToken()).equals('jwt-custom');
        check(seenExecutables).deepEquals([customPath]);

        // Real subprocess run with an explicit fake gcloud wrapper.
        final sandbox = Directory.systemTemp.createTempSync('iap_gcloud_ok_');
        addTearDown(() async {
          if (sandbox.existsSync()) {
            await sandbox.delete(recursive: true);
          }
        });
        final writerDart = File('${sandbox.path}/writer.dart')
          ..writeAsStringSync(
            'import "dart:io";\n'
            'void main(List<String> args) {\n'
            '  File(args.last).writeAsStringSync("real-subproc-jwt\\n");\n'
            '}\n',
          );
        final String wrapperPath;
        if (Platform.isWindows) {
          wrapperPath = '${sandbox.path}\\custom_gcloud.cmd';
          File(wrapperPath).writeAsStringSync(
            '@echo off\r\n"${Platform.resolvedExecutable}" "${writerDart.path}" %*\r\n',
          );
        } else {
          wrapperPath = '${sandbox.path}/custom_gcloud.sh';
          File(wrapperPath).writeAsStringSync(
            '#!/bin/sh\nexec "${Platform.resolvedExecutable}" "${writerDart.path}" "\$@"\n',
          );
          Process.runSync('chmod', ['+x', wrapperPath]);
        }
        final realSigner = IapJwtSigner(
          serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
          gcloudExecutable: wrapperPath,
        );
        check(await realSigner.getBearerToken()).equals('real-subproc-jwt');

        // Missing executable fails with ProcessException mentioning attempted path.
        final missingExec = Platform.isWindows
            ? '${sandbox.path}\\nonexistent_gcloud.cmd'
            : '${sandbox.path}/nonexistent_gcloud';
        final missingSigner = IapJwtSigner(
          serviceAccount: 'viewer@proj.iam.gserviceaccount.com',
          targetAudienceUrl: 'https://relay.run.app/v1/client',
          gcloudExecutable: missingExec,
        );
        await check(missingSigner.getBearerToken()).throws<ProcessException>(
          (e) => e.has((p) => p.executable, 'executable').equals(missingExec),
        );
      },
    );
  });

  group('gcloud executable probing and resolution', () {
    test('expandHomePath expands ~/ and ~\\ using HOME or USERPROFILE', () {
      check(
        expandHomePath(
          '~/dvelopment/google-cloud-sdk/bin/gcloud',
          environment: const {'HOME': '/Users/codefu/'},
          operatingSystem: 'macos',
        ),
      ).equals('/Users/codefu/dvelopment/google-cloud-sdk/bin/gcloud');

      check(
        expandHomePath(
          r'~\google-cloud-sdk\bin\gcloud.cmd',
          environment: const {'USERPROFILE': r'C:\Users\alice\'},
          operatingSystem: 'windows',
        ),
      ).equals(r'C:\Users\alice\google-cloud-sdk\bin\gcloud.cmd');

      check(
        expandHomePath(
          '~/sdk/gcloud',
          environment: const {},
          operatingSystem: 'linux',
        ),
      ).equals('~/sdk/gcloud');

      check(
        expandHomePath(
          '/usr/local/bin/gcloud',
          environment: const {'HOME': '/Users/codefu'},
          operatingSystem: 'macos',
        ),
      ).equals('/usr/local/bin/gcloud');
    });

    test(
      'probeGcloudExecutable checks PATH before standard locations on macOS/Linux and Windows',
      () {
        // 1. macOS/Linux: PATH wins over standard Homebrew fallback.
        final macBoth = <String>{
          '/custom/bin/gcloud',
          '/opt/homebrew/bin/gcloud',
        };
        check(
          probeGcloudExecutable(
            environment: const {
              'PATH': '/empty:/custom/bin/',
              'HOME': '/Users/codefu',
            },
            fileExists: macBoth.contains,
            operatingSystem: 'macos',
          ),
        ).equals('/custom/bin/gcloud');

        // 2. macOS/Linux: falls back to standard install locations when PATH is minimal (e.g. Dock launch).
        final macStandard = <String>{
          '/Users/codefu/google-cloud-sdk/bin/gcloud',
        };
        check(
          probeGcloudExecutable(
            environment: const {
              'PATH': '/usr/bin:/bin',
              'HOME': '/Users/codefu',
            },
            fileExists: macStandard.contains,
            operatingSystem: 'macos',
          ),
        ).equals('/Users/codefu/google-cloud-sdk/bin/gcloud');

        final homebrewOnly = <String>{
          '/opt/homebrew/share/google-cloud-sdk/bin/gcloud',
        };
        check(
          probeGcloudExecutable(
            environment: const {'PATH': '/usr/bin:/bin'},
            fileExists: homebrewOnly.contains,
            operatingSystem: 'macos',
          ),
        ).equals('/opt/homebrew/share/google-cloud-sdk/bin/gcloud');

        // 3. Windows: checks gcloud.cmd > gcloud.exe > gcloud in quoted Path entries.
        final winPathFiles = <String>{
          r'C:\Tools\sdk\bin\gcloud.exe',
          r'C:\Tools\sdk\bin\gcloud.cmd',
        };
        check(
          probeGcloudExecutable(
            environment: const {'Path': r'"C:\Tools\sdk\bin\"'},
            fileExists: winPathFiles.contains,
            operatingSystem: 'windows',
          ),
        ).equals(r'C:\Tools\sdk\bin\gcloud.cmd');

        // 4. Windows: falls back to LOCALAPPDATA / ProgramFiles / USERPROFILE standard locations.
        final winFallback = <String>{
          r'C:\Users\alice\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd',
        };
        check(
          probeGcloudExecutable(
            environment: const {
              'PATH': r'C:\Windows\System32',
              'LOCALAPPDATA': r'C:\Users\alice\AppData\Local',
              'USERPROFILE': r'C:\Users\alice',
            },
            fileExists: winFallback.contains,
            operatingSystem: 'windows',
          ),
        ).equals(
          r'C:\Users\alice\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin\gcloud.cmd',
        );

        // 5. Returns null when nothing matches.
        check(
          probeGcloudExecutable(
            environment: const {'PATH': '/usr/bin', 'HOME': '/Users/codefu'},
            fileExists: (_) => false,
            operatingSystem: 'linux',
          ),
        ).isNull();
      },
    );

    test(
      'resolveGcloudExecutable prioritizes overridePath with ~/ expansion, then probe, then gcloud',
      () {
        check(
          resolveGcloudExecutable(
            overridePath: '  ~/dvelopment/google-cloud-sdk/bin/gcloud  ',
            environment: const {
              'HOME': '/Users/codefu',
              'PATH': '/opt/homebrew/bin',
            },
            fileExists: (p) => p == '/opt/homebrew/bin/gcloud',
            operatingSystem: 'macos',
          ),
        ).equals('/Users/codefu/dvelopment/google-cloud-sdk/bin/gcloud');

        check(
          resolveGcloudExecutable(
            overridePath: '   ',
            environment: const {'PATH': '/usr/bin'},
            fileExists: (p) => p == '/opt/homebrew/bin/gcloud',
            operatingSystem: 'macos',
          ),
        ).equals('/opt/homebrew/bin/gcloud');

        check(
          resolveGcloudExecutable(
            environment: const {'PATH': '/usr/bin'},
            fileExists: (_) => false,
            operatingSystem: 'linux',
          ),
        ).equals('gcloud');
      },
    );
  });
}

void _verifyRs256Signature(List<String> parts, RsaPrivateKey rsaKey) {
  final sigBytes = base64Url.decode(base64Url.normalize(parts[2]));
  check(sigBytes.length).equals(rsaKey.byteLength);
  var sigInt = BigInt.zero;
  for (final b in sigBytes) {
    sigInt = (sigInt << 8) | BigInt.from(b);
  }
  final verifiedEm = sigInt.modPow(rsaKey.publicExponent, rsaKey.modulus);
  final emBytes = Uint8List(rsaKey.byteLength);
  var tmp = verifiedEm;
  for (var i = emBytes.length - 1; i >= 0; i--) {
    emBytes[i] = (tmp & BigInt.from(0xff)).toInt();
    tmp = tmp >> 8;
  }
  final expectedDigest = sha256
      .convert(utf8.encode('${parts[0]}.${parts[1]}'))
      .bytes;
  check(emBytes[0]).equals(0x00);
  check(emBytes[1]).equals(0x01);
  check(
    emBytes.sublist(emBytes.length - expectedDigest.length),
  ).deepEquals(expectedDigest);
}
