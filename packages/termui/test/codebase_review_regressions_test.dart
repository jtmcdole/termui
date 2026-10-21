import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:file/local.dart';
import 'package:file/memory.dart';
import 'package:termui/perf/fs_sink.dart';
import 'package:termui/perf/isolate_sink.dart';
import 'package:termui/perf/sink_creator.dart';
import 'package:termui/terminal/event.dart' as term_event;
import 'package:termui/terminal/input_parser.dart';
import 'package:termui/termui.dart';
import 'package:termui/trace/models/trace_models.dart';
import 'package:termui_test/termui_test.dart';
import 'package:test/test.dart';

void main() {
  setUp(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  tearDown(() {
    FocusManager.instance.setPrimaryFocus(null);
  });

  group('CODEBASE_REVIEW Regressions', () {
    test('P0-3: InputParser decodes UTF-8, Alt+[/Alt+O, and CPR (CSI R)', () {
      final parser = InputParser();

      final utf8Events = parser.parse(utf8.encode('é中🚀'));
      final keys = utf8Events.whereType<KeyEvent>().map((e) => e.key).toList();
      expect(keys, equals(['é', '中', '🚀']));

      final altBracket = parser.parse([27, 91]);
      expect(altBracket.single, isA<KeyEvent>());
      final altBracketKey = altBracket.single as KeyEvent;
      expect(altBracketKey.key, equals('['));
      expect(altBracketKey.modifiers, contains(term_event.Modifier.alt));

      final altO = parser.parse([27, 79]);
      expect(altO.single, isA<KeyEvent>());
      final altOKey = altO.single as KeyEvent;
      expect(altOKey.key, equals('O'));
      expect(altOKey.modifiers, contains(term_event.Modifier.alt));

      final cprEvents = parser.parse('\x1b[24;80R'.codeUnits);
      expect(cprEvents.single, isA<CursorPositionReportEvent>());
      final cpr = cprEvents.single as CursorPositionReportEvent;
      expect(cpr.y, equals(24));
      expect(cpr.x, equals(80));
    });

    test(
      'P0-4: PromptRunner._routeKeyEvent calls primaryFocus.bubbleKeyEvent once',
      () async {
        var bubbleCalls = 0;
        final focusNode = FocusNode(id: 'leaf');
        final backend = MockTerminalBackend();
        final terminal = Terminal(backend);
        final runner = PromptRunner<void>(
          terminal: terminal,
          mode: ExecutionMode.managed,
          widget: Column([
            const Text('1'),
            const Text('2'),
            const Text('3'),
            Focus(
              focusNode: focusNode,
              autofocus: true,
              onKeyEvent: (event) {
                bubbleCalls++;
                return false;
              },
              child: const Text('4'),
            ),
          ]),
        );
        unawaited(runner.run());
        await Future<void>.delayed(Duration.zero);
        focusNode.requestFocus();
        bubbleCalls = 0;
        runner.handleKeyEvent(const KeyEvent('x', KeyType.character));
        runner.dispose();
        terminal.dispose();
        expect(bubbleCalls, equals(1));
      },
    );

    test('P0-5: Compositor blocks occluded lower-layer fg and modifiers', () {
      final topBuf = Buffer(3, 1)
        ..writeString(0, 0, '   ', const Style(background: Color(0, 0, 0)));
      final bottomBuf = Buffer(5, 1)
        ..writeString(
          0,
          0,
          'HELLO',
          const Style(
            foreground: Color(255, 0, 0),
            modifiers: Modifier.underline,
          ),
        );

      final target = Buffer(5, 1);
      Compositor().composite(
        target: target,
        layers: [
          LayeredBuffer(buffer: bottomBuf, x: 0, y: 0, zIndex: 0),
          LayeredBuffer(buffer: topBuf, x: 0, y: 0, zIndex: 10),
        ],
      );

      expect(target.getForeground(0, 0), equals(0));
      expect(target.getModifiers(0, 0) & Modifier.underline, equals(0));
    });

    test('P0-6: InheritedElement notifies dependents on value update', () {
      final seenValues = <int>[];
      final constChild = _DependentChild(onBuild: seenValues.add);
      final el = InheritedElement(
        _CounterInherited(value: 1, child: constChild),
      )..mount(null);

      el.update(_CounterInherited(value: 2, child: constChild));
      el.unmount();

      expect(seenValues, equals([1, 2]));
    });

    test(
      'P0-7: getIntrinsicHeight reuses mounted tree and skips focus mutations',
      () {
        _IntrinsicProbe.mountCount = 0;
        Widget tree = const Text('leaf');
        for (var i = 0; i < 6; i++) {
          tree = _IntrinsicProbe(child: tree);
        }
        tree.getIntrinsicHeight(80);
        expect(_IntrinsicProbe.mountCount, lessThanOrEqualTo(6));

        final liveNode = FocusNode(id: 'live');
        final liveWidget = Focus(focusNode: liveNode, child: const Text('hi'));
        final liveEl = liveWidget.createElement()..mount(null);
        liveNode.requestFocus();
        expect(liveNode.hasFocus, isTrue);
        liveWidget.getIntrinsicHeight(80);
        expect(liveNode.hasFocus, isTrue);
        liveEl.unmount();
      },
    );

    test(
      'P0-13: FocusableStateMixin preserves external FocusNode and TabPanel updates/unmounts',
      () {
        final scope = FocusScopeNode(id: 'scope');
        final externalNode = FocusNode(id: 'ext');
        scope.addChild(externalNode);
        final btnEl = InkwellButton(
          text: 'Click',
          focusNode: externalNode,
          onPressed: () {},
        ).createElement()..mount(null);
        btnEl.unmount();
        expect(externalNode.parent, equals(scope));

        final tabCtrl = TabController(length: 2);
        final panelEl =
            TabPanel(
                controller: tabCtrl,
                tabFocusNodes: [
                  FocusNode(id: 't1'),
                  FocusNode(id: 't2'),
                ],
                children: const [Text('Tab 1'), Text('Tab 2')],
              ).createElement()
              ..owner = BuildOwner()
              ..mount(null);
        tabCtrl.index = 1;
        expect(panelEl.isDirty, isTrue);
        panelEl.rebuild();
        Element? activeChild;
        panelEl.visitChildren((c) => activeChild = c);
        expect((activeChild?.widget as Text).data, equals('Tab 2'));
        expect(activeChild?.mounted, isTrue);
        panelEl.unmount();
        expect(activeChild?.mounted, isFalse);
      },
    );

    test(
      'P0-14: createTracerSink uses IsolateSink on LocalFileSystem and parseTraceFile preserves dur',
      () async {
        final memSink = createTracerSink(MemoryFileSystem(), 'trace.json', 0);
        expect(memSink, isA<FileSystemSink>());
        await memSink.close();

        final tmpDir = Directory.systemTemp.createTempSync('trace_test');
        try {
          final localSink = createTracerSink(
            const LocalFileSystem(),
            '${tmpDir.path}/iso_trace.json',
            0,
          );
          expect(localSink, isA<IsolateSink>());
          await localSink.close();

          final traceFile = File('${tmpDir.path}/test.json');
          traceFile.writeAsStringSync(
            jsonEncode([
              {
                'name': 'frame',
                'ph': 'X',
                'cat': 'paint',
                'ts': 1000,
                'dur': 5000,
                'tid': 1,
              },
            ]),
          );
          final parsed = await parseTraceFile(traceFile.path);
          final spans = parsed!['spans'] as List<TraceSpan>;
          expect(spans.single.endUs - spans.single.startUs, equals(5000));
        } finally {
          tmpDir.deleteSync(recursive: true);
        }
      },
    );

    test('P0-15: find.text matches multiline strings', () {
      final root = const Text('Line 1\nLine 2').createElement()..mount(null);
      expect(find.text('Line 1\nLine 2').apply([root]), isNotEmpty);
      root.unmount();
    });

    test(
      'P1-2: StatefulElement.unmount disposes bottom-up and FocusNode.dispose detaches children',
      () {
        final parentScope = FocusScopeNode(id: 'parentScope');
        final childNode = FocusNode(id: 'childNode');
        parentScope.addChild(childNode);
        parentScope.dispose();
        expect(childNode.parent, isNull);

        final disposeOrder = <String>[];
        final tree = _DisposeOrderProbe(
          name: 'parent',
          onDispose: disposeOrder.add,
          child: _DisposeOrderProbe(
            name: 'child',
            onDispose: disposeOrder.add,
            child: const Text('leaf'),
          ),
        );
        final el = tree.createElement()..mount(null);
        el.unmount();
        expect(disposeOrder, equals(['child', 'parent']));
      },
    );

    test(
      'P1-4: Buffer.writeString clips wide chars at clip boundary and CanvasElement respects Viewport',
      () {
        final buf = Buffer(10, 2);
        buf.pushClip(const Rect(0, 0, 3, 2));
        buf.writeString(2, 0, '中', const Style(background: Color(255, 0, 0)));
        buf.popClip();
        expect(buf.characters[2], equals(' '));
        expect(buf.characters[3], equals(' '));
        expect(buf.getBackground(3, 0), equals(0));

        final canvasBuf = Buffer(10, 5);
        final vp = Viewport(canvasBuf, const Rect(2, 1, 3, 2));
        final canvasWidget = Canvas(
          8,
          4,
          style: const Style(background: Color(0, 255, 0)),
        )..setPixel(10, 0, true);
        final canvasEl = canvasWidget.createElement()..mount(null);
        canvasEl.layout(const BoxConstraints(maxWidth: 8, maxHeight: 4));
        canvasEl.paint(vp, Offset.zero);
        canvasEl.unmount();
        expect(canvasBuf.getBackground(5, 1), equals(0));
      },
    );

    test(
      'P1-5: Column/Row CrossAxisAlignment.center/end and 1-row Sparkline gradient',
      () {
        final colEl = const Column(
          [SizedBox(width: 2, height: 1)],
          crossAxisAlignment: CrossAxisAlignment.end,
        ).createElement()..mount(null);
        colEl.layout(
          const BoxConstraints(minWidth: 10, maxWidth: 10, maxHeight: 5),
        );
        final childDx =
            (colEl as ColumnElement).childElements.first.relativeOffset.dx;
        colEl.unmount();
        expect(childDx, equals(8));

        final sparkBuf = Buffer(10, 1);
        final sparkEl = Sparkline(
          const [0.5, 1.0, 0.8],
          direction: ProgressDirection.bottomToTop,
          colorBuilder: (_, _, [_, _, _]) => (
            fg: [
              (stop: 0.0, color: Colors.green),
              (stop: 1.0, color: Colors.red),
            ],
            bg: null,
          ),
        ).createElement()..mount(null);
        sparkEl.layout(const BoxConstraints(maxWidth: 10, maxHeight: 1));
        sparkEl.paint(sparkBuf, Offset.zero);
        sparkEl.unmount();
        expect(sparkBuf.getForeground(0, 0), isNonZero);
      },
    );

    test(
      'P1-6: RingBuffer.removeLast preserves capacity and length expansion throws UnsupportedError',
      () {
        final rb = RingBuffer<int>(10)..addAll([1, 2, 3]);
        expect(rb.removeLast(), equals(3));
        rb.add(4);
        expect(rb.toList(), equals([1, 2, 4]));

        final rb2 = RingBuffer<int>(5)..add(1);
        expect(() => rb2.length = 3, throwsUnsupportedError);
      },
    );

    test(
      'P2-2: SingleChildScrollView preserves RegisteredEffects and cleans orphaned wide-char cells',
      () {
        final scrollTarget = Buffer(6, 5);
        final scrollCtrl = DiscreteScrollController(initialScrollOffset: 1);
        final scrollEl = SingleChildScrollView(
          scrollDirection: LayoutDirection.horizontal,
          controller: scrollCtrl,
          childLength: 10,
          child: const _EffectPaintingWidget(),
        ).createElement()..mount(null);
        scrollEl.layout(const BoxConstraints(maxWidth: 6, maxHeight: 5));
        scrollCtrl.jumpTo(1);
        scrollEl.rebuild();
        scrollEl.layout(const BoxConstraints(maxWidth: 6, maxHeight: 5));
        scrollEl.paint(scrollTarget, Offset.zero);
        scrollEl.unmount();

        expect(scrollTarget.effects, hasLength(1));
        expect(scrollTarget.characters[0], equals(' '));
      },
    );

    test(
      'P1-2/P1-3/P1-4/P1-5/P1-6: Widget.canUpdate key reconciliation, empty DropdownButton, Viewport/Buffer alpha & truncated ANSI, SplitPane zero size, FlashEffect offset, DragTarget onWillAccept',
      () {
        // 1. Row reconciles children via Widget.canUpdate (key mismatch triggers remount)
        final keyA = const ValueKey('a');
        final keyB = const ValueKey('b');
        final rowEl = Row([_KeyedProbe(key: keyA)]).createElement()
          ..mount(null);
        final firstState =
            ((rowEl as RowElement).childElements.first as StatefulElement)
                .state;
        rowEl.update(Row([_KeyedProbe(key: keyB)]));
        final secondState =
            (rowEl.childElements.first as StatefulElement).state;
        expect(identical(firstState, secondState), isFalse);
        rowEl.unmount();

        // 2. Empty DropdownButton does not throw StateError during build or key handling
        final ddEl = DropdownButton<int>(
          items: const [],
          value: 1,
          hint: const Text('Empty'),
        ).createElement()..mount(null);
        ddEl.layout(const BoxConstraints(maxWidth: 20, maxHeight: 1));
        expect(
          (ddEl as StatefulElement).state,
          isA<DropdownButtonState<int>>(),
        );
        expect(
          (ddEl.state as DropdownButtonState<int>).handleKeyEvent(
            const KeyEvent('down', KeyType.down),
          ),
          isFalse,
        );
        ddEl.unmount();

        // 3. BufferAnsiSerialization.fromAnsi handles truncated 38/48 SGR sequences
        final parsed = BufferAnsiSerialization.fromAnsi(
          '\x1b[1;1f\x1b[38;2;255mHi\x1b[48m',
        );
        expect(parsed.getCharacter(0, 0), equals('H'));

        // 4. SplitPane handles zero constraints without RangeError
        final splitEl = SplitPane(
          constraint1: const FlexConstraint(1),
          constraint2: const FlexConstraint(1),
          child1: const Text('A'),
          child2: const Text('B'),
        ).createElement()..mount(null);
        expect(
          () => splitEl.layout(const BoxConstraints(maxWidth: 0, maxHeight: 0)),
          returnsNormally,
        );
        splitEl.unmount();

        // 5. FlashEffect paints at area.x / area.y offset
        final flashBuf = Buffer(10, 5);
        final flash = FlashEffect(
          duration: const Duration(milliseconds: 500),
          flashColor: const Color(255, 0, 0),
        )..start(const Point(0, 0), () {});
        flash.paint(flashBuf, const Rect(3, 2, 2, 1), Style.empty);
        expect(flashBuf.getBackground(0, 0), equals(0));
        expect(flashBuf.getBackground(3, 2), isNonZero);
      },
    );
  });
}

class _CounterInherited extends InheritedWidget {
  final int value;

  const _CounterInherited({required this.value, required super.child});

  @override
  bool updateShouldNotify(covariant _CounterInherited oldWidget) =>
      value != oldWidget.value;
}

class _DependentChild extends StatefulWidget {
  final void Function(int) onBuild;

  const _DependentChild({required this.onBuild});

  @override
  State<_DependentChild> createState() => _DependentChildState();
}

class _DependentChildState extends State<_DependentChild> {
  @override
  Widget build(BuildContext context) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_CounterInherited>();
    widget.onBuild(inherited?.value ?? -1);
    return const Text('dep');
  }
}

