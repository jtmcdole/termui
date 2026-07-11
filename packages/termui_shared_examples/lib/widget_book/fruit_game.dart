import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui/ui/event.dart' as ui;
import 'example_base.dart';

/// The game state machine transitions.
enum GameState {
  /// User is playing and dropping fruits.
  playing,

  /// Matches are exploding.
  exploding,

  /// Game has ended due to layout overflow.
  gameOver,
}

/// Represents an emoji fruit currently in free-fall.
class FallingEmoji {
  /// The emoji character representation.
  final String emoji;

  /// The horizontal grid column index.
  final int col;

  /// The vertical float coordinate.
  double y;

  /// Creates a [FallingEmoji].
  FallingEmoji({required this.emoji, required this.col, required this.y});
}

/// The payload metadata for dragging.
class DraggedFruit {
  /// The emoji being dragged.
  final String emoji;

  /// The source fruit selection slot index.
  final int slotIndex;

  /// Creates a [DraggedFruit].
  DraggedFruit(this.emoji, this.slotIndex);
}

/// A custom bordered box widget that renders a title centered on the top border.
class BorderWidget extends Widget {
  /// The title text to display on the top border line.
  final String title;

  /// The style configuration of the border characters.
  final Style style;

  /// The nested child widget.
  final Widget child;

  /// Creates a [BorderWidget].
  const BorderWidget({
    required this.title,
    required this.style,
    required this.child,
    super.key,
  });

  @override
  Element createElement() => BorderWidgetElement(this);
}

/// Backing element for [BorderWidget].
class BorderWidgetElement extends SingleChildElement {
  /// Creates a [BorderWidgetElement].
  BorderWidgetElement(BorderWidget super.widget);

  @override
  Widget? get childWidget => (widget as BorderWidget).child;

  @override
  Size performLayout(BoxConstraints constraints) {
    if (childElement != null) {
      final childConstraints = BoxConstraints(
        minWidth: max(0, constraints.minWidth - 2),
        maxWidth: constraints.maxWidth == BoxConstraints.infinity
            ? BoxConstraints.infinity
            : max(0, constraints.maxWidth - 2),
        minHeight: max(0, constraints.minHeight - 2),
        maxHeight: constraints.maxHeight == BoxConstraints.infinity
            ? BoxConstraints.infinity
            : max(0, constraints.maxHeight - 2),
      );
      final childSize = childElement!.layout(childConstraints);
      childElement!.relativeOffset = const Offset(1, 1);
      return constraints.constrain(
        Size(childSize.width + 2, childSize.height + 2),
      );
    }
    return constraints.constrain(const Size(2, 2));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as BorderWidget;
    final width = size.width;
    final height = size.height;

    final fg = w.style.foreground?.argb;
    final bg = w.style.background?.argb;
    final modifiers = w.style.modifiers;

    final x0 = offset.dx.toInt();
    final y0 = offset.dy.toInt();
    final x1 = x0 + width - 1;
    final y1 = y0 + height - 1;

    // Horizontal lines
    for (var x = x0 + 1; x < x1; x++) {
      buffer.setAttributes(
        x,
        y0,
        char: '─',
        fg: fg,
        bg: bg,
        modifiers: modifiers,
      );
      buffer.setAttributes(
        x,
        y1,
        char: '─',
        fg: fg,
        bg: bg,
        modifiers: modifiers,
      );
    }
    // Vertical lines
    for (var y = y0 + 1; y < y1; y++) {
      buffer.setAttributes(
        x0,
        y,
        char: '│',
        fg: fg,
        bg: bg,
        modifiers: modifiers,
      );
      buffer.setAttributes(
        x1,
        y,
        char: '│',
        fg: fg,
        bg: bg,
        modifiers: modifiers,
      );
    }
    // Corners
    buffer.setAttributes(
      x0,
      y0,
      char: '┌',
      fg: fg,
      bg: bg,
      modifiers: modifiers,
    );
    buffer.setAttributes(
      x1,
      y0,
      char: '┐',
      fg: fg,
      bg: bg,
      modifiers: modifiers,
    );
    buffer.setAttributes(
      x0,
      y1,
      char: '└',
      fg: fg,
      bg: bg,
      modifiers: modifiers,
    );
    buffer.setAttributes(
      x1,
      y1,
      char: '┘',
      fg: fg,
      bg: bg,
      modifiers: modifiers,
    );

    // Draw title
    if (w.title.isNotEmpty) {
      final titleText = ' ${w.title} ';
      final startX = x0 + ((width - titleText.length) ~/ 2).clamp(1, width - 1);
      for (var i = 0; i < titleText.length; i++) {
        if (startX + i < x1) {
          buffer.setAttributes(
            startX + i,
            y0,
            char: titleText[i],
            fg: fg,
            bg: bg,
            modifiers: modifiers,
          );
        }
      }
    }

    if (childElement != null) {
      childElement!.paint(buffer, offset + childElement!.relativeOffset);
    }
  }
}

