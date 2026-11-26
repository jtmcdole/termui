@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/automation/automation_driver_controller.dart';
import 'package:fterm/src/automation/automation_http_server.dart';
import 'package:fterm/src/automation/automation_http_server_io.dart';
import 'package:fterm/src/automation/automation_http_server_stub.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/automation/automation_screen_search.dart';
import 'package:fterm/src/settings_storage.dart';
import 'package:termui/termui.dart' as tui;

final class _MemorySettingsStorage implements SettingsStorage {
  final Map<String, String> values = <String, String>{};
  int getCount = 0;
  int setCount = 0;

  @override
  String? getItem(String key) {
    getCount++;
    return values[key];
  }

  @override
  void setItem(String key, String value) {
    setCount++;
    values[key] = value;
  }
}

final class _HttpResult {
  final int statusCode;
  final HttpHeaders headers;
  final Map<String, Object?> json;

  const _HttpResult({
    required this.statusCode,
    required this.headers,
    required this.json,
  });
}

Future<_HttpResult> _sendRequest(
  HttpClient client, {
  required String method,
  required int port,
  required String path,
  String? hostHeader,
  String? authHeader,
  String? contentType,
  List<int>? bodyBytes,
  bool chunked = false,
}) async {
  final uri = Uri.parse('http://127.0.0.1:$port$path');
  final request = await client.openUrl(method, uri);
  if (hostHeader != null) {
    request.headers.set(HttpHeaders.hostHeader, hostHeader);
  }
  if (authHeader != null) {
    request.headers.set(HttpHeaders.authorizationHeader, authHeader);
  }
  if (contentType != null) {
    request.headers.set(HttpHeaders.contentTypeHeader, contentType);
  }
  if (bodyBytes != null) {
    if (chunked) {
      request.headers.chunkedTransferEncoding = true;
      const chunkSize = 16 * 1024;
      for (var offset = 0; offset < bodyBytes.length; offset += chunkSize) {
        final end = min(offset + chunkSize, bodyBytes.length);
        request.add(bodyBytes.sublist(offset, end));
      }
    } else {
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);
    }
  }
  final response = await request.close();
  final rawText = await utf8.decoder.bind(response).join();
  final Object? decoded = jsonDecode(rawText);
  return _HttpResult(
    statusCode: response.statusCode,
    headers: response.headers,
    json: decoded is Map<Object?, Object?>
        ? <String, Object?>{
            for (final MapEntry(:key, :value) in decoded.entries)
              if (key is String) key: value,
          }
        : <String, Object?>{},
  );
}

