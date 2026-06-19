// ignore_for_file: file_names

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:characters/characters.dart';
import 'package:termui/terminal/terminal.dart' as term;
import 'package:termui/termui.dart';

/// A component that renders status indicators with custom styles and borders.
class StatCard extends StatelessWidget {
  final String title;
  final String value;
  final String detailText;
  final Widget? detailWidget;
  final Color color;

  const StatCard({
    super.key,
    required this.title,
    required this.value,
    this.detailText = '',
    this.detailWidget,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(border: Border.all(Style(foreground: color))),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column([
          SizedBox(
            height: 1,
            child: Text(
              title,
              style: Style(foreground: color, modifiers: Modifier.bold),
            ),
          ),
          const SizedBox(height: 1),
          SizedBox(
            height: 1,
            child: Text(value, style: const Style(modifiers: Modifier.bold)),
          ),
          const SizedBox(height: 1),
          SizedBox(
            height: 1,
            child:
                detailWidget ??
                Text(detailText, style: const Style(modifiers: Modifier.dim)),
          ),
        ]),
      ),
    );
  }
}

/// A widget that displays operating system details, runtime information, and uptime.
class SystemInfoPanel extends StatelessWidget {
  final DateTime bootTime;

  const SystemInfoPanel({super.key, required this.bootTime});

  @override
  Widget build(BuildContext context) {
    final uptime = DateTime.now().difference(bootTime);
    final days = uptime.inDays;
    final hours = uptime.inHours % 24;
    final minutes = uptime.inMinutes % 60;
    final seconds = uptime.inSeconds % 60;

    final uptimeStr = [
      if (days > 0) '${days}d',
      if (hours > 0 || days > 0) '${hours}h',
      if (minutes > 0 || hours > 0 || days > 0) '${minutes}m',
      '${seconds}s',
    ].join(' ');

    final timeStr = DateTime.now().toIso8601String().substring(11, 19);

    return Column([
      const SizedBox(
        height: 1,
        child: Text(
          'SYSTEM INFO',
          style: Style(foreground: Colors.blue, modifiers: Modifier.bold),
        ),
      ),
      const SizedBox(height: 1),
      SizedBox(
        height: 1,
        child: Text('OS:      ${Platform.operatingSystem.toUpperCase()}'),
      ),
      SizedBox(height: 1, child: Text('PID:     $pid')),
      SizedBox(
        height: 1,
        child: Text('Dart:    ${Platform.version.split(" ").first}'),
      ),
      SizedBox(height: 1, child: Text('Time:    $timeStr')),
      SizedBox(height: 1, child: Text('Uptime:  $uptimeStr')),
    ]);
  }
}

/// A custom stateful widget that displays wrapped, bounded log messages with rendering cache.
class LogWindow extends StatefulWidget {
  final List<String> logMessages;

  const LogWindow({super.key, required this.logMessages});

  @override
  State<LogWindow> createState() => _LogWindowState();
}

class _LogWindowState extends State<LogWindow> {
  int? _lastWidth;
  int? _lastLogsLength;
  String? _lastLogElement;
  List<String> _wrappedLines = [];

  void _ensureWrapped(int width) {
    final logs = widget.logMessages;
    final length = logs.length;
    final lastElement = logs.isEmpty ? null : logs.last;

    if (_lastWidth == width &&
        _lastLogsLength == length &&
        _lastLogElement == lastElement) {
      return; // Cache hit
    }

    _wrappedLines = [];
    for (final msg in logs) {
      _wrappedLines.addAll(wrapText(msg, width));
    }

    _lastWidth = width;
    _lastLogsLength = length;
    _lastLogElement = lastElement;
  }

  @override
  Widget build(BuildContext context) {
    return _LogWindowRender(
      onRender: _ensureWrapped,
      getWrappedLines: () => _wrappedLines,
    );
  }
}

class _LogWindowRender extends Widget {
  final void Function(int width) onRender;
  final List<String> Function() getWrappedLines;

  const _LogWindowRender({
    required this.onRender,
    required this.getWrappedLines,
  });

  @override
  Element createElement() => _LogWindowRenderElement(this);
}

class _LogWindowRenderElement extends Element {
  _LogWindowRenderElement(_LogWindowRender super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    final w = constraints.maxWidth == BoxConstraints.infinity
        ? 0
        : constraints.maxWidth;
    final h = constraints.maxHeight == BoxConstraints.infinity
        ? 0
        : constraints.maxHeight;
    return constraints.constrain(Size(w, h));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as _LogWindowRender;
    final areaWidth = size.width.toInt();
    final areaHeight = size.height.toInt();
    if (areaWidth <= 0 || areaHeight <= 0) return;

    // Verify cache before rendering
    w.onRender(areaWidth);

    final wrappedLines = w.getWrappedLines();
    final startIdx = max(0, wrappedLines.length - areaHeight);
    final visibleLines = wrappedLines.sublist(startIdx);

    for (var i = 0; i < visibleLines.length; i++) {
      if (i >= areaHeight) break;
      buffer.writeString(
        offset.dx.toInt(),
        offset.dy.toInt() + i,
        visibleLines[i],
        Style.empty,
      );
    }
  }
}