/// A fully productionized puzzle game demonstrating Draggable, DragTarget,
/// subpixel ripples, custom rendering performance, and TUI game loops.
class FruitGameExample extends WidgetBookExample {
  /// The library of fruit emojis available in the game.
  static const List<String> fruits = [
    '🍇',
    '🍈',
    '🍉',
    '🍊',
    '🍋',
    '🍌',
    '🍍',
    '🍎',
    '🍑',
    '🍒',
    '🥥',
    '🍓',
  ];

  final Random _random = Random();

  /// 17 columns (each taking 2 terminal cells), 13 rows.
  late List<List<String?>> grid;

  /// Emojis currently falling.
  late List<FallingEmoji> falling;

  /// The active fruit selection slots.
  late List<String> currentSlots;

  /// The active game score.
  int score = 0;

  /// The current state of the game.
  GameState gameState = GameState.playing;

  /// Milliseconds remaining for the current explosion animation phase.
  int explosionTimerMs = 0;

  /// The localized subpixel ripple manager.
  final SubpixelRippleManager rippleManager = SubpixelRippleManager();

  /// Observable hover columns and rows for MVVM drag target previews.
  int? dragHoverCol;

  /// Observable hover landing row index for MVVM drag target previews.
  int? dragHoverTargetRow;

  /// Observable fruit emoji currently being hovered/dragged.
  String? dragHoverEmoji;

  @override
  void init() {
    resetGame();
  }

  /// Resets the game board and variables.
  void resetGame() {
    grid = List.generate(13, (_) => List.filled(17, null));
    falling = [];
    currentSlots = List.generate(3, (_) => _randomFruit());
    score = 0;
    gameState = GameState.playing;
    explosionTimerMs = 0;
    dragHoverCol = null;
    dragHoverTargetRow = null;
    dragHoverEmoji = null;
  }

  String _randomFruit() {
    return fruits[_random.nextInt(fruits.length)];
  }

  /// Translates screen-absolute mouse positions to local grid columns and target rows.
  void updateDragHover(DragSession? session, Offset offset) {
    if (session == null ||
        session.data is! DraggedFruit ||
        gameState == GameState.gameOver) {
      dragHoverCol = null;
      dragHoverTargetRow = null;
      dragHoverEmoji = null;
      return;
    }

    final dragged = session.data as DraggedFruit;
    final localX = session.currentMousePosition.x - 1 - offset.dx;
    final col = (localX ~/ 2).clamp(0, 16);

    var targetRow = 12;
    while (targetRow >= 0 && grid[targetRow][col] != null) {
      targetRow--;
    }

    dragHoverCol = col;
    dragHoverTargetRow = targetRow >= 0 ? targetRow : null;
    dragHoverEmoji = dragged.emoji;
  }

  @override
  bool get requiresTick => true;

  @override
  bool tick(Duration duration) {
    final elapsedMs = duration.inMilliseconds;
    var changed = false;

    if (DragDropManager.activeSession != null) {
      changed = true;
    }

    if (rippleManager.hasActiveRipples) {
      rippleManager.updateRipples();
      changed = true;
    }

    if (gameState == GameState.exploding) {
      explosionTimerMs -= elapsedMs;
      changed = true;
      if (explosionTimerMs <= 0) {
        _applyGravity();
        gameState = GameState.playing;
        _checkAndResolveMatches();
      }
    }

    if (falling.isNotEmpty) {
      changed = true;
      final toRemove = <FallingEmoji>[];
      var settledAny = false;
      for (final f in falling) {
        final oldRow = f.y.toInt();
        f.y += elapsedMs * 0.03; // Falls 1 row every ~33ms
        final newRow = f.y.toInt();

        if (newRow >= 13 || grid[newRow][f.col] != null) {
          final settleRow = oldRow.clamp(0, 12);
          grid[settleRow][f.col] = f.emoji;
          toRemove.add(f);
          settledAny = true;
        }
      }
      falling.removeWhere(toRemove.contains);
      if (settledAny) {
        _checkAndResolveMatches();
      }
    }

    return changed;
  }