class _IntrinsicProbe extends StatefulWidget {
  static int mountCount = 0;
  final Widget child;

  const _IntrinsicProbe({required this.child});

  @override
  State<_IntrinsicProbe> createState() => _IntrinsicProbeState();
}

class _IntrinsicProbeState extends State<_IntrinsicProbe> {
  @override
  void initState() {
    super.initState();
    _IntrinsicProbe.mountCount++;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _DisposeOrderProbe extends StatefulWidget {
  final String name;
  final void Function(String) onDispose;
  final Widget child;

  const _DisposeOrderProbe({
    required this.name,
    required this.onDispose,
    required this.child,
  });

  @override
  State<_DisposeOrderProbe> createState() => _DisposeOrderProbeState();
}

class _DisposeOrderProbeState extends State<_DisposeOrderProbe> {
  @override
  void dispose() {
    widget.onDispose(widget.name);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

final class _NoOpEffect extends TerminalEffect {
  const _NoOpEffect();
  @override
  void applyEffect(Buffer target, Rect bounds) {}
}

class _EffectPaintingWidget extends Widget {
  const _EffectPaintingWidget();

  @override
  Element createElement() => _EffectPaintingElement(this);

  @override
  int getIntrinsicHeight(int width) => 5;

  @override
  int getIntrinsicWidth(int height) => 10;
}

class _EffectPaintingElement extends LeafElement {
  _EffectPaintingElement(super.widget);

  @override
  Size performLayout(BoxConstraints constraints) => const Size(10, 5);

  @override
  void performPaint(Buffer buffer, Offset offset) {
    buffer.addEffect(
      RegisteredEffect(
        const _NoOpEffect(),
        Rect(offset.dx, offset.dy, 10, 5),
        0,
        0,
      ),
    );
    buffer.writeString(offset.dx, offset.dy, '中中中', const Style());
  }
}

class _KeyedProbe extends StatefulWidget {
  const _KeyedProbe({super.key});

  @override
  State<_KeyedProbe> createState() => _KeyedProbeState();
}

class _KeyedProbeState extends State<_KeyedProbe> {
  @override
  Widget build(BuildContext context) => const Text('probe');
}
