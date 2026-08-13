import 'dart:async';
import 'package:core_bus/core_bus.dart';
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import '../events.dart';
import '../viewmodel.dart';
import 'virtual_terminal_widget.dart';

/// The TUI application for playing asciicasts, written purely in termui.
final class AsciicastPlayerTuiApp extends StatefulWidget {
  /// The ViewModel powering the player.
  final AsciicastPlayerViewModel viewModel;

  /// Creates a new [AsciicastPlayerTuiApp].
  const AsciicastPlayerTuiApp({super.key, required this.viewModel});

  @override
  State<AsciicastPlayerTuiApp> createState() => _AsciicastPlayerTuiAppState();
}

class _AsciicastPlayerTuiAppState extends State<AsciicastPlayerTuiApp> {
  final FocusNode _focusNode = FocusNode(id: 'tui_player_root');

  PlaybackState? _playbackState;
  List<String> _savedCasts = [];
  bool _showFileSelector = false;
  int _selectedFileIndex = 0;

  StreamSubscription? _playbackStateSub;
  StreamSubscription? _savedCastsSub;
  StreamSubscription? _uploadSub;

  @override
  void initState() {
    super.initState();

    _playbackStateSub = playbackStateEvent.on(playerEventBus).listen((state) {
      if (mounted) {
        setState(() {
          _playbackState = state;
        });
      }
    });

    _savedCastsSub = savedCastsChangedEvent.on(playerEventBus).listen((list) {
      if (mounted) {
        setState(() {
          _savedCasts = list;
          if (_selectedFileIndex >= _savedCasts.length) {
            _selectedFileIndex = _savedCasts.isEmpty
                ? 0
                : _selectedFileIndex.clamp(0, _savedCasts.length - 1);
          }
        });
      }
    });

    _uploadSub = castUploadedEvent.on(playerEventBus).listen((data) {
      widget.viewModel.uploadCast(data.filename, data.bytes);
    });

    widget.viewModel.refreshSavedCasts();
  }