  void _checkAndResolveMatches() {
    final matched = List.generate(13, (_) => List.filled(17, false));
    final visited = List.generate(13, (_) => List.filled(17, false));
    var maxDelayMs = 0;
    final now = DateTime.now().millisecondsSinceEpoch;
    var hasMatches = false;

    for (var r = 0; r < 13; r++) {
      for (var c = 0; c < 17; c++) {
        final emoji = grid[r][c];
        if (emoji != null && emoji != '💥' && !visited[r][c]) {
          final component = <Point<int>>[];
          final queue = <Point<int>>[Point<int>(c, r)];
          visited[r][c] = true;

          while (queue.isNotEmpty) {
            final p = queue.removeLast();
            component.add(p);

            final neighbors = [
              Point<int>(p.x + 1, p.y),
              Point<int>(p.x - 1, p.y),
              Point<int>(p.x, p.y + 1),
              Point<int>(p.x, p.y - 1),
            ];

            for (final n in neighbors) {
              if (n.x >= 0 && n.x < 17 && n.y >= 0 && n.y < 13) {
                if (!visited[n.y][n.x] && grid[n.y][n.x] == emoji) {
                  visited[n.y][n.x] = true;
                  queue.add(n);
                }
              }
            }
          }

          if (component.length >= 3) {
            hasMatches = true;
            for (var i = 0; i < component.length; i++) {
              final p = component[i];
              matched[p.y][p.x] = true;
              final delayMs = i * 250; // quarter second stagger per element
              if (delayMs > maxDelayMs) {
                maxDelayMs = delayMs;
              }
              rippleManager.addRipple(
                Point<int>(p.x * 2 + 1, p.y + 1),
                color: Colors.red,
                durationMs: 500,
                startTime: now + delayMs,
              );
            }
          }
        }
      }
    }

    if (hasMatches) {
      var matchCount = 0;
      for (var r = 0; r < 13; r++) {
        for (var c = 0; c < 17; c++) {
          if (matched[r][c]) {
            grid[r][c] = '💥';
            matchCount++;
          }
        }
      }
      score += matchCount;
      gameState = GameState.exploding;
      // Staggered ripples run for 500ms after they start. The last ripple starts at maxDelayMs,
      // so the total duration is maxDelayMs + 500ms. We use max() to prevent subsequent
      // matches from curtailing an ongoing longer explosion phase.
      explosionTimerMs = max(explosionTimerMs, maxDelayMs + 500);
    }

    // Check game over
    for (var c = 0; c < 17; c++) {
      if (grid[0][c] != null && grid[0][c] != '💥') {
        gameState = GameState.gameOver;
      }
    }
  }

  void _applyGravity() {
    for (var c = 0; c < 17; c++) {
      var read = 12;
      var write = 12;
      while (read >= 0) {
        if (grid[read][c] != null && grid[read][c] != '💥') {
          grid[write][c] = grid[read][c];
          if (read != write) {
            grid[read][c] = null;
          }
          write--;
        } else if (grid[read][c] == '💥') {
          grid[read][c] = null;
        }
        read--;
      }
    }
  }

  /// Triggers drop logic.
  void handleDrop(
    DraggedFruit dragged,
    Offset targetAbsoluteOffset,
    Point<int> mousePos,
  ) {
    if (gameState == GameState.gameOver) return;

    // Convert mouse position to local coordinate
    final localX = mousePos.x - 1 - targetAbsoluteOffset.dx.toInt();
    final col = (localX ~/ 2).clamp(0, 16);

    // Spawn falling emoji
    falling.add(FallingEmoji(emoji: dragged.emoji, col: col, y: 0.0));

    // Replace the slot in fruit box
    currentSlots[dragged.slotIndex] = _randomFruit();
  }

