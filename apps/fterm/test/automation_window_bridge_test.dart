import 'package:flutter/services.dart'
    show MethodCall, MethodChannel, PlatformException, StandardMethodCodec;
import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/automation/window_channel_bridge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannelWindowBridge.defaultChannel;

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    channel.setMethodCallHandler(null);
  });

  group('MethodChannelWindowBridge', () {
    test(
      'getBounds invokes getBounds and parses full native snapshot',
      () async {
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              calls.add(call);
              return <String, Object?>{
                'supported': true,
                'physical': <String, Object?>{
                  'x': 0.0,
                  'y': 0.0,
                  'width': 1920.0,
                  'height': 1080.0,
                },
                'logical': <String, Object?>{
                  'x': 0.0,
                  'y': 0.0,
                  'width': 1280.0,
                  'height': 720.0,
                },
                'dpr': 1.5,
                'alwaysOnTop': true,
                'squareCorners': true,
              };
            });

        const bridge = MethodChannelWindowBridge();
        final snapshot = await bridge.getBounds();

        expect(calls, hasLength(1));
        expect(calls.single.method, equals('getBounds'));
        expect(calls.single.arguments, isNull);
        expect(
          snapshot,
          equals(
            const WindowBoundsSnapshot(
              supported: true,
              physical: WindowBoundsRect(x: 0, y: 0, width: 1920, height: 1080),
              logical: WindowBoundsRect(x: 0, y: 0, width: 1280, height: 720),
              dpr: 1.5,
              alwaysOnTop: true,
              squareCorners: true,
            ),
          ),
        );
      },
    );

    test('setBounds encodes all fields and parses returned snapshot', () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return <String, Object?>{
              'supported': true,
              'physical': <String, Object?>{
                'x': 100.0,
                'y': 200.0,
                'width': 1920.0,
                'height': 1080.0,
              },
              'logical': <String, Object?>{
                'x': 50.0,
                'y': 100.0,
                'width': 960.0,
                'height': 540.0,
              },
              'dpr': 2.0,
              'alwaysOnTop': true,
              'squareCorners': true,
            };
          });

      const bridge = MethodChannelWindowBridge();
      const request = WindowBoundsRequest(
        x: 50,
        y: 100,
        width: 960,
        height: 540,
        units: .logical,
        squareCorners: true,
        alwaysOnTop: true,
        focus: true,
      );

      final snapshot = await bridge.setBounds(request);

      expect(calls, hasLength(1));
      expect(calls.single.method, equals('setBounds'));
      expect(
        calls.single.arguments,
        equals(<String, Object?>{
          'x': 50.0,
          'y': 100.0,
          'width': 960.0,
          'height': 540.0,
          'units': 'logical',
          'squareCorners': true,
          'alwaysOnTop': true,
          'focus': true,
        }),
      );
      expect(snapshot.supported, isTrue);
      expect(
        snapshot.physical,
        equals(
          const WindowBoundsRect(x: 100, y: 200, width: 1920, height: 1080),
        ),
      );
      expect(
        snapshot.logical,
        equals(const WindowBoundsRect(x: 50, y: 100, width: 960, height: 540)),
      );
      expect(snapshot.dpr, equals(2.0));
      expect(snapshot.alwaysOnTop, isTrue);
      expect(snapshot.squareCorners, isTrue);
    });

    test(
      'setBounds omits unset optional fields with default physical units',
      () async {
        Object? capturedArgs;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              capturedArgs = call.arguments;
              return <String, Object?>{
                'supported': true,
                'physical': <String, Object?>{
                  'x': 0,
                  'y': 0,
                  'width': 1280,
                  'height': 720,
                },
              };
            });

        const bridge = MethodChannelWindowBridge();
        final snapshot = await bridge.setBounds(
          const WindowBoundsRequest(width: 1280, height: 720),
        );

        expect(
          capturedArgs,
          equals(<String, Object?>{
            'width': 1280.0,
            'height': 720.0,
            'units': 'physical',
          }),
        );
        expect(snapshot.supported, isTrue);
        expect(snapshot.dpr, equals(1.0));
        expect(snapshot.alwaysOnTop, isFalse);
        expect(snapshot.squareCorners, isFalse);
      },
    );

    test('returns unsupported when MissingPluginException is thrown', () async {
      // No mock handler registered simulates macOS/Linux/Web missing method.
      const bridge = MethodChannelWindowBridge();

      expect(
        await bridge.getBounds(),
        equals(WindowBoundsSnapshot.unsupported),
      );
      expect(
        await bridge.setBounds(const WindowBoundsRequest(x: 0, y: 0)),
        equals(WindowBoundsSnapshot.unsupported),
      );
    });

    test('returns unsupported when PlatformException is thrown', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(
              code: 'INVALID_ARGUMENTS',
              message: 'Native runner rejected request.',
            );
          });

      const bridge = MethodChannelWindowBridge();

      expect(
        await bridge.getBounds(),
        equals(WindowBoundsSnapshot.unsupported),
      );
      expect(
        await bridge.setBounds(const WindowBoundsRequest(focus: true)),
        equals(WindowBoundsSnapshot.unsupported),
      );
    });

    test(
      'returns unsupported when native response is null or malformed',
      () async {
        final responses = <Map<String, Object?>?>[
          null,
          <String, Object?>{'supported': false},
          <String, Object?>{'supported': true},
          <String, Object?>{
            'supported': true,
            'physical': <String, Object?>{
              'x': 0,
              'y': 0,
              'width': -10,
              'height': 10,
            },
          },
        ];

        var index = 0;
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(
              channel,
              (call) async => responses[index++],
            );

        const bridge = MethodChannelWindowBridge();
        for (var i = 0; i < responses.length; i++) {
          expect(
            await bridge.getBounds(),
            equals(WindowBoundsSnapshot.unsupported),
            reason: 'response #$i',
          );
        }
      },
    );

    test(
      'does not clobber existing incoming method call handler on fterm/window',
      () async {
        final incomingCalls = <MethodCall>[];
        channel.setMethodCallHandler((call) async {
          incomingCalls.add(call);
          return null;
        });
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              return <String, Object?>{
                'supported': true,
                'physical': <String, Object?>{
                  'x': 0,
                  'y': 0,
                  'width': 800,
                  'height': 600,
                },
              };
            });

        const bridge = MethodChannelWindowBridge();
        await bridge.getBounds();
        await bridge.setBounds(const WindowBoundsRequest(squareCorners: true));

        const codec = StandardMethodCodec();
        final encoded = codec.encodeMethodCall(
          const MethodCall('windowSizeMoveChanged', true),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(channel.name, encoded, (_) {});

        expect(incomingCalls, hasLength(1));
        expect(incomingCalls.single.method, equals('windowSizeMoveChanged'));
        expect(incomingCalls.single.arguments, isTrue);
      },
    );

    test('supports custom MethodChannel injection', () async {
      const customChannel = MethodChannel('fterm/window_custom_test');
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(customChannel, null);
      });

      var called = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(customChannel, (call) async {
            called = true;
            return <String, Object?>{
              'supported': true,
              'physical': <String, Object?>{
                'x': 10,
                'y': 20,
                'width': 640,
                'height': 480,
              },
            };
          });

      const bridge = MethodChannelWindowBridge(channel: customChannel);
      final snapshot = await bridge.getBounds();

      expect(called, isTrue);
      expect(
        snapshot.physical,
        equals(const WindowBoundsRect(x: 10, y: 20, width: 640, height: 480)),
      );
    });
  });
}