  @override
  void dispose() {
    _playbackStateSub?.cancel();
    _savedCastsSub?.cancel();
    _uploadSub?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _cycleSpeed() {
    final current = _playbackState?.speedMultiplier ?? 1.0;
    final next = switch (current) {
      1.0 => 1.25,
      1.25 => 1.5,
      1.5 => 2.0,
      2.0 => 0.5,
      0.5 => 0.75,
      _ => 1.0,
    };
    widget.viewModel.setSpeed(next);
  }

  bool _handleKeyEvent(term.KeyEvent event) {
    if (_showFileSelector) {
      if (event.type == term.KeyType.up) {
        if (_savedCasts.isNotEmpty) {
          setState(() {
            _selectedFileIndex =
                (_selectedFileIndex - 1 + _savedCasts.length) %
                _savedCasts.length;
          });
        }
        return true;
      } else if (event.type == term.KeyType.down) {
        if (_savedCasts.isNotEmpty) {
          setState(() {
            _selectedFileIndex = (_selectedFileIndex + 1) % _savedCasts.length;
          });
        }
        return true;
      } else if (event.type == term.KeyType.enter ||
          event.key == '\n' ||
          event.key == '\r') {
        if (_savedCasts.isNotEmpty && _selectedFileIndex < _savedCasts.length) {
          widget.viewModel.loadSavedCast(_savedCasts[_selectedFileIndex]);
          setState(() {
            _showFileSelector = false;
          });
        }
        return true;
      } else if (event.key == 'd' || event.key == 'D') {
        if (_savedCasts.isNotEmpty && _selectedFileIndex < _savedCasts.length) {
          widget.viewModel.deleteCast(_savedCasts[_selectedFileIndex]);
        }
        return true;
      } else if (event.key == 'u' || event.key == 'U') {
        uploadCastRequestedEvent.post(playerEventBus, null);
        return true;
      } else if (event.key == 'escape' ||
          event.type == term.KeyType.escape ||
          event.key == 'o' ||
          event.key == 'O') {
        setState(() {
          _showFileSelector = false;
        });
        return true;
      }
      return false;
    }

    // Normal playback controls
    if (event.key == ' ') {
      widget.viewModel.togglePlay();
      return true;
    } else if (event.type == term.KeyType.left) {
      final current = _playbackState?.currentTime ?? 0.0;
      widget.viewModel.seek(current - 5.0);
      return true;
    } else if (event.type == term.KeyType.right) {
      final current = _playbackState?.currentTime ?? 0.0;
      widget.viewModel.seek(current + 5.0);
      return true;
    } else if (event.key == 'l' || event.key == 'L') {
      final looping = _playbackState?.isLooping ?? false;
      widget.viewModel.setLoop(!looping);
      return true;
    } else if (event.key == 's' || event.key == 'S') {
      _cycleSpeed();
      return true;
    } else if (event.key == 'o' || event.key == 'O') {
      setState(() {
        _showFileSelector = true;
      });
      return true;
    } else if (event.key == 'u' || event.key == 'U') {
      uploadCastRequestedEvent.post(playerEventBus, null);
      return true;
    } else if (event.key == 'q' ||
        event.key == 'Q' ||
        event.key == 'escape' ||
        event.type == term.KeyType.escape) {
      PromptScope.of(context)?.done();
      return true;
    }

    return false;
  }

  String _formatTime(double timeSecs) {
    final mins = (timeSecs / 60).floor();
    final secs = (timeSecs % 60).floor();
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final element = context as Element;
    final width = element.size.width;
    final height = element.size.height;

    final activeFile = _playbackState?.activeFilename ?? 'None';
    final isPlaying = _playbackState?.isPlaying ?? false;
    final isLooping = _playbackState?.isLooping ?? false;
    final speed = _playbackState?.speedMultiplier ?? 1.0;
    final currentSec = _playbackState?.currentTime ?? 0.0;
    final totalSec = _playbackState?.totalDuration ?? 0.0;

    // Header Bar
    final headerLeft = ' 📹 TERMUI TUI PLAYER | Active: $activeFile';
    final headerRight =
        'Speed: ${speed.toStringAsFixed(2)}x  Loop: ${isLooping ? "ON" : "OFF"} ';
    final spacesCount = (width - headerLeft.length - headerRight.length).clamp(
      0,
      width,
    );
    final headerText = '$headerLeft${" " * spacesCount}$headerRight';

    // Timeline Text Progress
    final progressText =
        ' ${isPlaying ? "▶ PLAYING" : "⏸ PAUSED"}  [ ${_formatTime(currentSec)} / ${_formatTime(totalSec)} ]';
    final hintText =
        ' [Space]: Play/Pause  [←/→]: Seek  [O]: Select Cast  [U]: Upload  [Q/Esc]: Exit ';
    final spacer2Count = (width - progressText.length - hintText.length).clamp(
      0,
      width,
    );
    final footerControlText = '$progressText${" " * spacer2Count}$hintText';

    // TUI Scrubber values
    final sliderVal = totalSec > 0
        ? (currentSec / totalSec).clamp(0.0, 1.0)
        : 0.0;

    // Outer layout structure
    final mainLayout = Column([
      // Top header
      SizedBox(
        height: 1,
        child: Text(
          headerText,
          style: const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.charple,
            modifiers: Modifier.bold,
          ),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      // Viewport Area
      Expanded(
        child: Center(
          child: Column([
            Expanded(
              child: VirtualTerminalWidget(
                virtualTerminal: widget.viewModel.virtualTerminal,
              ),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 1, child: Text('')),
      // Timeline Scrubber
      SizedBox(
        height: 1,
        child: Slider(
          value: sliderVal,
          min: 0.0,
          max: 1.0,
          trackStyle: const Style(foreground: CharmColors.iron),
          thumbStyle: const Style(
            foreground: CharmColors.julep,
            modifiers: Modifier.bold,
          ),
          onChanged: (val) {
            widget.viewModel.seek(val * totalSec);
          },
        ),
      ),
      // Controls & Hints
      SizedBox(
        height: 1,
        child: Text(
          footerControlText,
          style: const Style(
            foreground: CharmColors.pepper,
            background: CharmColors.soda,
            modifiers: Modifier.bold,
          ),
        ),
      ),
    ]);

    // Floating File Selector Overlay dialog
    Widget? fileSelectorOverlay;
    if (_showFileSelector) {
      final dialogWidth = (width * 0.7).round().clamp(30, 80);
      final dialogHeight = (height * 0.6).round().clamp(10, 20);

      final listItems = <Widget>[];
      if (_savedCasts.isEmpty) {
        listItems.add(const Text('  No saved cast files available.'));
      } else {
        for (var i = 0; i < _savedCasts.length; i++) {
          final isSelected = i == _selectedFileIndex;
          listItems.add(
            Text(
              '${isSelected ? "➔ " : "  "}${_savedCasts[i]}',
              style: isSelected
                  ? const Style(
                      foreground: CharmColors.pepper,
                      background: CharmColors.charple,
                      modifiers: Modifier.bold,
                    )
                  : const Style(foreground: CharmColors.iron),
            ),
          );
        }
      }

      fileSelectorOverlay = Positioned.center(
        width: dialogWidth,
        height: dialogHeight,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            backgroundStyle: Style(
              foreground: CharmColors.pepper,
              background: CharmColors.soda,
            ),
          ),
          child: Column([
            SizedBox(
              height: 1,
              child: Text(
                '┌${"─" * (dialogWidth - 2)}┐',
                style: const Style(foreground: CharmColors.charple),
              ),
            ),
            SizedBox(
              height: 1,
              child: Text(
                '│${" SELECT CAST FILE ".center(dialogWidth - 2)}│',
                style: const Style(
                  foreground: CharmColors.pepper,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            SizedBox(
              height: 1,
              child: Text(
                '├${"─" * (dialogWidth - 2)}┤',
                style: const Style(foreground: CharmColors.charple),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Column(listItems),
              ),
            ),
            SizedBox(
              height: 1,
              child: Text(
                '├${"─" * (dialogWidth - 2)}┤',
                style: const Style(foreground: CharmColors.charple),
              ),
            ),
            SizedBox(
              height: 1,
              child: Text(
                '│${" [Enter]: Load  [D]: Delete  [U]: Upload New  [Esc]: Close ".center(dialogWidth - 2)}│',
                style: const Style(
                  foreground: CharmColors.julep,
                  modifiers: Modifier.bold,
                ),
              ),
            ),
            SizedBox(
              height: 1,
              child: Text(
                '└${"─" * (dialogWidth - 2)}┘',
                style: const Style(foreground: CharmColors.charple),
              ),
            ),
          ]),
        ),
      );
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (event) {
        return _handleKeyEvent(event);
      },
      child: Stack([
        Positioned(left: 0, top: 0, right: 0, bottom: 0, child: mainLayout),
        ?fileSelectorOverlay,
      ]),
    );
  }
}

extension on String {
  String center(int width) {
    if (length >= width) return substring(0, width);
    final totalPad = width - length;
    final leftPad = totalPad ~/ 2;
    final rightPad = totalPad - leftPad;
    return '${" " * leftPad}$this${" " * rightPad}';
  }
}
