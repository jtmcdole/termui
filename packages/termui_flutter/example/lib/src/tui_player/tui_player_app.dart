import 'dart:async';
import 'package:core_bus/core_bus.dart';
import 'package:flutter/widgets.dart' show Characters;
import 'package:termui/termui.dart';
import 'package:termui/terminal/terminal.dart' as term;
import '../events.dart';
import '../viewmodel.dart';
import 'virtual_terminal_widget.dart';

String _formatPlaybackTime(double timeSecs) {
  final mins = (timeSecs / 60).floor();
  final secs = (timeSecs % 60).floor();
  return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
}

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

  List<String> _savedCasts = [];
  bool _showFileSelector = false;
  int _selectedFileIndex = 0;

  StreamSubscription<List<String>>? _savedCastsSub;
  StreamSubscription<UploadedCastData>? _uploadSub;

  @override
  void initState() {
    super.initState();

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
    _savedCastsSub?.cancel();
    _uploadSub?.cancel();
    _focusNode.dispose();
    super.dispose();
  }

  void _cycleSpeed() {
    final current = widget.viewModel.speedMultiplier;
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
      return _handleFileSelectorKeyEvent(event);
    }
    return _handlePlaybackKeyEvent(event);
  }

  bool _handleFileSelectorKeyEvent(term.KeyEvent event) {
    if (event.type == term.KeyType.up) {
      if (_savedCasts.isNotEmpty) {
        setState(() {
          _selectedFileIndex =
              (_selectedFileIndex - 1 + _savedCasts.length) %
              _savedCasts.length;
        });
      }
      return true;
    }
    if (event.type == term.KeyType.down) {
      if (_savedCasts.isNotEmpty) {
        setState(() {
          _selectedFileIndex = (_selectedFileIndex + 1) % _savedCasts.length;
        });
      }
      return true;
    }
    if (event.type == term.KeyType.enter ||
        event.key == '\n' ||
        event.key == '\r') {
      if (_savedCasts.isNotEmpty && _selectedFileIndex < _savedCasts.length) {
        widget.viewModel.loadSavedCast(_savedCasts[_selectedFileIndex]);
        setState(() {
          _showFileSelector = false;
        });
      }
      return true;
    }
    switch (event.key.toLowerCase()) {
      case 'd':
        if (_savedCasts.isNotEmpty && _selectedFileIndex < _savedCasts.length) {
          widget.viewModel.deleteCast(_savedCasts[_selectedFileIndex]);
        }
        return true;
      case 'u':
        uploadCastRequestedEvent.post(playerEventBus, null);
        return true;
      case 'escape' || 'o':
        setState(() {
          _showFileSelector = false;
        });
        return true;
    }
    if (event.type == term.KeyType.escape) {
      setState(() {
        _showFileSelector = false;
      });
      return true;
    }
    return false;
  }

  bool _handlePlaybackKeyEvent(term.KeyEvent event) {
    if (event.key == ' ') {
      widget.viewModel.togglePlay();
      return true;
    }
    if (event.type == term.KeyType.left) {
      widget.viewModel.seek(widget.viewModel.currentTime - 5.0);
      return true;
    }
    if (event.type == term.KeyType.right) {
      widget.viewModel.seek(widget.viewModel.currentTime + 5.0);
      return true;
    }
    switch (event.key.toLowerCase()) {
      case 'l':
        widget.viewModel.setLoop(!widget.viewModel.isLooping);
        return true;
      case 's':
        _cycleSpeed();
        return true;
      case 'o':
        setState(() {
          _showFileSelector = true;
        });
        return true;
      case 'u':
        uploadCastRequestedEvent.post(playerEventBus, null);
        return true;
      case 'q' || 'escape':
        PromptScope.of(context)?.done();
        return true;
    }
    if (event.type == term.KeyType.escape) {
      PromptScope.of(context)?.done();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final element = context as Element;
    final width = element.size.width;
    final height = element.size.height;

    final mainLayout = Column([
      SizedBox(
        height: 1,
        child: _PlaybackHeaderBar(viewModel: widget.viewModel),
      ),
      const SizedBox(height: 1, child: Text('')),
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
      SizedBox(
        height: 2,
        child: _PlaybackScrubberBar(viewModel: widget.viewModel),
      ),
    ]);

    final fileSelectorOverlay = _showFileSelector
        ? _buildFileSelectorOverlay(width, height)
        : null;

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Stack([
        Positioned(left: 0, top: 0, right: 0, bottom: 0, child: mainLayout),
        ?fileSelectorOverlay,
      ]),
    );
  }

  Widget _buildFileSelectorOverlay(int width, int height) {
    final dialogWidth = (width * 0.7).round().clamp(30, 80);
    final dialogHeight = (height * 0.6).round().clamp(10, 20);

    final listItems = <Widget>[
      if (_savedCasts.isEmpty)
        const Text('  No saved cast files available.')
      else
        for (var i = 0; i < _savedCasts.length; i++)
          Text(
            '${i == _selectedFileIndex ? "➔ " : "  "}${_savedCasts[i]}',
            style: i == _selectedFileIndex
                ? const Style(
                    foreground: CharmColors.pepper,
                    background: CharmColors.charple,
                    modifiers: Modifier.bold,
                  )
                : const Style(foreground: CharmColors.iron),
          ),
    ];

    return Positioned.center(
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
}

final class _PlaybackHeaderBar extends StatefulWidget {
  final AsciicastPlayerViewModel viewModel;

  const _PlaybackHeaderBar({required this.viewModel});

  @override
  State<_PlaybackHeaderBar> createState() => _PlaybackHeaderBarState();
}

final class _PlaybackHeaderBarState extends State<_PlaybackHeaderBar> {
  StreamSubscription<PlaybackState>? _sub;
  String? _activeFilename;
  double _speed = 1.0;
  bool _isLooping = false;

  @override
  void initState() {
    super.initState();
    _syncFromViewModel();
    _sub = playbackStateEvent.on(playerEventBus).listen((state) {
      if (!mounted) return;
      if (_activeFilename != state.activeFilename ||
          _speed != state.speedMultiplier ||
          _isLooping != state.isLooping) {
        setState(() {
          _activeFilename = state.activeFilename;
          _speed = state.speedMultiplier;
          _isLooping = state.isLooping;
        });
      }
    });
  }

  @override
  void didUpdateWidget(_PlaybackHeaderBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.viewModel != oldWidget.viewModel) {
      _syncFromViewModel();
    }
  }

  void _syncFromViewModel() {
    _activeFilename = widget.viewModel.activeFilename;
    _speed = widget.viewModel.speedMultiplier;
    _isLooping = widget.viewModel.isLooping;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const headerStyle = Style(
      foreground: CharmColors.pepper,
      background: CharmColors.charple,
      modifiers: Modifier.bold,
    );
    final activeFile = _activeFilename ?? 'None';
    final headerLeft = ' 📹 TERMUI TUI PLAYER | Active: $activeFile';
    final headerRight =
        'Speed: ${_speed.toStringAsFixed(2)}x  Loop: ${_isLooping ? "ON" : "OFF"} ';

    return Row(
      [
        Flexible(child: Text(headerLeft, style: headerStyle)),
        Text(headerRight, style: headerStyle),
      ],
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      backgroundChar: ' ',
      backgroundStyle: headerStyle,
    );
  }
}

