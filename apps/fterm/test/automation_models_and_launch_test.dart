@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io' show ProcessStartMode;
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/desktop_launch_env.dart';
import 'package:fterm/src/desktop_launch_env_io.dart';
import 'package:fterm/src/launch_config.dart';
import 'package:fterm/src/settings_storage.dart';

void main() {
  group('WindowBounds models', () {
    test('WindowBoundsUnits parses wire names strictly', () {
      expect(
        WindowBoundsUnits.tryFromWireName('physical'),
        equals(WindowBoundsUnits.physical),
      );
      expect(
        WindowBoundsUnits.tryFromWireName('logical'),
        equals(WindowBoundsUnits.logical),
      );
      expect(WindowBoundsUnits.tryFromWireName('pixels'), isNull);
      expect(WindowBoundsUnits.tryFromWireName(123), isNull);
      expect(WindowBoundsUnits.tryFromWireName(null), isNull);
    });

    test('WindowBoundsRect parses finite maps and rejects invalid inputs', () {
      const rect = WindowBoundsRect(x: -10, y: 20.5, width: 1920, height: 1080);
      expect(WindowBoundsRect.tryFromMap(rect.toJson()), equals(rect));
      expect(
        WindowBoundsRect.tryFromMap(rect.toJson()).hashCode,
        equals(rect.hashCode),
      );
      expect(rect.toString(), contains('1920'));

      // Accepts integer coordinates as doubles.
      expect(
        WindowBoundsRect.tryFromMap(<String, Object?>{
          'x': 0,
          'y': 0,
          'width': 800,
          'height': 600,
        }),
        equals(const WindowBoundsRect(x: 0, y: 0, width: 800, height: 600)),
      );

      for (final invalid in const <Object?>[
        null,
        'not-a-map',
        <String, Object?>{'x': 0, 'y': 0, 'width': 100},
        <String, Object?>{'x': double.nan, 'y': 0, 'width': 100, 'height': 100},
        <String, Object?>{
          'x': 0,
          'y': double.infinity,
          'width': 100,
          'height': 100,
        },
        <String, Object?>{'x': 0, 'y': 0, 'width': -1, 'height': 100},
        <String, Object?>{'x': 0, 'y': 0, 'width': 100, 'height': -5},
        <String, Object?>{'x': '0', 'y': 0, 'width': 100, 'height': 100},
      ]) {
        expect(
          WindowBoundsRect.tryFromMap(invalid),
          isNull,
          reason: '$invalid',
        );
      }
    });

    test(
      'WindowBoundsSnapshot parses channel maps and supports unsupported',
      () {
        expect(WindowBoundsSnapshot.unsupported.supported, isFalse);
        expect(WindowBoundsSnapshot.unsupported.physical, isNull);
        expect(WindowBoundsSnapshot.unsupported.logical, isNull);
        expect(
          WindowBoundsSnapshot.unsupported.toJson(),
          equals(<String, Object?>{
            'supported': false,
            'dpr': 1.0,
            'alwaysOnTop': false,
            'squareCorners': false,
          }),
        );

        expect(
          WindowBoundsSnapshot.fromChannelMap(null),
          equals(WindowBoundsSnapshot.unsupported),
        );
        expect(
          WindowBoundsSnapshot.fromChannelMap(<String, Object?>{
            'supported': false,
          }),
          equals(WindowBoundsSnapshot.unsupported),
        );
        expect(
          WindowBoundsSnapshot.fromChannelMap(<String, Object?>{
            'supported': true,
          }),
          equals(WindowBoundsSnapshot.unsupported),
        );

        final parsed = WindowBoundsSnapshot.fromChannelMap(<String, Object?>{
          'supported': true,
          'physical': <String, Object?>{
            'x': 0,
            'y': 0,
            'width': 1920,
            'height': 1080,
          },
          'logical': <String, Object?>{
            'x': 0,
            'y': 0,
            'width': 1280,
            'height': 720,
          },
          'dpr': 1.5,
          'alwaysOnTop': true,
          'squareCorners': true,
        });
        expect(parsed.supported, isTrue);
        expect(
          parsed.physical,
          equals(const WindowBoundsRect(x: 0, y: 0, width: 1920, height: 1080)),
        );
        expect(
          parsed.logical,
          equals(const WindowBoundsRect(x: 0, y: 0, width: 1280, height: 720)),
        );
        expect(parsed.dpr, equals(1.5));
        expect(parsed.alwaysOnTop, isTrue);
        expect(parsed.squareCorners, isTrue);
        expect(
          WindowBoundsSnapshot.fromChannelMap(parsed.toJson()),
          equals(parsed),
        );
        expect(
          WindowBoundsSnapshot.fromChannelMap(parsed.toJson()).hashCode,
          equals(parsed.hashCode),
        );

        // Non-positive or non-finite DPR falls back to 1.0.
        final badDpr = WindowBoundsSnapshot.fromChannelMap(<String, Object?>{
          'supported': true,
          'physical': WindowBoundsRect.zero.toJson(),
          'dpr': -2,
        });
        expect(badDpr.dpr, equals(1.0));
      },
    );

    test('WindowBoundsRequest validates JSON fields and round-trips', () {
      final full = WindowBoundsRequest.fromJson(<String, Object?>{
        'x': 100,
        'y': 50.5,
        'width': 1280,
        'height': 720,
        'units': 'logical',
        'squareCorners': true,
        'alwaysOnTop': false,
        'focus': true,
      });
      expect(full.x, equals(100.0));
      expect(full.y, equals(50.5));
      expect(full.width, equals(1280.0));
      expect(full.height, equals(720.0));
      expect(full.units, equals(WindowBoundsUnits.logical));
      expect(full.squareCorners, isTrue);
      expect(full.alwaysOnTop, isFalse);
      expect(full.focus, isTrue);
      expect(full.hasPositionChange, isTrue);
      expect(full.hasSizeChange, isTrue);
      expect(full.isEmpty, isFalse);
      expect(WindowBoundsRequest.fromJson(full.toJson()), equals(full));
      expect(
        WindowBoundsRequest.fromJson(full.toJson()).hashCode,
        equals(full.hashCode),
      );

      final empty = WindowBoundsRequest.fromJson(const <String, Object?>{});
      expect(empty.units, equals(WindowBoundsUnits.physical));
      expect(empty.hasPositionChange, isFalse);
      expect(empty.hasSizeChange, isFalse);
      expect(empty.isEmpty, isTrue);
      expect(
        empty.toJson(),
        equals(const <String, Object?>{'units': 'physical'}),
      );

      for (final badPayload in <Map<String, Object?>>[
        <String, Object?>{'x': double.nan},
        <String, Object?>{'y': double.infinity},
        <String, Object?>{'x': '100'},
        <String, Object?>{'width': 0},
        <String, Object?>{'width': -10},
        <String, Object?>{'height': 0},
        <String, Object?>{'height': double.negativeInfinity},
        <String, Object?>{'units': 'cm'},
        <String, Object?>{'units': 1},
        <String, Object?>{'squareCorners': 'yes'},
        <String, Object?>{'alwaysOnTop': 1},
        <String, Object?>{'focus': 'true'},
      ]) {
        expect(
          () => WindowBoundsRequest.fromJson(badPayload),
          throwsFormatException,
          reason: '$badPayload',
        );
      }
    });
  });

  group('AutomationDriverConfig', () {
    test('enforces port range 1..65535 and default port 9911', () {
      expect(AutomationDriverConfig.defaultPort, equals(9911));
      expect(AutomationDriverConfig.isValidPort(0), isFalse);
      expect(AutomationDriverConfig.isValidPort(-1), isFalse);
      expect(AutomationDriverConfig.isValidPort(1), isTrue);
      expect(AutomationDriverConfig.isValidPort(9911), isTrue);
      expect(AutomationDriverConfig.isValidPort(65535), isTrue);
      expect(AutomationDriverConfig.isValidPort(65536), isFalse);

      expect(
        () => AutomationDriverConfig(port: 0, password: 'abc'),
        throwsRangeError,
      );
      expect(
        () => AutomationDriverConfig(port: 65536, password: 'abc'),
        throwsRangeError,
      );
      expect(
        () => AutomationDriverConfig(port: -10, password: 'abc'),
        throwsRangeError,
      );
    });

    test('generatePassword uses 4x5 unambiguous alphanumeric groups', () {
      final pattern = RegExp(
        r'^[abcdefghjkmnpqrstuvwxyz23456789]{5}'
        r'(?:-[abcdefghjkmnpqrstuvwxyz23456789]{5}){3}$',
      );
      final ambiguous = RegExp(r'[01iloILO]');
      final generated = <String>{};

      for (var i = 0; i < 64; i++) {
        final pw = AutomationDriverConfig.generatePassword();
        expect(pw.length, equals(23));
        expect(pattern.hasMatch(pw), isTrue, reason: pw);
        expect(ambiguous.hasMatch(pw), isFalse, reason: pw);
        generated.add(pw);
      }
      // 64 secure generations must all be distinct.
      expect(generated.length, equals(64));

      // Deterministic seed support for reproducible tests.
      expect(
        AutomationDriverConfig.generatePassword(random: Random(42)),
        equals(AutomationDriverConfig.generatePassword(random: Random(42))),
      );
    });

    test('round-trips JSON and handles malformed persisted payloads', () {
      final config = AutomationDriverConfig(
        port: 9942,
        password: AutomationDriverConfig.generatePassword(),
      );
      expect(config.hasPassword, isTrue);
      expect(config.toString(), contains('9942'));

      final encoded = config.toJsonString();
      final decoded = AutomationDriverConfig.tryFromJsonString(encoded);
      expect(decoded, equals(config));
      expect(decoded.hashCode, equals(config.hashCode));

      final copied = config.copyWith(port: 9955);
      expect(copied.port, equals(9955));
      expect(copied.password, equals(config.password));
      expect(copied, isNot(equals(config)));

      // Out-of-range or non-integer port falls back to defaultPort.
      final badPort = AutomationDriverConfig.fromJson(<String, Object?>{
        'port': 70000,
        'password': '  secret-token  ',
      });
      expect(badPort.port, equals(AutomationDriverConfig.defaultPort));
      expect(badPort.password, equals('secret-token'));

      final fractionalPort = AutomationDriverConfig.fromJson(<String, Object?>{
        'port': 9911.5,
      });
      expect(fractionalPort.port, equals(AutomationDriverConfig.defaultPort));
      expect(fractionalPort.hasPassword, isFalse);

      final wholeDoublePort = AutomationDriverConfig.fromJson(<String, Object?>{
        'port': 9920.0,
        'password': 'abc',
      });
      expect(wholeDoublePort.port, equals(9920));

      expect(AutomationDriverConfig.tryFromJsonString(null), isNull);
      expect(AutomationDriverConfig.tryFromJsonString('   '), isNull);
      expect(AutomationDriverConfig.tryFromJsonString('{bad'), isNull);
      expect(AutomationDriverConfig.tryFromJsonString('[]'), isNull);
    });
  });

  group('Automation HTTP & screen models', () {
    test('AutomationHttpResponse formats ok and error JSON envelopes', () {
      final ok = AutomationHttpResponse.ok(<String, Object?>{'port': 9911});
      expect(ok.statusCode, equals(200));
      expect(ok.isOk, isTrue);
      expect(
        jsonDecode(ok.toJsonString()),
        equals(<String, Object?>{
          'ok': true,
          'result': <String, Object?>{'port': 9911},
        }),
      );

      final err = AutomationHttpResponse.error(
        statusCode: 403,
        code: 'pty_disabled',
        message: 'Allow PTY is disabled.',
      );
      expect(err.statusCode, equals(403));
      expect(err.isOk, isFalse);
      expect(
        jsonDecode(err.toJsonString()),
        equals(<String, Object?>{
          'ok': false,
          'error': <String, Object?>{
            'code': 'pty_disabled',
            'message': 'Allow PTY is disabled.',
          },
        }),
      );

      final detailed = AutomationHttpResponse.error(
        statusCode: 422,
        code: 'shader_compile_error',
        message: 'GLSL compile failed.',
        details: <String, Object?>{'errorCount': 2},
      );
      expect(
        (detailed.body['error'] as Map<String, Object?>)['details'],
        equals(<String, Object?>{'errorCount': 2}),
      );
    });

    test(
      'screen match, snapshot, storage key, and unsupported bridge contracts',
      () async {
        expect(ftermAutomationConfigStorageKey, equals('fterm.automation.v1'));
        expect(
          AutomationPtyWriteResult.values,
          equals(const [
            AutomationPtyWriteResult.ok,
            AutomationPtyWriteResult.exited,
            AutomationPtyWriteResult.editorPane,
            AutomationPtyWriteResult.notFound,
          ]),
        );

        const match = AutomationScreenMatch(
          row: 3,
          col: 4,
          endCol: 10,
          text: 'hello!',
          x: 0.25,
          y: 0.5,
        );
        expect(
          match.toJson(),
          equals(<String, Object?>{
            'row': 3,
            'col': 4,
            'endCol': 10,
            'text': 'hello!',
            'x': 0.25,
            'y': 0.5,
          }),
        );
        expect(
          const AutomationScreenMatch(
            row: 3,
            col: 4,
            endCol: 10,
            text: 'hello!',
            x: 0.25,
            y: 0.5,
          ),
          equals(match),
        );

        final snapshot = AutomationScreenSnapshot(
          paneId: 'pane-1',
          cols: 80,
          rows: 24,
          cursorCol: 5,
          cursorRow: 2,
          cursorVisible: true,
          lines: <String>['line 0', 'line 1'],
        );
        expect(() => snapshot.lines.add('mutated'), throwsUnsupportedError);
        expect(
          snapshot.toJson(),
          equals(<String, Object?>{
            'paneId': 'pane-1',
            'cols': 80,
            'rows': 24,
            'cursor': <String, Object?>{'col': 5, 'row': 2, 'visible': true},
            'lines': const ['line 0', 'line 1'],
          }),
        );
        expect(
          AutomationScreenSnapshot(
            paneId: 'pane-1',
            cols: 80,
            rows: 24,
            cursorCol: 5,
            cursorRow: 2,
            cursorVisible: true,
            lines: const ['line 0', 'line 1'],
          ),
          equals(snapshot),
        );

        const bridge = UnsupportedAutomationWindowBridge();
        expect(
          await bridge.getBounds(),
          equals(WindowBoundsSnapshot.unsupported),
        );
        expect(
          await bridge.setBounds(const WindowBoundsRequest(width: 800)),
          equals(WindowBoundsSnapshot.unsupported),
        );
      },
    );
  });

  group('Automation CLI flags, env override, and relaunch sanitization', () {
    final desktopBase = Uri.parse('file:///C:/Users/dev/fterm/');

    test('CastLaunchConfig defaults all automation fields to off/null', () {
      final config = CastLaunchConfig();
      expect(config.automationDriverEnabled, isFalse);
      expect(config.automationAllowPty, isFalse);
      expect(config.automationPort, isNull);
      expect(config.automationTokenOverride, isNull);
    });

    test('resolveCastLaunchConfig forwards automation flags without relay/IAP/trace config', () {
      final driverOnly = resolveCastLaunchConfig(
        baseUri: desktopBase,
        args: const ['--automation-driver'],
        environment: const {},
      );
      expect(driverOnly.automationDriverEnabled, isTrue);
      expect(driverOnly.automationAllowPty, isFalse);
      expect(driverOnly.automationPort, isNull);
      expect(driverOnly.automationTokenOverride, isNull);
      expect(driverOnly.relaunchArgs, isEmpty);

      final equalsPort = resolveCastLaunchConfig(
        baseUri: desktopBase,
        args: const [
          '--automation-driver',
          '--automation-allow-pty',
          '--automation-port=9922',
        ],
        environment: const {'FTERM_AUTOMATION_TOKEN': '  ephemeral-secret  '},
      );
      expect(equalsPort.automationDriverEnabled, isTrue);
      expect(equalsPort.automationAllowPty, isTrue);
      expect(equalsPort.automationPort, equals(9922));
      expect(equalsPort.automationTokenOverride, equals('ephemeral-secret'));
      expect(equalsPort.relaunchArgs, isEmpty);

      final spacePort = resolveCastLaunchConfig(
        baseUri: desktopBase,
        args: const ['--automation-port', '65535'],
        environment: const {},
      );
      expect(spacePort.automationDriverEnabled, isFalse);
      expect(spacePort.automationAllowPty, isFalse);
      expect(spacePort.automationPort, equals(65535));
      expect(spacePort.automationTokenOverride, isNull);

      final tokenOnly = resolveCastLaunchConfig(
        baseUri: desktopBase,
        environment: const {'FTERM_AUTOMATION_TOKEN': 'env-only-token'},
      );
      expect(tokenOnly.automationDriverEnabled, isFalse);
      expect(tokenOnly.automationTokenOverride, equals('env-only-token'));

      final blankToken = resolveCastLaunchConfig(
        baseUri: desktopBase,
        environment: const {'FTERM_AUTOMATION_TOKEN': '   '},
      );
      expect(blankToken.automationTokenOverride, isNull);
    });

    test(
      'rejects --automation-token, invalid ports, and unexpected flag values',
      () {
        for (final tokenArgs in const <List<String>>[
          ['--automation-token', 'secret'],
          ['--automation-token=secret'],
          ['--automation-token'],
        ]) {
          expect(
            () => resolveCastLaunchConfig(
              baseUri: desktopBase,
              args: tokenArgs,
              environment: const {},
            ),
            throwsA(
              isA<FormatException>().having(
                (e) => e.message,
                'message',
                contains('FTERM_AUTOMATION_TOKEN'),
              ),
            ),
            reason: '$tokenArgs',
          );
        }

        for (final badArgs in const <List<String>>[
          ['--automation-port'],
          ['--automation-port='],
          ['--automation-port=   '],
          ['--automation-port=0'],
          ['--automation-port=-1'],
          ['--automation-port=65536'],
          ['--automation-port=not-a-port'],
          ['--automation-driver=true'],
          ['--automation-allow-pty=false'],
        ]) {
          expect(
            () => resolveCastLaunchConfig(
              baseUri: desktopBase,
              args: badArgs,
              environment: const {},
            ),
            throwsFormatException,
            reason: '$badArgs',
          );
        }

        // Arguments after `--` are ignored (including --automation-token).
        final afterSeparator = resolveCastLaunchConfig(
          baseUri: desktopBase,
          args: const [
            '--',
            '--automation-driver',
            '--automation-token=ignored',
            '--automation-port=0',
          ],
          environment: const {},
        );
        expect(afterSeparator.automationDriverEnabled, isFalse);
        expect(afterSeparator.automationPort, isNull);
      },
    );

    test('excludes all --automation-* flags from relaunchArgs while keeping safe flags', () {
      final overrides = parseDesktopLaunchOverrides(
        args: const [
          '--server',
          'wss://relay.example.com/v1/client',
          '--automation-driver',
          '--automation-allow-pty',
          '--automation-port=9944',
        ],
        environment: const {'FTERM_AUTOMATION_TOKEN': 'ephemeral-tok'},
      );
      expect(overrides.hasAutomationConfig, isTrue);
      expect(
        overrides.relaunchArgs,
        equals(const ['--server', 'wss://relay.example.com/v1/client']),
      );
    });

    test('relaunchPlatformDesktopApp strips FTERM_AUTOMATION_TOKEN alongside FTERM_GPU_PREFERENCE', () async {
      Map<String, String>? capturedEnv;
      final launched = await relaunchPlatformDesktopApp(
        args: const ['--server', 'wss://relay.example'],
        environment: const {
          'PATH': '/usr/bin',
          'FTERM_GPU_PREFERENCE': 'highPerformance',
          'FTERM_AUTOMATION_TOKEN': 'ephemeral-secret-token',
        },
        processStarter:
            (
              executable,
              arguments, {
              environment,
              includeParentEnvironment = true,
              mode = ProcessStartMode.normal,
            }) async {
              capturedEnv = environment;
              return Object();
            },
      );
      expect(launched, isTrue);
      expect(capturedEnv, equals(const {'PATH': '/usr/bin'}));
    });
  });
}