  @override
  Widget build({
    required bool focusDemoPane,
    required int width,
    required int height,
  }) {
    return _FruitGameWidget(example: this);
  }

  @override
  bool get hasActiveOverlay => DragDropManager.activeSession != null;

  @override
  void renderOverlay(Buffer buffer, int width, int height) {
    final session = DragDropManager.activeSession;
    if (session != null && session.data is DraggedFruit) {
      final dragged = session.data as DraggedFruit;
      final x = session.currentMousePosition.x - 1;
      final y = session.currentMousePosition.y - 1;
      if (x >= 0 && x < width && y >= 0 && y < height) {
        buffer.writeString(
          x,
          y,
          dragged.emoji,
          const Style(modifiers: Modifier.bold),
        );
      }
    }
  }

  @override
  bool handleKeyEvent(ui.KeyEvent event) {
    if (event.key == 'r' || event.key == 'R') {
      resetGame();
      return true;
    }
    return false;
  }

  @override
  Map<String, String> get helpBindings => {'R': 'Reset Fruit Game'};
}

class _FruitGameWidget extends StatefulWidget {
  final FruitGameExample example;

  const _FruitGameWidget({required this.example});

  @override
  State<_FruitGameWidget> createState() => _FruitGameWidgetState();
}

class _FruitGameWidgetState extends State<_FruitGameWidget> {
  final GlobalKey _gridKey = GlobalKey();

  Offset _findAbsoluteOffset(BuildContext context) {
    var offset = Offset.zero;
    final element = context as Element?;
    if (element != null) {
      offset += element.relativeOffset;
      var parent = element.parent;
      while (parent != null) {
        offset += parent.relativeOffset;
        parent = parent.parent;
      }
    }
    return offset;
  }

  @override
  Widget build(BuildContext context) {
    final ex = widget.example;

    if (ex.gameState == GameState.gameOver) {
      return Center(
        child: Column([
          const SizedBox(
            height: 1,
            child: Text(
              '💥 GAME OVER 💥',
              style: Style(foreground: Colors.red, modifiers: Modifier.bold),
            ),
          ),
          const SizedBox(height: 1),
          SizedBox(
            height: 1,
            child: Text(
              'Final Score: ${ex.score}',
              style: const Style(foreground: Colors.green),
            ),
          ),
          const SizedBox(height: 1),
          const SizedBox(height: 1, child: Text('Press [R] to Restart')),
        ]),
      );
    }

    return Column([
      // Fruit Selection Box
      Center(
        child: SizedBox(
          width: 32,
          height: 3,
          child: BorderWidget(
            title: 'emoji fruit',
            style: const Style(foreground: Colors.blue),
            child: Center(
              child: Row([
                for (var i = 0; i < 3; i++)
                  Draggable<DraggedFruit>(
                    data: DraggedFruit(ex.currentSlots[i], i),
                    child: SizedBox(
                      width: 6,
                      height: 1,
                      child: Text(' [ ${ex.currentSlots[i]} ] '),
                    ),
                  ),
              ], mainAxisAlignment: MainAxisAlignment.spaceEvenly),
            ),
          ),
        ),
      ),
      const SizedBox(height: 1),
      // Score Label
      Center(
        child: SizedBox(
          height: 1,
          child: Text(
            '[ SCORE: ${ex.score} ]',
            style: const Style(
              foreground: Colors.yellow,
              modifiers: Modifier.bold,
            ),
          ),
        ),
      ),
      const SizedBox(height: 1),
      // Collection Bin / Playfield
      Center(
        child: SizedBox(
          width: 36,
          height: 15,
          child: DragTarget<DraggedFruit>(
            onAccept: (dragged) {
              final gridContext = _gridKey.currentContext;
              if (gridContext != null) {
                final absOffset = _findAbsoluteOffset(gridContext);
                final session = DragDropManager.activeSession;
                if (session != null) {
                  ex.handleDrop(
                    dragged,
                    absOffset,
                    session.currentMousePosition,
                  );
                  setState(() {});
                }
              }
            },
            builder: (context, candidate, rejected) {
              final isHovered = candidate.isNotEmpty;
              return BorderWidget(
                title: isHovered ? 'ready to drop!' : 'drop emojis here',
                style: Style(
                  foreground: isHovered ? Colors.green : Colors.white,
                ),
                child: Center(
                  child: Stack([
                    FruitGameGridWidget(
                      key: _gridKey,
                      example: ex,
                      grid: ex.grid,
                      falling: ex.falling,
                    ),
                    SubpixelRippleWidget(manager: ex.rippleManager),
                  ]),
                ),
              );
            },
          ),
        ),
      ),
    ]);
  }
}

