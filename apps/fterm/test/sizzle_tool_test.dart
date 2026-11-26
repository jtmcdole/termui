import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/automation/automation_http_server_io.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:path/path.dart' as p;

import '../tool/sizzle.dart';

void main() {
  group('SizzleConfig', () {
    test('parses defaults, env overrides, and persisted settings fallback', () {
      final config = SizzleConfig.parseArgs(
        const <String>['--no-obs', '--mode=takes', '--acts=1,3'],
        environment: const <String, String>{},
        persistedConfig: const PersistedFtermDriverConfig(
          port: 9922,
          password: 'saved-token-12345',
        ),
      );
      expect(config.ftermPort, 9922);
      expect(config.ftermToken, 'saved-token-12345');
      expect(config.useObs, isFalse);
      expect(config.mode, SizzleRecordingMode.takes);
      expect(config.acts, <int>{1, 3});
      expect(config.shaderPreset, 'wallpaper_wave');
      expect(config.foregroundPresets, const <String>[
        'scanline_overlay',
        'phosphor_glow',
      ]);
    });

    test('FTERM_AUTOMATION_TOKEN overrides persisted password', () {
      final config = SizzleConfig.parseArgs(
        const <String>[],
        environment: const <String, String>{
          'FTERM_AUTOMATION_TOKEN': 'env-override-token',
          'OBS_WEBSOCKET_PASSWORD': 'obs-secret',
        },
        persistedConfig: const PersistedFtermDriverConfig(
          port: 9911,
          password: 'saved-token',
        ),
      );
      expect(config.ftermToken, 'env-override-token');
      expect(config.obsPassword, 'obs-secret');
    });

    test('rejects invalid mode, act, port, and unknown flags', () {
      expect(
        () => SizzleConfig.parseArgs(const <String>['--mode=bogus']),
        throwsFormatException,
      );
      expect(
        () => SizzleConfig.parseArgs(const <String>['--acts=9']),
        throwsFormatException,
      );
      expect(
        () => SizzleConfig.parseArgs(const <String>['--port=99999']),
        throwsFormatException,
      );
      expect(
        () => SizzleConfig.parseArgs(const <String>['--not-a-flag']),
        throwsFormatException,
      );
    });

    test('reads persisted config from desktop settings.json', () {
      final tempDir = Directory.systemTemp.createTempSync('sizzle_cfg_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final settingsFile = File(p.join(tempDir.path, 'fterm', 'settings.json'));
      settingsFile.parent.createSync(recursive: true);
      settingsFile.writeAsStringSync(
        jsonEncode(<String, Object?>{
          'fterm.automation.v1': jsonEncode(<String, Object?>{
            'port': 9944,
            'password': 'abcde-fghjk-mnpqr-stuvw',
          }),
        }),
      );

      final parsed = readPersistedFtermDriverConfig(
        environment: <String, String>{'APPDATA': tempDir.path},
        isWindows: true,
      );
      expect(parsed, isNotNull);
      expect(parsed!.port, 9944);
      expect(parsed.password, 'abcde-fghjk-mnpqr-stuvw');
    });

    test(
      '--launch-fterm generates ephemeral token and builds safe CLI args',
      () {
        final config = SizzleConfig.parseArgs(const <String>[
          '--launch-fterm',
          '--port=9955',
          '--keep-fterm',
        ], environment: const <String, String>{});
        expect(config.launchFterm, isTrue);
        expect(config.keepFterm, isTrue);
        expect(
          config.ftermToken,
          matches(RegExp(r'^[a-z2-9]{5}(-[a-z2-9]{5}){3}$')),
        );
        final args = buildFtermLaunchArgs(config);
        expect(args, <String>[
          '--automation-driver',
          '--automation-allow-pty',
          '--automation-port=9955',
          '--window-title=fterm-sizzle',
        ]);
        expect(args.join(' '), isNot(contains(config.ftermToken)));

        final childEnv = buildFtermLaunchEnvironment(const <String, String>{
          'PATH': r'C:\Windows',
          'TERM': 'dumb',
          'WT_SESSION': 'abc',
          'POSH_SESSION_ID': 'xyz',
        }, token: config.ftermToken);
        expect(childEnv['PATH'], r'C:\Windows');
        expect(childEnv['FTERM_AUTOMATION_TOKEN'], config.ftermToken);
        expect(childEnv.containsKey('TERM'), isFalse);
        expect(childEnv.containsKey('WT_SESSION'), isFalse);
        expect(childEnv.containsKey('POSH_SESSION_ID'), isFalse);
      },
    );

    test(
      'injectHighlightedItsDefine hoists loop bound to top-level #define ITS',
      () {
        const raw = '''
void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    for (float i = 0.0; i < 4.0; i++) {
    }
}
''';
        final rewritten = injectHighlightedItsDefine(raw, initialValue: '1');
        expect(rewritten, isNotNull);
        expect(
          rewritten,
          startsWith(
            '// @fterm-stage: bg\n'
            '// vvvvvv live edit vvvvvv\n'
            '#define ITS 1\n'
            '//         ^^^\n',
          ),
        );
        expect(rewritten, contains('for (float i = 0.0; i < float(ITS); i++)'));
        expect(
          injectHighlightedItsDefine('void main() {}', initialValue: '1'),
          isNull,
        );
      },
    );

    test('resolveFtermExecutablePath prefers Release over Debug', () {
      final tempDir = Directory.systemTemp.createTempSync('sizzle_bin_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final debugBin = File(
        p.join(
          tempDir.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Debug',
          'fterm.exe',
        ),
      )..createSync(recursive: true);
      expect(
        resolveFtermExecutablePath(workingDir: tempDir.path, isWindows: true),
        debugBin.absolute.path,
      );
      final releaseBin = File(
        p.join(
          tempDir.path,
          'build',
          'windows',
          'x64',
          'runner',
          'Release',
          'fterm.exe',
        ),
      )..createSync(recursive: true);
      expect(
        resolveFtermExecutablePath(workingDir: tempDir.path, isWindows: true),
        releaseBin.absolute.path,
      );
    });
  });

  group('waitForFtermDriverReady', () {
    test('retries until loopback automation server binds', () async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final freePort = probe.port;
      await probe.close();

      final server = IoAutomationHttpServer();
      addTearDown(server.stop);

      final client = FtermDriverClient(
        baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: freePort),
        token: 'ready-token',
      );
      addTearDown(client.close);

      var polls = 0;
      await waitForFtermDriverReady(
        client,
        pollInterval: Duration.zero,
        sleep: (_) async {
          polls++;
          if (polls == 2) {
            await server.start(
              port: freePort,
              password: 'ready-token',
              allowPty: true,
              onRequest: (_) async => AutomationHttpResponse.ok(
                const <String, Object?>{'overlay': 'none'},
              ),
            );
          }
        },
      );
      expect(polls, greaterThanOrEqualTo(2));
    });
  });

  group('FtermDriverClient', () {
    late IoAutomationHttpServer server;
    late List<AutomationHttpRequest> recorded;
    late FtermDriverClient client;
    var findPollCount = 0;

    setUp(() async {
      recorded = <AutomationHttpRequest>[];
      findPollCount = 0;
      server = IoAutomationHttpServer();
      await server.start(
        port: 0,
        password: 'test-sizzle-password',
        allowPty: true,
        onRequest: (request) async {
          recorded.add(request);
          return switch ((request.method, request.path)) {
            ('GET', '/v1/shader') => AutomationHttpResponse.ok(
              <String, Object?>{
                'background': const <String>[],
                'foreground': const <String>[],
                'backgroundOpacity': 1.0,
                'availablePresets': const <String>[
                  'wallpaper_wave',
                  'scanline_overlay',
                  'phosphor_glow',
                ],
              },
            ),
            ('GET', '/v1/screen') => AutomationHttpResponse.ok(
              <String, Object?>{
                'paneId': request.queryParameters['paneId'] ?? 'pane-1',
                'cols': 80,
                'rows': 24,
                'cursor': const <String, Object?>{
                  'col': 12,
                  'row': 1,
                  'visible': true,
                },
                'lines': const <String>['PowerShell 7.5.0', 'john@dev ~> ', ''],
              },
            ),
            ('POST', '/v1/screen/find') => () {
              findPollCount++;
              final matches = findPollCount >= 2
                  ? <Map<String, Object?>>[
                      <String, Object?>{
                        'row': 3,
                        'col': 5,
                        'endCol': 13,
                        'text': '[ Cast ]',
                        'x': 0.25,
                        'y': 0.5,
                      },
                    ]
                  : const <Map<String, Object?>>[];
              return AutomationHttpResponse.ok(<String, Object?>{
                'paneId': 'pane-1',
                'cols': 80,
                'rows': 24,
                'matches': matches,
              });
            }(),
            ('POST', '/v1/shader/editor') => AutomationHttpResponse.ok(
              <String, Object?>{
                'open': true,
                'paneId': 'editor-1',
                'compiled': request.body?['awaitCompile'] == true,
              },
            ),
            ('POST', '/v1/pty/write') => AutomationHttpResponse.ok(
              <String, Object?>{'paneId': 'pane-1', 'bytesWritten': 1},
            ),
            ('POST', '/v1/input/pointer') => AutomationHttpResponse.ok(
              <String, Object?>{'paneId': 'editor-1'},
            ),
            _ => AutomationHttpResponse.error(
              statusCode: 404,
              code: 'not_found',
              message: 'Unknown route',
            ),
          };
        },
      );
      client = FtermDriverClient(
        baseUri: Uri(scheme: 'http', host: '127.0.0.1', port: server.boundPort),
        token: 'test-sizzle-password',
        sleep: (_) async {},
        random: math.Random(42),
      );
    });

    tearDown(() async {
      client.close();
      await server.stop();
    });

    test('livePatchConstant defers awaitCompile until final char', () async {
      await client.livePatchConstant(
        prefix: 'uParams0.x : ',
        oldVal: '0.35',
        newVal: '1.85',
        keystrokeDelay: Duration.zero,
      );

      expect(recorded, hasLength(4));
      expect(recorded[0].body, <String, Object?>{
        'open': false,
        'find': 'uParams0.x : 0.35',
        'replace': 'uParams0.x : 1',
        'awaitCompile': false,
      });
      expect(recorded[1].body, <String, Object?>{
        'open': false,
        'find': 'uParams0.x : 1',
        'replace': 'uParams0.x : 1.',
        'awaitCompile': false,
      });
      expect(recorded[2].body, <String, Object?>{
        'open': false,
        'find': 'uParams0.x : 1.',
        'replace': 'uParams0.x : 1.8',
        'awaitCompile': false,
      });
      expect(recorded[3].body, <String, Object?>{
        'open': false,
        'find': 'uParams0.x : 1.8',
        'replace': 'uParams0.x : 1.85',
        'awaitCompile': true,
      });
    });

    test('typeHuman sends single characters followed by CR', () async {
      await client.typeHuman('pane-1', 'ls');
      expect(recorded.map((r) => r.body?['text']).toList(), <Object?>[
        'l',
        's',
        '\r',
      ]);
    });

    test('waitForScreen polls until a match appears', () async {
      final hit = await client.waitForScreen(
        'pane-1',
        r'\[ Cast \]',
        pollInterval: Duration.zero,
      );
      expect(findPollCount, 2);
      expect(hit['text'], '[ Cast ]');
      expect(hit['x'], 0.25);
    });

    test('waitForScreen timeout includes visible screen lines', () async {
      await expectLater(
        () => client.waitForScreen(
          'pane-1',
          'NEVER_MATCHES',
          timeout: Duration.zero,
          pollInterval: Duration.zero,
        ),
        throwsA(
          isA<TimeoutException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('Visible screen on "pane-1" (80x24'),
              contains('[00] PowerShell 7.5.0'),
              contains('[01] john@dev ~>'),
            ),
          ),
        ),
      );
    });

    test(
      'sweepShaderPointer sends Lissajous steps and clears on exit',
      () async {
        await client.sweepShaderPointer(
          'editor-1',
          fixedSteps: 3,
          stepInterval: const Duration(milliseconds: 16),
        );
        expect(recorded, hasLength(4));
        for (var i = 0; i < 3; i++) {
          expect(recorded[i].body?['pressed'], isFalse);
          expect(recorded[i].body?['x'], inInclusiveRange(0.0, 1.0));
          expect(recorded[i].body?['y'], inInclusiveRange(0.0, 1.0));
        }
        expect(recorded.last.body, <String, Object?>{
          'paneId': 'editor-1',
          'clear': true,
        });
      },
    );
  });

  group('ObsWebSocketClient', () {
    test('authenticates with SHA-256 and tracks recording lifecycle', () async {
      final httpServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => httpServer.close(force: true));

      final receivedRequests = <String>[];
      const expectedPassword = 'obs-test-password';
      const salt = 'test-salt-value';
      const challenge = 'test-challenge-value';
      final expectedAuth = ObsWebSocketClient.computeAuthString(
        password: expectedPassword,
        salt: salt,
        challenge: challenge,
      );

      unawaited(() async {
        await for (final req in httpServer) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.add(
            jsonEncode(<String, Object?>{
              'op': 0,
              'd': <String, Object?>{
                'obsWebSocketVersion': '5.5.0',
                'rpcVersion': 1,
                'authentication': <String, Object?>{
                  'challenge': challenge,
                  'salt': salt,
                },
              },
            }),
          );
          await for (final raw in ws) {
            final msg = jsonDecode(raw as String) as Map<Object?, Object?>;
            final op = msg['op'] as int;
            final data = msg['d'] as Map<Object?, Object?>;
            if (op == 1) {
              expect(data['authentication'], expectedAuth);
              ws.add(
                jsonEncode(<String, Object?>{
                  'op': 2,
                  'd': <String, Object?>{'negotiatedRpcVersion': 1},
                }),
              );
            } else if (op == 6) {
              final type = data['requestType'] as String;
              final requestId = data['requestId'] as String;
              receivedRequests.add(type);
              final responseData = switch (type) {
                'StopRecord' => <String, Object?>{
                  'outputPath': r'C:\temp\raw_capture.mkv',
                },
                'GetSceneItemId' => <String, Object?>{'sceneItemId': 7},
                _ => const <String, Object?>{},
              };
              ws.add(
                jsonEncode(<String, Object?>{
                  'op': 7,
                  'd': <String, Object?>{
                    'requestType': type,
                    'requestId': requestId,
                    'requestStatus': <String, Object?>{
                      'result': true,
                      'code': 100,
                    },
                    'responseData': responseData,
                  },
                }),
              );
              if (type == 'StartRecord') {
                ws.add(
                  jsonEncode(<String, Object?>{
                    'op': 5,
                    'd': <String, Object?>{
                      'eventType': 'RecordStateChanged',
                      'eventData': <String, Object?>{
                        'outputActive': true,
                        'outputState': 'OBS_WEBSOCKET_OUTPUT_STARTED',
                      },
                    },
                  }),
                );
              } else if (type == 'StopRecord') {
                ws.add(
                  jsonEncode(<String, Object?>{
                    'op': 5,
                    'd': <String, Object?>{
                      'eventType': 'RecordStateChanged',
                      'eventData': <String, Object?>{
                        'outputActive': false,
                        'outputState': 'OBS_WEBSOCKET_OUTPUT_STOPPED',
                        'outputPath': r'C:\temp\raw_capture.mkv',
                      },
                    },
                  }),
                );
              }
            }
          }
        }
      }());

      final obs = await ObsWebSocketClient.connect(
        Uri(scheme: 'ws', host: '127.0.0.1', port: httpServer.port),
        password: expectedPassword,
        overlayInput: 'LowerThirdText',
        overlayScene: 'MainStage',
      );
      addTearDown(obs.close);

      await obs.startRecord();
      await obs.createRecordChapter('01_live_glsl_editor');
      await obs.setOverlayBadge('Hello Sizzle');
      await obs.clearOverlayBadge();
      final path = await obs.stopRecord();

      expect(path, r'C:\temp\raw_capture.mkv');
      expect(receivedRequests, <String>[
        'StartRecord',
        'CreateRecordChapter',
        'SetInputSettings',
        'GetSceneItemId',
        'SetSceneItemEnabled',
        'GetSceneItemId',
        'SetSceneItemEnabled',
        'SetInputSettings',
        'StopRecord',
      ]);
    });
  });
}
