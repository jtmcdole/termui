import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:termui/termui.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

void main() {
  const sessionId = SessionId('shader-sess');

  group('shaderFrames capability negotiation', () {
    test(
      'omits capability byte when false for backwards compatibility and encodes when true',
      () {
        final legacyAuth = BufferFrameCodec.encode(
          const AuthAcceptedFrame(role: .caster),
        );
        check(legacyAuth.length).equals(3);
        final decodedLegacyAuth =
            BufferFrameCodec.decode(legacyAuth) as AuthAcceptedFrame;
        check(decodedLegacyAuth.shaderFrames).isFalse();

        final modernAuth = BufferFrameCodec.encode(
          const AuthAcceptedFrame(role: .caster, shaderFrames: true),
        );
        check(modernAuth.length).equals(4);
        final decodedModernAuth =
            BufferFrameCodec.decode(modernAuth) as AuthAcceptedFrame;
        check(decodedModernAuth.shaderFrames).isTrue();

        final legacySub = BufferFrameCodec.encode(
          const SubscribeSessionFrame(sessionId: sessionId, cols: 80, rows: 24),
        );
        final modernSub = BufferFrameCodec.encode(
          const SubscribeSessionFrame(
            sessionId: sessionId,
            cols: 80,
            rows: 24,
            shaderFrames: true,
          ),
        );
        check(modernSub.length).equals(legacySub.length + 1);
        check(
          (BufferFrameCodec.decode(legacySub) as SubscribeSessionFrame)
              .shaderFrames,
        ).isFalse();
        check(
          (BufferFrameCodec.decode(modernSub) as SubscribeSessionFrame)
              .shaderFrames,
        ).isTrue();
      },
    );

    test('rejects unknown capability flag bits', () {
      final tampered = Uint8List.fromList([
        BufferFrameCodec.protocolVersion,
        0x02,
        0,
        0x80,
      ]);
      check(
        () => BufferFrameCodec.decode(tampered),
      ).throws<ProtocolFormatException>();
    });
  });

  group('0x1C ShaderFrame codec & relay inspection', () {
    test(
      'round-trips every CastShaderPayload subtype and passes inspectRelayShaderFrame',
      () {
        final payloads = <CastShaderPayload>[
          const CastDefineShaderPayload(
            id: 'fire_custom',
            glslSource: 'void mainImage(out vec4 c, in vec2 u){c=vec4(1.0);}',
            persist: true,
          ),
          CastRegionShaderPayload(
            id: 'r1',
            region: ShaderRegion(
              id: 'r1',
              shaderId: 'fire_custom',
              sourceRects: const [Rect(10, 4, 4, 1), Rect(0, 5, 6, 1)],
              padding: const CellPadding(top: 2, right: 1, bottom: 0, left: 1),
              stage: ShaderRegionStage.overGlyphs,
              zIndex: 3,
              persist: true,
              params: Float32List.fromList([1.2, 0, 0, -2.5, 0, 0, 0, 0]),
            ),
          ),
          const CastRegionShaderPayload(id: 'r1', remove: true),
          CastTransformsShaderPayload(
            replace: true,
            entries: [
              (
                col: 4,
                row: 2,
                transform: const CellTransform(
                  dx: 0.5,
                  dy: -1.0,
                  scaleX: 1.5,
                  scaleY: 0.75,
                  rotationRad: 1.25,
                  alpha: 0.75,
                  zLayer: 2,
                  tween: CellTween(
                    animationId: 9,
                    endDx: 3.0,
                    endDy: 8.0,
                    endRotationRad: 3.25,
                    endAlpha: 0.0,
                    durationSec: 0.5,
                    easing: CellTweenEasing.easeOut,
                    fromCurrent: true,
                    clearOnFinish: true,
                  ),
                ),
              ),
              (col: 5, row: 2, transform: null),
            ],
          ),
          CastSetShaderPayload(
            stage: 'post',
            presetId: 'crt_lottes',
            params: Float32List.fromList([0.4, 0, 0, 0, 0, 0, 0, 0]),
          ),
          CastSetShaderPayload(stage: 'post', clear: true),
          CastUniformShaderPayload(
            id: 'r1',
            paramMask: 0x05,
            params: Float32List.fromList([1.5, 0, -0.75, 0, 0, 0, 0, 0]),
          ),
          const CastResetShaderPayload(target: 'regions'),
        ];

        for (final payload in payloads) {
          final frame = ShaderFrame(sessionId: sessionId, payload: payload);
          final wire = BufferFrameCodec.encode(frame);
          check(wire[1]).equals(0x1C);
          check(
            wire.length,
          ).isLessOrEqual(BufferFrameCodec.maxShaderFrameBytes);
          check(
            BufferFrameCodec.inspectRelayShaderFrame(
              wire,
              expectedSession: sessionId,
            ),
          ).isTrue();
          check(
            BufferFrameCodec.inspectRelayShaderFrame(
              wire,
              expectedSession: const SessionId('other'),
            ),
          ).isFalse();

          final decoded = BufferFrameCodec.decode(wire) as ShaderFrame;
          check(decoded.sessionId).equals(sessionId);
          check(decoded.payload).equals(payload);
        }
      },
    );

    test('enforces <= 32 KiB GLSL and <= 64 KiB frame cap', () {
      check(
        () => BufferFrameCodec.encode(
          ShaderFrame(
            sessionId: sessionId,
            payload: CastDefineShaderPayload(
              id: 'too_big',
              glslSource: 'a' * (32 * 1024 + 1),
            ),
          ),
        ),
      ).throws<ProtocolFormatException>();

      final hugeBatch = List<CellTransformEntry>.generate(
        1100,
        (i) => (
          col: i % 80,
          row: i ~/ 80,
          transform: const CellTransform(dx: 1.0),
        ),
      );
      check(
        () => BufferFrameCodec.encode(
          ShaderFrame(
            sessionId: sessionId,
            payload: CastTransformsShaderPayload(entries: hugeBatch),
          ),
        ),
      ).throws<ProtocolFormatException>();
    });
  });
}