/// A performant custom rendering widget for the game grid.
class FruitGameGridWidget extends Widget {
  /// The game example.
  final FruitGameExample example;

  /// The game board.
  final List<List<String?>> grid;

  /// The active falling emojis.
  final List<FallingEmoji> falling;

  /// Creates a [FruitGameGridWidget].
  const FruitGameGridWidget({
    super.key,
    required this.example,
    required this.grid,
    required this.falling,
  });

  @override
  Element createElement() => FruitGameGridWidgetElement(this);
}

/// The element that draws the game board without standard widget reconciliation overhead.
class FruitGameGridWidgetElement extends Element {
  /// Creates a [FruitGameGridWidgetElement].
  FruitGameGridWidgetElement(FruitGameGridWidget super.widget);

  @override
  Size performLayout(BoxConstraints constraints) {
    return constraints.constrain(const Size(34, 13));
  }

  @override
  void performPaint(Buffer buffer, Offset offset) {
    final w = widget as FruitGameGridWidget;

    // Fill playfield background with blanks (Issue C - optimized row batch clearing)
    final blankRow = ' ' * 34;
    for (var y = 0; y < 13; y++) {
      buffer.writeString(
        offset.dx.toInt(),
        offset.dy.toInt() + y,
        blankRow,
        Style.empty,
      );
    }

    // Paint settled emojis
    for (var r = 0; r < 13; r++) {
      for (var c = 0; c < 17; c++) {
        final emoji = w.grid[r][c];
        if (emoji != null) {
          var style = Style.empty;
          if (emoji == '💥') {
            final isRed = (w.example.explosionTimerMs ~/ 100) % 2 == 0;
            style = Style(
              background: isRed ? Colors.red : Colors.white,
              foreground: isRed ? Colors.white : Colors.black,
            );
          }
          buffer.writeString(
            offset.dx.toInt() + c * 2,
            offset.dy.toInt() + r,
            emoji,
            style,
          );
        }
      }
    }

    // Update and draw guide column and landing cell preview (Issue A - MVVM bounds)
    w.example.updateDragHover(DragDropManager.activeSession, offset);
    final hoverCol = w.example.dragHoverCol;
    final hoverRow = w.example.dragHoverTargetRow;
    final hoverEmoji = w.example.dragHoverEmoji;

    if (hoverCol != null && hoverRow != null && hoverEmoji != null) {
      for (var r = 0; r < hoverRow; r++) {
        if (w.grid[r][hoverCol] == null) {
          final drawX = offset.dx.toInt() + hoverCol * 2;
          final drawY = offset.dy.toInt() + r;
          buffer.setAttributes(drawX, drawY, bg: CharmColors.bbq.argb);
          buffer.setAttributes(drawX + 1, drawY, bg: CharmColors.bbq.argb);
        }
      }

      final landingX = offset.dx.toInt() + hoverCol * 2;
      final landingY = offset.dy.toInt() + hoverRow;
      buffer.setAttributes(landingX, landingY, bg: CharmColors.char.argb);
      buffer.setAttributes(landingX + 1, landingY, bg: CharmColors.char.argb);
      buffer.writeString(
        landingX,
        landingY,
        hoverEmoji,
        const Style(modifiers: Modifier.dim),
      );
    }

    // Paint falling emojis
    for (final f in w.falling) {
      final r = f.y.toInt();
      if (r >= 0 && r < 13) {
        buffer.writeString(
          offset.dx.toInt() + f.col * 2,
          offset.dy.toInt() + r,
          f.emoji,
          Style.empty,
        );
      }
    }
  }
}
