import 'dart:convert';
import 'package:termui/terminal/event.dart' as ev;
import 'package:termui/termui.dart';
import 'package:termui_pty/termui_pty.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  group('Synchronized Output (?2026)', () {
    test(
      'defers notifications while ?2026h is active and flushes once on ?2026l',
      () {
        final vt = VirtualTerminal(width: 20, height: 5);
        var notifications = 0;
        vt.addListener(() => notifications++);

        vt.writeString('\x1b[?2026h');
        expect(vt.synchronizedOutput, isTrue);
        expect(notifications, 0);

        vt.writeString('Hello ');
        vt.writeString('World!\n');
        vt.writeString('Next line');
        expect(
          notifications,
          0,
          reason: 'Notifications should be held during sync mode',
        );

        vt.writeString('\x1b[?2026l');
        expect(vt.synchronizedOutput, isFalse);
        expect(notifications, 1, reason: 'Single flush must occur upon ?2026l');
      },
    );

    test(
      'does not flush notification on ?2026l if no updates occurred in batch',
      () {
        final vt = VirtualTerminal(width: 20, height: 5);
        var notifications = 0;
        vt.addListener(() => notifications++);

        vt.writeString('\x1b[?2026h\x1b[?2026l');
        expect(vt.synchronizedOutput, isFalse);
        expect(notifications, 0);
      },
    );

    test(
      'flushes single notification for combined sequence ?2026h<data>?2026l',
      () {
        final vt = VirtualTerminal(width: 20, height: 5);
        var notifications = 0;
        vt.addListener(() => notifications++);

        vt.writeString('\x1b[?2026hBatch Update\x1b[?2026l');
        expect(vt.synchronizedOutput, isFalse);
        expect(notifications, 1);
      },
    );

    test('R5a: pre-sync output before empty ?2026h?2026l notifies once', () {
      final vt = VirtualTerminal(width: 20, height: 5);
      var notifications = 0;
      var lastRow0 = '';
      vt.addListener(() {
        notifications++;
        lastRow0 = vt.buffer.getCharacter(0, 0);
      });

      vt.writeString('X\x1b[?2026h\x1b[?2026l');
      expect(notifications, equals(1));
      expect(lastRow0, equals('X'));
    });

    test(
      'R5b: trailing output after ?2026l in same write notifies with final state AB',
      () {
        final vt = VirtualTerminal(width: 20, height: 5);
        var lastObserved = '';
        vt.addListener(() {
          lastObserved =
              '${vt.buffer.getCharacter(0, 0)}${vt.buffer.getCharacter(1, 0)}';
        });

        vt.writeString('\x1b[?2026hA\x1b[?2026lB');
        expect(lastObserved, equals('AB'));
      },
    );

    test('DECSTR flushes pending updates and clears synchronizedOutput', () {
      final vt = VirtualTerminal(width: 20, height: 5);
      var notifications = 0;
      vt.addListener(() => notifications++);

      vt.writeString('\x1b[?2026h');
      vt.writeString('Pending text');
      expect(notifications, 0);

      vt.writeString('\x1b[!p');
      expect(vt.synchronizedOutput, isFalse);
      expect(notifications, 1);
    });

    test(
      'RIS (ESC c) flushes pending updates and resets synchronizedOutput',
      () {
        final vt = VirtualTerminal(width: 20, height: 5);
        var notifications = 0;
        vt.addListener(() => notifications++);

        vt.writeString('\x1b[?2026h');
        vt.writeString('Pending text');
        expect(notifications, 0);

        vt.writeString('\x1bc');
        expect(vt.synchronizedOutput, isFalse);
        expect(notifications, 1);
      },
    );

    test('reset() resets synchronizedOutput and dispatches once', () {
      final vt = VirtualTerminal(width: 20, height: 5);
      var notifications = 0;
      vt.addListener(() => notifications++);

      vt.writeString('\x1b[?2026h');
      vt.writeString('Pending text');
      expect(notifications, 0);

      vt.reset();
      expect(vt.synchronizedOutput, isFalse);
      expect(notifications, 1);
    });

    test(
      'safety timeout flushes pending notifications if ?2026h remains unclosed',
      () async {
        final vt = VirtualTerminal(width: 20, height: 5);
        var notifications = 0;
        vt.addListener(() => notifications++);

        vt.writeString('\x1b[?2026h');
        vt.writeString('Unclosed batch');
        expect(notifications, 0);

        await Future<void>.delayed(const Duration(milliseconds: 140));

        expect(vt.synchronizedOutput, isFalse);
        expect(notifications, 1);
        vt.dispose();
      },
    );

    test(r'reports synchronized output status via DECRQM (?2026$p)', () {
      final replies = <String>[];
      final vt = VirtualTerminal(width: 20, height: 5, onReply: replies.add);

      vt.writeString('\x1b[?2026\$p');
      expect(replies.last, '\x1b[?2026;2\$y');

      vt.writeString('\x1b[?2026h');
      vt.writeString('\x1b[?2026\$p');
      expect(replies.last, '\x1b[?2026;1\$y');

      vt.writeString('\x1b[?2026l');
      vt.writeString('\x1b[?2026\$p');
      expect(replies.last, '\x1b[?2026;2\$y');
      vt.dispose();
    });
  });

  group('Extended Queries (XTVERSION, OSC 10/11)', () {
    test('XTVERSION responds to CSI > 0 q and CSI > q', () {
      final replies = <String>[];
      final vt = VirtualTerminal(width: 20, height: 5, onReply: replies.add);

      vt.writeString('\x1b[>0q');
      expect(replies, ['\x1bP>|termui(0.8.3)\x1b\\']);

      replies.clear();
      vt.writeString('\x1b[>q');
      expect(replies, ['\x1bP>|termui(0.8.3)\x1b\\']);

      replies.clear();
      vt.writeString('\x1b[>1q');
      expect(replies, isEmpty);
      vt.dispose();
    });

    test(
      'OSC 10;? queries default and custom foreground color in 16-bit hex',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 20, height: 5, onReply: replies.add);

        vt.writeString('\x1b]10;?\x1b\\');
        expect(replies, ['\x1b]10;rgb:ffff/ffff/ffff\x1b\\']);

        replies.clear();
        final customVt = VirtualTerminal(
          width: 20,
          height: 5,
          defaultForeground: const Color(18, 52, 86),
          onReply: replies.add,
        );

        customVt.writeString('\x1b]10;?\x1b\\');
        expect(replies, ['\x1b]10;rgb:1212/3434/5656\x1b\\']);
        vt.dispose();
        customVt.dispose();
      },
    );

    test(
      'OSC 11;? queries default and custom background color in 16-bit hex',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 20, height: 5, onReply: replies.add);

        vt.writeString('\x1b]11;?\x1b\\');
        expect(replies, ['\x1b]11;rgb:0000/0000/0000\x1b\\']);

        replies.clear();
        final customVt = VirtualTerminal(
          width: 20,
          height: 5,
          defaultBackground: const Color(170, 187, 204),
          onReply: replies.add,
        );

        customVt.writeString('\x1b]11;?\x1b\\');
        expect(replies, ['\x1b]11;rgb:aaaa/bbbb/cccc\x1b\\']);
        vt.dispose();
        customVt.dispose();
      },
    );
  });

  group('Desktop Notifications (OSC 9 / OSC 99)', () {
    test(
      'OSC 9 preserves semicolons in message and ignores ConEmu sub-commands',
      () {
        final notifications = <({String title, String message})>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onNotification: (title, message) =>
              notifications.add((title: title, message: message)),
        );

        vt.writeString('\x1b]9;Simple message\x1b\\');
        expect(notifications.last, (title: '', message: 'Simple message'));

        // Semicolons in OSC 9 payload MUST NOT be split into title/message!
        vt.writeString('\x1b]9;Task Alert;Job finished successfully\x1b\\');
        expect(notifications.last, (
          title: '',
          message: 'Task Alert;Job finished successfully',
        ));

        // ConEmu sub-commands starting with <digit>; (e.g. OSC 9;4;1;50) MUST be ignored!
        notifications.clear();
        vt.writeString('\x1b]9;4;1;50\x1b\\\x1b]9;1;100\x07');
        expect(notifications, isEmpty);
        vt.dispose();
      },
    );

    test(
      'OSC 99 parses chunks, ignores p=? queries, and enforces 16 KiB & 32-entry caps',
      () {
        final notifications = <({String title, String message})>[];
        final vt = VirtualTerminal(
          width: 20,
          height: 5,
          onNotification: (title, message) =>
              notifications.add((title: title, message: message)),
        );

        // Single-chunk title & body
        vt.writeString('\x1b]99;;Build finished\x1b\\');
        expect(notifications.last, (title: 'Build finished', message: ''));

        vt.writeString('\x1b]99;p=body;Build completed in 1.4s\x1b\\');
        expect(notifications.last, (
          title: '',
          message: 'Build completed in 1.4s',
        ));

        // Multi-chunk notification using ID and d=0
        notifications.clear();
        vt.writeString('\x1b]99;i=task42:p=title:d=0;Download Ready\x1b\\');
        expect(notifications, isEmpty);

        vt.writeString(
          '\x1b]99;i=task42:p=body:d=1;File archive.tar.gz downloaded\x1b\\',
        );
        expect(notifications, [
          (title: 'Download Ready', message: 'File archive.tar.gz downloaded'),
        ]);

        // Base64-encoded payload (e=1)
        notifications.clear();
        final base64Payload = base64.encode(utf8.encode('Encrypted Alert'));
        vt.writeString('\x1b]99;e=1;$base64Payload\x1b\\');
        expect(notifications, [(title: 'Encrypted Alert', message: '')]);

        // Ignore p=? queries and unsupported p= types (never call onNotification!)
        notifications.clear();
        vt.writeString(
          '\x1b]99;p=?\x1b\\\x1b]99;i=q1:p=?;?\x1b\\\x1b]99;p=alive;\x1b\\',
        );
        expect(notifications, isEmpty);

        // Cap each pending notification at 16 * 1024 chars across chunks
        final chunk4k = 'A' * 4096;
        for (var i = 0; i < 6; i++) {
          vt.writeString('\x1b]99;i=big:p=body:d=0;$chunk4k\x1b\\');
        }
        vt.writeString('\x1b]99;i=big:p=body:d=1;END\x1b\\');
        expect(notifications.single.message.length, equals(16 * 1024));

        // Cap _pendingOsc99 map at 32 entries (evicting oldest)
        notifications.clear();
        for (var id = 0; id < 36; id++) {
          vt.writeString('\x1b]99;i=n$id:p=title:d=0;T$id\x1b\\');
        }
        // n0 was evicted, so finishing n0 only has the final body chunk
        vt.writeString('\x1b]99;i=n0:p=body:d=1;B0\x1b\\');
        expect(notifications.last, (title: '', message: 'B0'));
        // n35 was retained
        vt.writeString('\x1b]99;i=n35:p=body:d=1;B35\x1b\\');
        expect(notifications.last, (title: 'T35', message: 'B35'));

        // reset() clears pending OSC 99 notifications
        notifications.clear();
        vt.writeString('\x1b]99;i=rst:p=title:d=0;Stale\x1b\\');
        vt.reset();
        vt.writeString('\x1b]99;i=rst:p=body:d=1;Fresh\x1b\\');
        expect(notifications.single, (title: '', message: 'Fresh'));
        vt.dispose();
      },
    );

    test('OSC 99 supports ad-hoc Title;Message format', () {
      final notifications = <({String title, String message})>[];
      final vt = VirtualTerminal(
        width: 20,
        height: 5,
        onNotification: (title, message) =>
            notifications.add((title: title, message: message)),
      );

      vt.writeString(
        '\x1b]99;Compilation Succeeded;0 errors, 0 warnings\x1b\\',
      );
      expect(notifications, [
        (title: 'Compilation Succeeded', message: '0 errors, 0 warnings'),
      ]);
      vt.dispose();
    });
  });

  group('SGR-Pixels Mouse Mode (?1016)', () {
    test(
      r'VirtualTerminal tracks sgrPixelsMouseMode and responds to DECRQM (?1016$p)',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(width: 20, height: 5, onReply: replies.add);

        expect(vt.sgrPixelsMouseMode, isFalse);
        vt.writeString('\x1b[?1016\$p');
        expect(replies.last, '\x1b[?1016;2\$y');

        vt.writeString('\x1b[?1016h');
        expect(vt.sgrPixelsMouseMode, isTrue);
        vt.writeString('\x1b[?1016\$p');
        expect(replies.last, '\x1b[?1016;1\$y');

        vt.writeString('\x1b[?1016l');
        expect(vt.sgrPixelsMouseMode, isFalse);
        vt.writeString('\x1b[?1016\$p');
        expect(replies.last, '\x1b[?1016;2\$y');
        vt.dispose();
      },
    );

    test(
      'InputEncoder encodes SGR-Pixels even when standalone ?1016 is active without ?1006',
      () {
        const pressWithPixels = ev.MouseEvent(
          x: 5,
          y: 10,
          pixelX: 52,
          pixelY: 144,
          button: ev.MouseButton.left,
          type: ev.MouseEventType.press,
        );

        // Standalone ?1016 (sgrMouse: false, sgrPixels: true) MUST NOT fall back to X10!
        expect(
          InputEncoder.encode(
            pressWithPixels,
            sgrMouse: false,
            sgrPixels: true,
          ),
          equals('\x1b[<0;52;144M'),
        );

        // Explicit pixelX/pixelY overrides event.pixelX/pixelY when provided
        expect(
          InputEncoder.encode(
            pressWithPixels,
            sgrMouse: false,
            sgrPixels: true,
            pixelX: 60,
            pixelY: 160,
          ),
          equals('\x1b[<0;60;160M'),
        );
      },
    );

    test(
      'TerminalView translates event.pixelX/Y relative to bounds and supports standalone ?1016',
      () {
        debugShowTouchesEnabled = false;
        FocusManager.instance.setPrimaryFocus(null);
        final tester = TerminalTester();
        final vt = VirtualTerminal(width: 20, height: 10);
        final inputs = <String>[];

        tester.run(() async {
          final runner = PromptRunner<Object?>(
            terminal: tester.terminal,
            alternateScreen: false,
            widget: Padding(
              padding: const EdgeInsets.only(left: 2, top: 1),
              child: TerminalView(terminal: vt, onInput: inputs.add),
            ),
          );

          final runFuture = runner.run();
          await tester.pump(const Duration(milliseconds: 50));

          // Enable ?1000h + standalone ?1016h WITHOUT ?1006h!
          vt.writeString('\x1b[?1000h\x1b[?1016h');

          // 1. Cell click at global (5, 4) -> local (2, 2) inside Padding(left:2, top:1).
          // Default 8x16 cell metrics -> pixelX = 2*8 + 1 = 17, pixelY = 2*16 + 1 = 33.
          tester.sendString('\x1b[<0;5;4M');
          await tester.pump(const Duration(milliseconds: 20));
          expect(inputs, equals(['\x1b[<0;17;33M']));
          inputs.clear();

          // 2. Host SGR-Pixels click at global pixel (37, 55):
          // global cell = ((37-1)~/8 + 1, (55-1)~/16 + 1) = (5, 4), origin = (2*8, 1*16) = (16, 16)
          // translated local pixel = (37 - 16, 55 - 16) = (21, 39).
          runner.handleMouseEvent(
            const ev.MouseEvent(
              x: 5,
              y: 4,
              pixelX: 37,
              pixelY: 55,
              button: ev.MouseButton.left,
              type: ev.MouseEventType.press,
            ),
          );
          expect(inputs, equals(['\x1b[<0;21;39M']));

          runner.abort();
          await runFuture.catchError((_) => null);
        });
        vt.dispose();
      },
    );

    test(
      'OSC 99 preserves a=report and c=1 across chunks and emits activation/close replies',
      () {
        final replies = <String>[];
        final osc99Events = <Osc99Notification>[];
        final vt = VirtualTerminal(width: 40, height: 10, onReply: replies.add)
          ..onOsc99Notification = osc99Events.add;

        vt.writeString(
          '\x1b]99;i=ktty3:d=0:p=title:a=focus,report:c=1;KTTY Probe #3\x1b\\'
          '\x1b]99;i=ktty3:d=1:p=body;Chunked body\x1b\\',
        );

        expect(osc99Events, hasLength(1));
        expect(
          osc99Events.single,
          equals((
            id: 'ktty3',
            title: 'KTTY Probe #3',
            body: 'Chunked body',
            reportActivation: true,
            reportClose: true,
          )),
        );

        vt.reportNotificationActivated('ktty3\x1b\\bad');
        vt.reportNotificationClosed('ktty3');
        expect(
          replies,
          equals([
            '\x1b]99;i=ktty3bad;\x1b\\',
            '\x1b]99;i=ktty3:p=close;\x1b\\',
          ]),
        );
        vt.dispose();
      },
    );

    test(
      'VirtualTerminal replies to XTWINOPS 14t and 16t using cellPixelWidth/Height',
      () {
        final replies = <String>[];
        final vt = VirtualTerminal(
          width: 40,
          height: 10,
          cellPixelWidth: 11,
          cellPixelHeight: 22,
          onReply: replies.add,
        );
        vt.writeString('\x1b[16t\x1b[14t');
        expect(replies, equals(['\x1b[6;22;11t', '\x1b[4;220;440t']));

        replies.clear();
        vt.setCellPixelSize(14, 28);
        vt.writeString('\x1b[16t');
        expect(replies, equals(['\x1b[6;28;14t']));
        vt.dispose();
      },
    );
  });
}