void main() {
  group('constantTimeEquals & platform factory', () {
    test(
      'compares equal, unequal, and differing-length strings accurately',
      () {
        expect(constantTimeEquals('abc-123', 'abc-123'), isTrue);
        expect(constantTimeEquals('abc-123', 'abc-124'), isFalse);
        expect(constantTimeEquals('abc-123', 'abc-1234'), isFalse);
        expect(constantTimeEquals('', ''), isTrue);
        expect(constantTimeEquals('secret', ''), isFalse);
        expect(constantTimeEquals('🚀token', '🚀token'), isTrue);
        expect(constantTimeEquals('🚀token', '🚀tokeN'), isFalse);
      },
    );

    test('createAutomationHttpServerBackend returns IO backend on VM', () {
      final backend = createAutomationHttpServerBackend();
      expect(backend, isA<IoAutomationHttpServer>());
      expect(backend.isSupported, isTrue);
      expect(backend.isRunning, isFalse);
      expect(backend.boundPort, isNull);
    });

    test('StubAutomationHttpServer is an inert unsupported backend', () async {
      const stub = StubAutomationHttpServer();
      expect(stub.isSupported, isFalse);
      expect(stub.isRunning, isFalse);
      expect(stub.boundPort, isNull);
      await stub.start(
        port: 9911,
        password: 'pw',
        allowPty: true,
        onRequest: (_) async => AutomationHttpResponse.ok(<String, Object?>{}),
      );
      stub.updatePassword('pw2');
      stub.updateAllowPty(false);
      await stub.stop();
      expect(stub.isRunning, isFalse);
      expect(stub.boundPort, isNull);
    });
  });

  group('IoAutomationHttpServer security & queueing', () {
    late IoAutomationHttpServer server;
    late HttpClient client;
    late List<AutomationHttpRequest> recorded;
    late AutomationRequestHandler activeHandler;

    setUp(() async {
      recorded = <AutomationHttpRequest>[];
      activeHandler = (request) async {
        recorded.add(request);
        return AutomationHttpResponse.ok(<String, Object?>{
          'method': request.method,
          'path': request.path,
          'query': request.queryParameters,
          'body': request.body,
        });
      };
      server = IoAutomationHttpServer();
      client = HttpClient();
      await server.start(
        port: 0,
        password: 'alpha-beta-gamma-delta',
        allowPty: false,
        onRequest: (request) => activeHandler(request),
      );
    });

    tearDown(() async {
      client.close(force: true);
      await server.stop();
    });

    test(
      'binds loopback and allows 127.0.0.1 and localhost Hosts only',
      () async {
        final port = server.boundPort!;
        expect(server.isRunning, isTrue);
        expect(port, greaterThan(0));

        final ipRes = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state?pane=p1',
          hostHeader: '127.0.0.1:$port',
          authHeader: 'Bearer alpha-beta-gamma-delta',
        );
        expect(ipRes.statusCode, equals(HttpStatus.ok));
        expect(ipRes.json['ok'], isTrue);
        expect(recorded.single.queryParameters, equals({'pane': 'p1'}));
        expect(recorded.single.body, isNull);

        final localhostRes = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          hostHeader: 'localhost:$port',
          authHeader: 'Bearer alpha-beta-gamma-delta',
        );
        expect(localhostRes.statusCode, equals(HttpStatus.ok));

        final badHostRes = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          hostHeader: 'evil.example:$port',
          authHeader: 'Bearer alpha-beta-gamma-delta',
        );
        expect(badHostRes.statusCode, equals(HttpStatus.forbidden));
        expect(badHostRes.json['ok'], isFalse);

        final wrongPortHostRes = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          hostHeader: '127.0.0.1:${port + 1}',
          authHeader: 'Bearer alpha-beta-gamma-delta',
        );
        expect(wrongPortHostRes.statusCode, equals(HttpStatus.forbidden));
      },
    );

    test(
      'rejects OPTIONS with 405 and zero Access-Control-* headers',
      () async {
        final port = server.boundPort!;
        final res = await _sendRequest(
          client,
          method: 'OPTIONS',
          port: port,
          path: '/v1/window/bounds',
        );
        expect(res.statusCode, equals(HttpStatus.methodNotAllowed));
        expect(res.json['ok'], isFalse);

        final corsHeaders = <String>[];
        res.headers.forEach((name, _) {
          if (name.toLowerCase().startsWith('access-control-')) {
            corsHeaders.add(name);
          }
        });
        expect(corsHeaders, isEmpty);
      },
    );

    test(
      'enforces Bearer token auth and instant live password rotation',
      () async {
        final port = server.boundPort!;

        final missingAuth = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
        );
        expect(missingAuth.statusCode, equals(HttpStatus.unauthorized));

        final wrongScheme = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          authHeader: 'Basic alpha-beta-gamma-delta',
        );
        expect(wrongScheme.statusCode, equals(HttpStatus.unauthorized));

        final wrongToken = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          authHeader: 'Bearer wrong-token',
        );
        expect(wrongToken.statusCode, equals(HttpStatus.unauthorized));

        server.updatePassword('rotated-token-12345');

        final staleToken = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          authHeader: 'Bearer alpha-beta-gamma-delta',
        );
        expect(staleToken.statusCode, equals(HttpStatus.unauthorized));

        final freshToken = await _sendRequest(
          client,
          method: 'GET',
          port: port,
          path: '/v1/state',
          authHeader: 'Bearer rotated-token-12345',
        );
        expect(freshToken.statusCode, equals(HttpStatus.ok));
      },
    );

    test(
      'rejects non-GET/POST methods after authentication with 405',
      () async {
        final port = server.boundPort!;
        final res = await _sendRequest(
          client,
          method: 'DELETE',
          port: port,
          path: '/v1/state',
          authHeader: 'Bearer alpha-beta-gamma-delta',
        );
        expect(res.statusCode, equals(HttpStatus.methodNotAllowed));
      },
    );

    test(
      'gates PTY paths behind allowPty and supports live toggling',
      () async {
        final port = server.boundPort!;
        const auth = 'Bearer alpha-beta-gamma-delta';

        final ptyPaths = <({String method, String path})>[
          (method: 'GET', path: '/v1/screen'),
          (method: 'POST', path: '/v1/screen/find'),
          (method: 'POST', path: '/v1/pty/write'),
          (method: 'POST', path: '/v1/tabs/spawn'),
          (method: 'POST', path: '/v1/input/mouse'),
          (method: 'GET', path: '/v1/ui/../screen'),
        ];

        for (final target in ptyPaths) {
          final res = await _sendRequest(
            client,
            method: target.method,
            port: port,
            path: target.path,
            authHeader: auth,
            contentType: target.method == 'POST' ? 'application/json' : null,
            bodyBytes: target.method == 'POST' ? utf8.encode('{}') : null,
          );
          expect(
            res.statusCode,
            equals(HttpStatus.forbidden),
            reason: '${target.method} ${target.path}',
          );
        }

        // Base pointer endpoint remains accessible while allowPty is false.
        final pointerRes = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/input/pointer',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: utf8.encode('{"x":0.5,"y":0.5}'),
        );
        expect(pointerRes.statusCode, equals(HttpStatus.ok));

        server.updateAllowPty(true);

        for (final target in ptyPaths) {
          final res = await _sendRequest(
            client,
            method: target.method,
            port: port,
            path: target.path,
            authHeader: auth,
            contentType: target.method == 'POST' ? 'application/json' : null,
            bodyBytes: target.method == 'POST' ? utf8.encode('{}') : null,
          );
          expect(
            res.statusCode,
            equals(HttpStatus.ok),
            reason: '${target.method} ${target.path} after allowPty=true',
          );
        }
      },
    );

    test(
      'enforces POST Content-Type, 256 KiB cap, UTF-8, and JSON object',
      () async {
        final port = server.boundPort!;
        const auth = 'Bearer alpha-beta-gamma-delta';

        final missingCt = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          bodyBytes: utf8.encode('{}'),
        );
        expect(missingCt.statusCode, equals(HttpStatus.unsupportedMediaType));

        final wrongCt = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'text/plain',
          bodyBytes: utf8.encode('{}'),
        );
        expect(wrongCt.statusCode, equals(HttpStatus.unsupportedMediaType));

        final invalidUtf8 = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: const <int>[0x7B, 0xFF, 0xFE, 0x7D],
        );
        expect(invalidUtf8.statusCode, equals(HttpStatus.badRequest));

        final badJson = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json; charset=utf-8',
          bodyBytes: utf8.encode('{not json'),
        );
        expect(badJson.statusCode, equals(HttpStatus.badRequest));

        final nonObjectJson = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: utf8.encode('[1, 2, 3]'),
        );
        expect(nonObjectJson.statusCode, equals(HttpStatus.badRequest));

        final oversized = List<int>.filled(
          IoAutomationHttpServer.maxBodyBytes + 1,
          0x20,
        );
        final tooLargeFixed = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: oversized,
        );
        expect(
          tooLargeFixed.statusCode,
          equals(HttpStatus.requestEntityTooLarge),
        );

        final tooLargeChunked = await _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: oversized,
          chunked: true,
        );
        expect(
          tooLargeChunked.statusCode,
          equals(HttpStatus.requestEntityTooLarge),
        );
      },
    );

    test(
      'serializes concurrent POST requests FIFO and survives handler errors',
      () async {
        final port = server.boundPort!;
        const auth = 'Bearer alpha-beta-gamma-delta';
        final events = <String>[];
        final firstGate = Completer<void>();
        final firstEntered = Completer<void>();

        activeHandler = (request) async {
          final id = request.body?['id'];
          events.add('start:$id');
          if (id == 1) {
            firstEntered.complete();
            await firstGate.future;
          }
          if (id == 2) {
            events.add('throw:$id');
            throw StateError('boom');
          }
          events.add('end:$id');
          return AutomationHttpResponse.ok(<String, Object?>{'id': id});
        };

        final f1 = _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: utf8.encode('{"id":1}'),
        );
        await firstEntered.future;

        final f2 = _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: utf8.encode('{"id":2}'),
        );
        // Let f2 reach the server queue before sending f3.
        await Future<void>.delayed(const Duration(milliseconds: 25));

        final f3 = _sendRequest(
          client,
          method: 'POST',
          port: port,
          path: '/v1/ui',
          authHeader: auth,
          contentType: 'application/json',
          bodyBytes: utf8.encode('{"id":3}'),
        );
        await Future<void>.delayed(const Duration(milliseconds: 25));

        // Neither 2 nor 3 may start while 1 is still in flight.
        expect(events, equals(['start:1']));
        firstGate.complete();

        final results = await Future.wait<_HttpResult>([f1, f2, f3]);
        expect(results[0].statusCode, equals(HttpStatus.ok));
        expect(results[1].statusCode, equals(HttpStatus.internalServerError));
        expect(results[2].statusCode, equals(HttpStatus.ok));
        expect(
          events,
          equals([
            'start:1',
            'end:1',
            'start:2',
            'throw:2',
            'start:3',
            'end:3',
          ]),
        );
      },
    );
  });

  group('AutomationDriverController', () {
    test('stays completely inert on unsupported (Web) backends', () async {
      final storage = _MemorySettingsStorage();
      final controller = AutomationDriverController(
        onRequest: (_) async => AutomationHttpResponse.ok(<String, Object?>{}),
        storage: storage,
        backend: const StubAutomationHttpServer(),
      );
      addTearDown(controller.dispose);

      expect(controller.isSupported, isFalse);
      expect(controller.isRunning, isFalse);
      expect(controller.password, isEmpty);
      expect(storage.getCount, equals(0));
      expect(storage.setCount, equals(0));

      expect(
        await controller.applyStartupFlags(
          enabled: true,
          allowPty: true,
          portOverride: 9922,
          tokenOverride: 'override-tok',
        ),
        isFalse,
      );
      expect(await controller.setEnabled(true), isFalse);
      controller.setPort(9933);
      controller.setAllowPty(true);
      expect(controller.regeneratePassword(), isEmpty);
      expect(storage.getCount, equals(0));
      expect(storage.setCount, equals(0));
      expect(controller.allowPty, isFalse);
    });

    test('persists generated password on first load and respects overrides', () async {
      final storage = _MemorySettingsStorage();
      final backend = IoAutomationHttpServer();
      final controller = AutomationDriverController(
        onRequest: (_) async => AutomationHttpResponse.ok(<String, Object?>{}),
        storage: storage,
        backend: backend,
        random: Random(42),
      );
      addTearDown(() async {
        await controller.setEnabled(false);
        controller.dispose();
      });

      expect(controller.isSupported, isTrue);
      expect(controller.isRunning, isFalse);
      expect(controller.allowPty, isFalse);
      expect(controller.port, equals(AutomationDriverConfig.defaultPort));
      expect(controller.password, isNotEmpty);

      final initialStored = storage.values[ftermAutomationConfigStorageKey];
      expect(initialStored, isNotNull);
      final persistedPassword = controller.password;

      // Apply ephemeral overrides without overwriting persisted storage.
      final probeSocket = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        0,
      );
      final freePort = probeSocket.port;
      await probeSocket.close(force: true);

      final started = await controller.applyStartupFlags(
        enabled: true,
        allowPty: true,
        portOverride: freePort,
        tokenOverride: 'ephemeral-secret',
      );
      expect(started, isTrue);
      expect(controller.isRunning, isTrue);
      expect(controller.port, equals(freePort));
      expect(controller.boundPort, equals(freePort));
      expect(controller.password, equals('ephemeral-secret'));
      expect(controller.hasEphemeralTokenOverride, isTrue);
      expect(controller.allowPty, isTrue);
      expect(
        storage.values[ftermAutomationConfigStorageKey],
        equals(initialStored),
      );

      // Live regeneratePassword rotates active token and persists new password.
      final rotated = controller.regeneratePassword();
      expect(rotated, isNot(equals(persistedPassword)));
      expect(controller.password, equals(rotated));
      expect(controller.hasEphemeralTokenOverride, isFalse);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final oldAuth = await _sendRequest(
        client,
        method: 'GET',
        port: freePort,
        path: '/v1/screen',
        authHeader: 'Bearer ephemeral-secret',
      );
      expect(oldAuth.statusCode, equals(HttpStatus.unauthorized));

      final newAuth = await _sendRequest(
        client,
        method: 'GET',
        port: freePort,
        path: '/v1/screen',
        authHeader: 'Bearer $rotated',
      );
      expect(newAuth.statusCode, equals(HttpStatus.ok));

      // Live setAllowPty updates running server immediately.
      controller.setAllowPty(false);
      final gatedRes = await _sendRequest(
        client,
        method: 'GET',
        port: freePort,
        path: '/v1/screen',
        authHeader: 'Bearer $rotated',
      );
      expect(gatedRes.statusCode, equals(HttpStatus.forbidden));

      // setPort is ignored while running, persisted once stopped.
      controller.setPort(9955);
      expect(controller.port, equals(freePort));

      await controller.setEnabled(false);
      expect(controller.isRunning, isFalse);
      controller.setPort(9955);
      expect(controller.port, equals(9955));
      final reloaded = AutomationDriverConfig.tryFromJsonString(
        storage.values[ftermAutomationConfigStorageKey],
      );
      expect(reloaded?.port, equals(9955));
      expect(reloaded?.password, equals(rotated));
    });

    test(
      'surfaces SocketException bind failure in lastError cleanly',
      () async {
        final blocker = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => blocker.close(force: true));

        final storage = _MemorySettingsStorage();
        final controller = AutomationDriverController(
          onRequest: (_) async =>
              AutomationHttpResponse.ok(<String, Object?>{}),
          storage: storage,
          backend: IoAutomationHttpServer(),
        );
        addTearDown(controller.dispose);

        controller.setPort(blocker.port);
        final started = await controller.setEnabled(true);
        expect(started, isFalse);
        expect(controller.isRunning, isFalse);
        expect(controller.lastError, isNotNull);
        expect(controller.lastError, contains('${blocker.port}'));
      },
    );

    test('reloads persisted port and password on fresh controller startup', () {
      final storage = _MemorySettingsStorage();
      storage.values[ftermAutomationConfigStorageKey] = AutomationDriverConfig(
        port: 9944,
        password: 'saved-token-value-1234',
      ).toJsonString();

      final controller = AutomationDriverController(
        onRequest: (_) async => AutomationHttpResponse.ok(<String, Object?>{}),
        storage: storage,
        backend: IoAutomationHttpServer(),
      );
      addTearDown(controller.dispose);

      expect(controller.port, equals(9944));
      expect(controller.password, equals('saved-token-value-1234'));
      expect(controller.isRunning, isFalse);
      expect(controller.allowPty, isFalse);
      expect(storage.setCount, equals(0));
    });
  });

  group('automation_screen_search', () {
    tui.Buffer buildBuffer(int cols, int rows, List<List<String>> grid) {
      final buffer = tui.Buffer.blank(cols, rows);
      for (var r = 0; r < grid.length; r++) {
        final rowCells = grid[r];
        for (var c = 0; c < rowCells.length; c++) {
          buffer.characters[r * cols + c] = rowCells[c];
        }
      }
      return buffer;
    }

    test('extractScreenSnapshot omits continuation cells and trims right', () {
      final buffer = buildBuffer(10, 2, <List<String>>[
        <String>['中', '', '🚀', '', 'H', 'i', ' ', ' ', ' ', ' '],
        <String>[' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' ', ' '],
      ]);

      final snapshot = extractScreenSnapshot(
        buffer,
        paneId: 'pane-1',
        cursorCol: 6,
        cursorRow: 0,
        cursorVisible: true,
      );

      expect(snapshot.paneId, equals('pane-1'));
      expect(snapshot.cols, equals(10));
      expect(snapshot.rows, equals(2));
      expect(snapshot.cursorCol, equals(6));
      expect(snapshot.cursorRow, equals(0));
      expect(snapshot.cursorVisible, isTrue);
      expect(snapshot.lines, equals(['中🚀Hi', '']));
    });

    test(
      'findInScreenBuffer computes exact columns across wide CJK & emoji',
      () {
        final buffer = buildBuffer(10, 4, <List<String>>[
          <String>['中', '', '🚀', '', 'O', 'K', ' ', ' ', ' ', ' '],
          <String>['A', 'B', '文', '', '字', '', 'Z', ' ', ' ', ' '],
          <String>['h', 'e', 'l', 'l', 'o', ' ', 'H', 'E', 'L', 'L'],
        ]);

        // Match after wide CJK + surrogate-pair emoji keeps exact 0-based col 4..6.
        final okMatches = findInScreenBuffer(buffer, text: 'OK');
        expect(okMatches, hasLength(1));
        expect(okMatches.single.row, equals(0));
        expect(okMatches.single.col, equals(4));
        expect(okMatches.single.endCol, equals(6));
        expect(okMatches.single.text, equals('OK'));
        expect(okMatches.single.x, closeTo((4 + 6) / 20.0, 1e-9));
        expect(okMatches.single.y, closeTo(0.5 / 4.0, 1e-9));

        // Match ending on a wide glyph advances endCol past continuation cell.
        final wideEndMatches = findInScreenBuffer(buffer, text: '中🚀');
        expect(wideEndMatches, hasLength(1));
        expect(wideEndMatches.single.col, equals(0));
        expect(wideEndMatches.single.endCol, equals(4));
        expect(wideEndMatches.single.x, closeTo(4 / 20.0, 1e-9));

        // Single emoji (UTF-16 length 2) maps to col 2..4.
        final emojiMatches = findInScreenBuffer(buffer, text: '🚀');
        expect(emojiMatches, hasLength(1));
        expect(emojiMatches.single.col, equals(2));
        expect(emojiMatches.single.endCol, equals(4));
        expect(emojiMatches.single.x, closeTo(6 / 20.0, 1e-9));

        // Regex matching across CJK glyphs spans full rendered cell width.
        final regexMatches = findInScreenBuffer(buffer, regex: r'B文字');
        expect(regexMatches, hasLength(1));
        expect(regexMatches.single.row, equals(1));
        expect(regexMatches.single.col, equals(1));
        expect(regexMatches.single.endCol, equals(6));
        expect(regexMatches.single.x, closeTo(7 / 20.0, 1e-9));
        expect(regexMatches.single.y, closeTo(1.5 / 4.0, 1e-9));

        // Case-insensitive literal search finds both occurrences on row 2.
        final ciMatches = findInScreenBuffer(
          buffer,
          text: 'hell',
          caseSensitive: false,
        );
        expect(ciMatches, hasLength(2));
        expect(ciMatches[0].col, equals(0));
        expect(ciMatches[0].endCol, equals(4));
        expect(ciMatches[1].col, equals(6));
        expect(ciMatches[1].endCol, equals(10));
      },
    );

    test('findInScreenBuffer validates arguments and regex syntax', () {
      final buffer = tui.Buffer.blank(8, 2);
      expect(() => findInScreenBuffer(buffer), throwsFormatException);
      expect(
        () => findInScreenBuffer(buffer, text: 'a', regex: 'b'),
        throwsFormatException,
      );
      expect(() => findInScreenBuffer(buffer, text: ''), throwsFormatException);
      expect(
        () => findInScreenBuffer(buffer, regex: ''),
        throwsFormatException,
      );
      expect(
        () => findInScreenBuffer(buffer, regex: '[unclosed'),
        throwsFormatException,
      );
    });
  });
}