final class _PlaybackScrubberBar extends StatefulWidget {
  final AsciicastPlayerViewModel viewModel;

  const _PlaybackScrubberBar({required this.viewModel});

  @override
  State<_PlaybackScrubberBar> createState() => _PlaybackScrubberBarState();
}

final class _PlaybackScrubberBarState extends State<_PlaybackScrubberBar> {
  StreamSubscription<PlaybackState>? _sub;
  double _currentSec = 0.0;
  double _totalSec = 0.0;
  bool _isPlaying = false;

  @override
  void initState() {
    super.initState();
    _syncFromViewModel();
    _sub = playbackStateEvent.on(playerEventBus).listen((state) {
      if (!mounted) return;
      setState(() {
        _currentSec = state.currentTime;
        _totalSec = state.totalDuration;
        _isPlaying = state.isPlaying;
      });
    });
  }

  @override
  void didUpdateWidget(_PlaybackScrubberBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.viewModel != oldWidget.viewModel) {
      _syncFromViewModel();
    }
  }

  void _syncFromViewModel() {
    _currentSec = widget.viewModel.currentTime;
    _totalSec = widget.viewModel.totalDuration;
    _isPlaying = widget.viewModel.isPlaying;
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const footerStyle = Style(
      foreground: CharmColors.pepper,
      background: CharmColors.soda,
      modifiers: Modifier.bold,
    );
    final sliderVal = _totalSec > 0
        ? (_currentSec / _totalSec).clamp(0.0, 1.0)
        : 0.0;
    final progressText =
        ' ${_isPlaying ? "▶ PLAYING" : "⏸ PAUSED"}  [ ${_formatPlaybackTime(_currentSec)} / ${_formatPlaybackTime(_totalSec)} ]';
    const hintText =
        ' [Space]: Play/Pause  [←/→]: Seek  [O]: Select Cast  [U]: Upload  [Q/Esc]: Exit ';

    return Column([
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
            widget.viewModel.seek(val * _totalSec);
          },
        ),
      ),
      SizedBox(
        height: 1,
        child: Row(
          [
            Text(progressText, style: footerStyle),
            Flexible(child: const Text(hintText, style: footerStyle)),
          ],
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          backgroundChar: ' ',
          backgroundStyle: footerStyle,
        ),
      ),
    ]);
  }
}

extension on String {
  String center(int width) {
    if (width <= 0) return '';
    final chars = Characters(this);
    final charLen = chars.length;
    if (charLen >= width) return chars.take(width).toString();
    final totalPad = width - charLen;
    final leftPad = totalPad ~/ 2;
    final rightPad = totalPad - leftPad;
    return '${" " * leftPad}$this${" " * rightPad}';
  }
}