/// Helper function to wrap text safely using characters visual width measurement.
List<String> wrapText(String text, int maxWidth) {
  if (maxWidth <= 0) return [];
  final lines = <String>[];
  final paragraphs = text.split('\n');

  for (final paragraph in paragraphs) {
    if (paragraph.isEmpty) {
      lines.add('');
      continue;
    }

    final words = paragraph.split(' ');
    var currentLine = '';
    var currentLineLen = 0;

    for (final word in words) {
      if (word.isEmpty) continue;

      final wordWidth = measureStringWidth(word);

      if (currentLine.isEmpty) {
        if (wordWidth <= maxWidth) {
          currentLine = word;
          currentLineLen = wordWidth;
        } else {
          _splitWordIntoLines(word, maxWidth, lines);
        }
      } else {
        if (currentLineLen + 1 + wordWidth <= maxWidth) {
          currentLine += ' $word';
          currentLineLen += 1 + wordWidth;
        } else {
          lines.add(currentLine);
          if (wordWidth <= maxWidth) {
            currentLine = word;
            currentLineLen = wordWidth;
          } else {
            currentLine = '';
            currentLineLen = 0;
            _splitWordIntoLines(word, maxWidth, lines);
          }
        }
      }
    }

    if (currentLine.isNotEmpty) {
      lines.add(currentLine);
    }
  }

  return lines;
}

void _splitWordIntoLines(String word, int maxWidth, List<String> lines) {
  final chunk = StringBuffer();
  var takeWidth = 0;
  for (final char in word.characters) {
    final w = isWideGrapheme(char) ? 2 : 1;
    if (takeWidth + w > maxWidth) {
      if (chunk.isNotEmpty) {
        lines.add(chunk.toString());
        chunk.clear();
        takeWidth = 0;
      }
    }
    chunk.write(char);
    takeWidth += w;
  }
  if (chunk.isNotEmpty) {
    lines.add(chunk.toString());
  }
}

/// The main Dashboard Application root widget coordinating simulation timers.
class DashboardApp extends StatefulWidget {
  const DashboardApp({super.key});

  @override
  State<DashboardApp> createState() => _DashboardAppState();
}

class _DashboardAppState extends State<DashboardApp> {
  late final DateTime bootTime;
  double cpuUsage = 0.45;
  double ramUsed = 8.2;
  final double ramTotal = 16.0;
  double txSpeed = 1.2;
  double rxSpeed = 3.4;
  final List<String> logMessages = [];

  Timer? _metricsTimer;
  Timer? _logTimer;

  @override
  void initState() {
    super.initState();
    bootTime = DateTime.now();
    _startSimulationTimers();
  }

  @override
  void dispose() {
    _metricsTimer?.cancel();
    _logTimer?.cancel();
    super.dispose();
  }

