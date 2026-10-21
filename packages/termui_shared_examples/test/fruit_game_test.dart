import 'dart:math';
import 'package:termui/termui.dart';
import 'package:termui_shared_examples/widget_book/fruit_game.dart';
import 'package:test/test.dart';

void main() {
  group('Fruit Game Logic Tests', () {
    late FruitGameExample game;

    setUp(() {
      game = FruitGameExample()..init();
    });

    test('resetGame initializes board and slots correctly', () {
      expect(game.score, equals(0));
      expect(game.gameState, equals(GameState.playing));
      expect(game.currentSlots.length, equals(3));

      for (var r = 0; r < 13; r++) {
        for (var c = 0; c < 17; c++) {
          expect(game.grid[r][c], isNull);
        }
      }
    });

    test('Emoji settling and gravity matches horizontal runs', () {
      // Setup horizontal run of 3 '🍇' at the bottom row (row 12)
      game.grid[12][0] = '🍇';
      game.grid[12][1] = '🍇';

      // Let's drop a 3rd '🍇' at column 2
      // targetAbsoluteOffset = Offset.zero, mouse pos x = 5 -> col = (5 - 1 - 0) ~/ 2 = 2
      game.handleDrop(
        DraggedFruit('🍇', 0),
        Offset.zero,
        const Point<int>(5, 1),
      );
      expect(game.falling.length, equals(1));
      expect(game.falling.first.col, equals(2));

      // Advance ticks to let it settle
      var ticks = 0;
      while (game.falling.isNotEmpty && ticks < 100) {
        game.tick(const Duration(milliseconds: 16));
        ticks++;
      }

      // Settle triggers match, explosions ('💥') and state transition
      expect(game.gameState, equals(GameState.exploding));
      expect(game.grid[12][0], equals('💥'));
      expect(game.grid[12][1], equals('💥'));
      expect(game.grid[12][2], equals('💥'));

      // Tick to resolve explosion phase (1000ms duration)
      game.tick(const Duration(milliseconds: 1000));
      expect(game.grid[12][0], isNull);
      expect(game.grid[12][1], isNull);
      expect(game.grid[12][2], isNull);
      expect(game.score, equals(3));
    });

    test('Emoji settling and gravity matches vertical runs', () {
      game.grid[12][0] = '🍊';
      game.grid[11][0] = '🍊';

      game.handleDrop(
        DraggedFruit('🍊', 0),
        Offset.zero,
        const Point<int>(1, 1),
      );
      expect(game.falling.length, equals(1));

      var ticks = 0;
      while (game.falling.isNotEmpty && ticks < 100) {
        game.tick(const Duration(milliseconds: 16));
        ticks++;
      }

      expect(game.gameState, equals(GameState.exploding));
      expect(game.grid[12][0], equals('💥'));
      expect(game.grid[11][0], equals('💥'));
      expect(game.grid[10][0], equals('💥'));

      game.tick(const Duration(milliseconds: 1000));
      expect(game.grid[12][0], isNull);
      expect(game.score, equals(3));
    });

    test('Top row overflow triggers game over state', () {
      for (var r = 1; r < 13; r++) {
        game.grid[r][5] = r % 2 == 0 ? '🍇' : '🍉';
      }
      expect(game.gameState, equals(GameState.playing));

      game.handleDrop(
        DraggedFruit('🍊', 0),
        Offset.zero,
        const Point<int>(11, 1),
      );

      var ticks = 0;
      while (game.falling.isNotEmpty && ticks < 100) {
        game.tick(const Duration(milliseconds: 16));
        ticks++;
      }

      expect(game.gameState, equals(GameState.gameOver));
    });

    test('Orthogonally connected L-shape of 3 emoji matches and explodes', () {
      // Setup:
      // Row 11: 🍌
      // Row 12: 🍌 🍌
      game.grid[12][0] = '🍌';
      game.grid[12][1] = '🍌';

      game.handleDrop(
        DraggedFruit('🍌', 0),
        Offset.zero,
        const Point<int>(1, 1),
      ); // drop at col 0
      expect(game.falling.length, equals(1));

      var ticks = 0;
      while (game.falling.isNotEmpty && ticks < 100) {
        game.tick(const Duration(milliseconds: 16));
        ticks++;
      }

      // Settle triggers match, explosions ('💥') and state transition for L-shape
      expect(game.gameState, equals(GameState.exploding));
      expect(game.grid[12][0], equals('💥'));
      expect(game.grid[12][1], equals('💥'));
      expect(game.grid[11][0], equals('💥'));

      game.tick(const Duration(milliseconds: 1000));
      expect(game.grid[12][0], isNull);
      expect(game.grid[12][1], isNull);
      expect(game.grid[11][0], isNull);
      expect(game.score, equals(3));
    });

    test('Gravity shifts cause recursive cascades', () {
      game.grid[12][1] = '🍇';
      game.grid[12][2] = '🍇';

      game.grid[11][1] = '🍉'; // will fall to (12, 1)
      game.grid[11][2] = '🍉'; // will fall to (12, 2)

      game.grid[12][3] = '🍉';

      // Drop '🍇' at column 0 (mouse pos x = 1 -> col = 0)
      game.handleDrop(
        DraggedFruit('🍇', 0),
        Offset.zero,
        const Point<int>(1, 1),
      );
      expect(game.falling.length, equals(1));

      // 1st tick cycle: settle and trigger 🍇 match
      var ticks = 0;
      while (game.falling.isNotEmpty && ticks < 100) {
        game.tick(const Duration(milliseconds: 16));
        ticks++;
      }
      expect(game.gameState, equals(GameState.exploding));
      expect(game.grid[12][0], equals('💥'));
      expect(game.grid[12][1], equals('💥'));
      expect(game.grid[12][2], equals('💥'));

      expect(game.grid[11][1], equals('🍉'));
      expect(game.grid[11][2], equals('🍉'));
      expect(game.score, equals(3));
      // Tick to finish the 🍇 explosion (1000ms)
      game.tick(const Duration(milliseconds: 1000));
      expect(
        game.gameState,
        equals(GameState.exploding),
      ); // Still exploding because of 🍉!
      expect(game.grid[12][1], equals('💥'));
      expect(game.grid[12][2], equals('💥'));
      expect(game.grid[12][3], equals('💥'));
      expect(game.score, equals(6));

      // Tick to finish the 🍉 explosion (1000ms)
      game.tick(const Duration(milliseconds: 1000));
      expect(game.gameState, equals(GameState.playing));
      expect(game.grid[12][1], isNull);
      expect(game.grid[12][2], isNull);
      expect(game.grid[12][3], isNull);
    });
  });
}
