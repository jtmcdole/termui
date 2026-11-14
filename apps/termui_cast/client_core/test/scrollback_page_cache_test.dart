import 'dart:typed_data';

import 'package:checks/checks.dart';
import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:termui_cast_client_core/src/scrollback_page_cache.dart';
import 'package:termui_cast_protocol/termui_cast_protocol.dart';
import 'package:test/test.dart';

EncodedScrollbackRow _row(String text, {bool isWrapped = false}) {
  final chars = text.split('');
  return EncodedScrollbackRow(
    isWrapped: isWrapped,
    characters: chars,
    attributes: Uint32List(chars.length * 3),
  );
}

void main() {
  const sessionId = SessionId('sess-cache');

  group('ScrollbackPageCache', () {
    test(
      'caches rows, coalesces gaps, respects maxInFlight=2, and evicts oldest pages beyond 2048 rows',
      () {
        final cache = ScrollbackPageCache()
          ..updateWindow(
            const ScrollbackWindow(
              clearSeq: 0,
              oldestLine: 0,
              totalLines: 2500,
            ),
          );

        // Request 0..200 -> split into 2 max-128 requests (0..128 and 128..200), hitting maxInFlight=2.
        final reqs = cache.planRequests(
          sessionId: sessionId,
          startLine: 0,
          endLine: 200,
        );
        check(reqs).length.equals(2);
        check(reqs[0].startLine).equals(0);
        check(reqs[0].count).equals(128);
        check(reqs[1].startLine).equals(128);
        check(reqs[1].count).equals(72);

        // Third request while 2 are in-flight returns empty.
        check(
          cache.planRequests(
            sessionId: sessionId,
            startLine: 500,
            endLine: 600,
          ),
        ).isEmpty();

        // Ingest first chunk -> frees 1 in-flight slot.
        check(
          cache.ingestChunk(
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: reqs[0].requestId,
              clearSeq: 0,
              startLine: 0,
              rows: [for (var i = 0; i < 128; i++) _row('L$i')],
            ),
          ),
        ).isTrue();
        check(cache.rowAt(0)!.characters).deepEquals(['L', '0']);
        check(cache.rowAt(127)!.characters).deepEquals(['L', '1', '2', '7']);

        // Plan 0..250 -> skips cached 0..128 and in-flight 128..200, requesting ONLY 200..250!
        final gapReqs = cache.planRequests(
          sessionId: sessionId,
          startLine: 0,
          endLine: 250,
        );
        check(gapReqs).length.equals(1);
        check(gapReqs.single.startLine).equals(200);
        check(gapReqs.single.count).equals(50);

        // Pump 17 full 128-row pages (2176 rows > 2048 maxCachedRows) -> oldest page (0..127) is evicted.
        for (var page = 1; page <= 17; page++) {
          final start = page * 128;
          cache.ingestChunk(
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: 9000 + page,
              clearSeq: 0,
              startLine: start,
              rows: [for (var i = 0; i < 128; i++) _row('P$page-$i')],
            ),
          );
        }
        check(cache.rowAt(0)).isNull();
        check(cache.rowAt(17 * 128)).isNotNull();
      },
    );

    test(
      'invalidates on clearSeq bump, drops stale chunks, and reclaims stalled in-flight slots on clearInFlight or timeout',
      () {
        fakeAsync((async) {
          final cache = ScrollbackPageCache(clock: clock)
            ..updateWindow(
              const ScrollbackWindow(
                clearSeq: 1,
                oldestLine: 0,
                totalLines: 300,
              ),
            );

          final reqs = cache.planRequests(
            sessionId: sessionId,
            startLine: 0,
            endLine: 256,
          );
          check(reqs).length.equals(2);

          // Advance 2 seconds -> stalled in-flight slots expire automatically!
          async.elapse(ScrollbackPageCache.requestTimeout);
          final retryReqs = cache.planRequests(
            sessionId: sessionId,
            startLine: 0,
            endLine: 64,
          );
          check(retryReqs).length.equals(1);
          check(retryReqs.single.startLine).equals(0);

          // clearInFlight() immediately frees slots (used on BufferSnapshotFrame reconnect).
          cache.clearInFlight();
          final afterClearReqs = cache.planRequests(
            sessionId: sessionId,
            startLine: 64,
            endLine: 128,
          );
          check(afterClearReqs).length.equals(1);

          // Bump clearSeq 1 -> 2: clears cache & in-flight, and rejects old clearSeq=1 chunks.
          check(
            cache.updateWindow(
              const ScrollbackWindow(
                clearSeq: 2,
                oldestLine: 0,
                totalLines: 50,
              ),
            ),
          ).isTrue();
          check(
            cache.ingestChunk(
              ScrollbackChunkFrame(
                sessionId: sessionId,
                requestId: afterClearReqs.single.requestId,
                clearSeq: 1,
                startLine: 64,
                rows: [_row('stale')],
              ),
            ),
          ).isFalse();
          check(cache.rowAt(64)).isNull();
        });
      },
    );

    test(
      'advances oldestLine on non-empty clamped ScrollbackChunkFrame without refetch spin loop and invalidates on window regression',
      () {
        final cache = ScrollbackPageCache()
          ..updateWindow(
            const ScrollbackWindow(clearSeq: 0, oldestLine: 0, totalLines: 500),
          );

        // Viewer requests 0..128 before learning caster ring evicted 0..49.
        final reqs = cache.planRequests(
          sessionId: sessionId,
          startLine: 0,
          endLine: 128,
        );
        check(reqs).length.equals(1);
        check(reqs.single.startLine).equals(0);

        // Caster replies with clamped non-empty chunk starting at 50 (rows 50..177).
        check(
          cache.ingestChunk(
            ScrollbackChunkFrame(
              sessionId: sessionId,
              requestId: reqs.single.requestId,
              clearSeq: 0,
              startLine: 50,
              rows: [for (var i = 50; i < 178; i++) _row('R$i')],
            ),
          ),
        ).isTrue();
        check(cache.oldestLine).equals(50);
        check(cache.rowAt(49)).isNull();
        check(cache.rowAt(50)!.characters).deepEquals(['R', '5', '0']);

        // Planning 0..128 again must emit 0 requests because 0..50 was evicted and 50..177 is cached!
        check(
          cache.planRequests(sessionId: sessionId, startLine: 0, endLine: 128),
        ).isEmpty();

        // Caster restart with clearSeq == 0 and smaller totalLines invalidates ghost pages.
        check(
          cache.updateWindow(
            const ScrollbackWindow(clearSeq: 0, oldestLine: 0, totalLines: 60),
          ),
        ).isTrue();
        check(cache.oldestLine).equals(0);
        check(cache.totalLines).equals(60);
        check(cache.rowAt(50)).isNull();
      },
    );
  });
}