  void _startSimulationTimers() {
    final random = Random();

    _metricsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        cpuUsage = (cpuUsage + (random.nextDouble() * 0.2 - 0.1)).clamp(
          0.0,
          1.0,
        );
        ramUsed = (ramUsed + (random.nextDouble() * 0.4 - 0.2)).clamp(
          2.0,
          ramTotal - 0.5,
        );
        txSpeed = (txSpeed + (random.nextDouble() * 0.8 - 0.4)).clamp(
          0.1,
          100.0,
        );
        rxSpeed = (rxSpeed + (random.nextDouble() * 1.5 - 0.75)).clamp(
          0.1,
          250.0,
        );
      });
    });

    _logTimer = Timer.periodic(const Duration(milliseconds: 500), (timer) {
      final templates = [
        'GET /api/v1/status - 200 OK',
        'POST /api/v1/auth/login - 401 Unauthorized',
        'GET /api/v1/users - 200 OK',
        'Database connection pool health check: OK',
        'Scheduled cron: clean_sessions executed in 12ms',
        'Worker thread #${random.nextInt(8)} spawned successfully',
        'Warning: High disk I/O detected on /dev/sda1',
        'Backup job: finished uploading snapshot_backup.tar.gz',
        'Cache invalidated for user_${random.nextInt(1000)}',
        'System updated: packages security patches applied',
        'Connected to redis instance at 127.0.0.1:6379',
      ];
      final timestamp = DateTime.now().toIso8601String().substring(11, 19);
      final newLog =
          '[$timestamp] ${templates[random.nextInt(templates.length)]}';

      setState(() {
        logMessages.add(newLog);
        if (logMessages.length > 100) {
          logMessages.removeAt(0);
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final cpuCard = StatCard(
      title: ' CPU USAGE ',
      value: '${(cpuUsage * 100).toStringAsFixed(1)}%',
      detailWidget: LinearProgressIndicator(
        cpuUsage.clamp(0.0, 1.0),
        smooth: true,
        style: const Style(foreground: Colors.green),
      ),
      color: Colors.green,
    );

    final memCard = StatCard(
      title: ' MEMORY (RAM) ',
      value:
          '${ramUsed.toStringAsFixed(1)} GB / ${ramTotal.toStringAsFixed(1)} GB',
      detailWidget: LinearProgressIndicator(
        (ramUsed / ramTotal).clamp(0.0, 1.0),
        smooth: true,
        style: const Style(foreground: Colors.blue),
      ),
      color: Colors.blue,
    );

    final netCard = StatCard(
      title: ' NETWORK TRAFFIC ',
      value: 'TX: ${txSpeed.toStringAsFixed(1)} MB/s',
      detailText: 'RX: ${rxSpeed.toStringAsFixed(1)} MB/s',
      color: Colors.yellow,
    );

    final logPanel = DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.all(Style(foreground: Colors.white)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: Column([
          const SizedBox(
            height: 1,
            child: Text(
              ' SERVER LOGS ',
              style: Style(modifiers: Modifier.bold),
            ),
          ),
          const SizedBox(height: 1),
          Expanded(child: LogWindow(logMessages: logMessages)),
        ]),
      ),
    );

    final sysPanel = DecoratedBox(
      decoration: const BoxDecoration(
        border: Border.all(Style(foreground: Colors.blue)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1),
        child: SystemInfoPanel(bootTime: bootTime),
      ),
    );

    final dashboardContent = Column([
      SizedBox(
        height: 1,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            backgroundStyle: Style(background: Colors.blue),
          ),
          child: Center(
            child: Text(
              ' 💻 SERVER MONITORING DASHBOARD 💻 ',
              style: Style(
                foreground: Colors.white,
                background: Colors.blue,
                modifiers: Modifier.bold,
              ),
            ),
          ),
        ),
      ),
      const SizedBox(height: 1),
      Expanded(
        flex: 1,
        child: Row([
          Expanded(child: cpuCard),
          const SizedBox(width: 1),
          Expanded(child: memCard),
          const SizedBox(width: 1),
          Expanded(child: netCard),
        ]),
      ),
      const SizedBox(height: 1),
      Expanded(
        flex: 2,
        child: Row([
          Expanded(flex: 2, child: logPanel),
          const SizedBox(width: 1),
          Expanded(flex: 1, child: sysPanel),
        ]),
      ),
      const SizedBox(height: 1),
      const SizedBox(
        height: 1,
        child: Center(
          child: Text(
            'Press [Q] or Ctrl+C to Quit',
            style: Style(modifiers: Modifier.dim),
          ),
        ),
      ),
    ]);

    return SafeLayout(minWidth: 40, minHeight: 10, child: dashboardContent);
  }
}

void main() async {
  await term.Terminal.runGuarded((terminal) async {
    final termSize = await terminal.size;
    var width = termSize.x;
    var height = termSize.y;

    terminal.enterAlternateScreen();
    terminal.hideCursor();

    final buffer = Buffer.blank(width, height);
    var renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);

    final elementWrapper = ElementWidget(const DashboardApp());

    late final BuildOwner buildOwner;

    void drawFrame() {
      buildOwner.buildScope();
      buffer.clear();
      buffer.fill(Cell(' ', Style.empty));
      elementWrapper.layout(
        BoxConstraints.tight(Size(width, height)),
        buildOwner,
      );
      elementWrapper.paint(buffer, Offset.zero);

      final sb = StringBuffer();
      renderer.render(buffer, sb);
      if (sb.isNotEmpty) {
        stdout.write(sb.toString());
      }
    }

    // Coalesce updates in a microtask to prevent pipeline thrashing
    bool frameScheduled = false;
    void scheduleRepaint() {
      if (!frameScheduled) {
        frameScheduled = true;
        scheduleMicrotask(() {
          drawFrame();
          frameScheduled = false;
        });
      }
    }

    buildOwner = BuildOwner(onNeedVisualUpdate: scheduleRepaint);

    drawFrame();

    final sizeSubscription = terminal.watchSize().listen((size) {
      width = size.x;
      height = size.y;
      buffer.resize(width, height);
      renderer = Renderer(width, height, mode: RenderingMode.alternateScreen);
      // Size changes are passed declaratively down the tree during render
      drawFrame();
    });

    try {
      await for (final event in terminal.events) {
        if (event is term.KeyEvent) {
          if (event.key == 'q' || event.key == 'Q') {
            break;
          }
          if (event.key.length == 1 && event.key.codeUnits[0] == 3) {
            break; // Ctrl+C
          }
        }
      }
    } finally {
      sizeSubscription.cancel();
      elementWrapper.element?.unmount();
      terminal.showCursor();
      terminal.exitAlternateScreen();
      terminal.resetStyle();
    }
  });
  print('Dashboard demo exited cleanly.');
  exit(0);
}
