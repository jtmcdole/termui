import 'package:flutter_test/flutter_test.dart';
import 'package:fterm/src/automation/automation_models.dart';
import 'package:fterm/src/ui/fterm_overlays.dart';
import 'package:fterm/src/ui/settings/fterm_automation_settings_tab.dart';
import 'package:material_ui/material_ui.dart';

final class _FakeAutomationDriverViewModel extends ChangeNotifier
    implements AutomationDriverViewModel {
  @override
  bool isSupported;

  @override
  bool isRunning;

  @override
  int port;

  @override
  String password;

  @override
  bool allowPty;

  @override
  bool hasEphemeralTokenOverride;

  @override
  String? lastError;

  String? failNextStartWith;
  int regenerateCount = 0;
  final List<int> committedPorts = <int>[];
  final List<bool> enabledCalls = <bool>[];
  final List<bool> allowPtyCalls = <bool>[];

  _FakeAutomationDriverViewModel({
    this.isSupported = true,
    this.isRunning = false,
    this.port = AutomationDriverConfig.defaultPort,
    this.password = 'abcde-fghjk-mnpqr-stuvw',
    this.allowPty = false,
    this.hasEphemeralTokenOverride = false,
    this.lastError,
  });

  @override
  Future<bool> setEnabled(bool enabled) async {
    enabledCalls.add(enabled);
    if (enabled && failNextStartWith != null) {
      lastError = failNextStartWith;
      failNextStartWith = null;
      isRunning = false;
      notifyListeners();
      return false;
    }
    lastError = null;
    isRunning = enabled;
    notifyListeners();
    return isRunning;
  }

  @override
  void setPort(int nextPort) {
    if (!AutomationDriverConfig.isValidPort(nextPort)) {
      throw RangeError.range(
        nextPort,
        AutomationDriverConfig.minPort,
        AutomationDriverConfig.maxPort,
        'port',
      );
    }
    committedPorts.add(nextPort);
    port = nextPort;
    notifyListeners();
  }

  @override
  void setAllowPty(bool nextAllowPty) {
    allowPtyCalls.add(nextAllowPty);
    allowPty = nextAllowPty;
    notifyListeners();
  }

  @override
  String regeneratePassword() {
    regenerateCount++;
    password = 'regen-$regenerateCount-xxxxx-yyyyy';
    notifyListeners();
    return password;
  }

  void setErrorExternally(String? error) {
    lastError = error;
    notifyListeners();
  }
}

const FtermOverlayPalette _testPalette = FtermOverlayPalette(
  surface: Color(0xFF1A1B26),
  surfaceAlt: Color(0xFF24283B),
  foreground: Color(0xFFC0CAF5),
  muted: Color(0xFF8C93B0),
  accent: Color(0xFF7AA2F7),
  border: Color(0xFF3B4261),
  danger: Color(0xFFF7768E),
);

Finder _byKey(String key) => find.byKey(ValueKey(key));

Future<void> _pumpTab(
  WidgetTester tester,
  AutomationDriverViewModel driver, {
  Future<void> Function(String text)? onCopyText,
  bool Function()? isShiftPressed,
}) async {
  await tester.binding.setSurfaceSize(const Size(640, 720));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const .all(16),
          child: FtermAutomationSettingsTab(
            driver: driver,
            palette: _testPalette,
            onCopyText: onCopyText,
            isShiftPressed: isShiftPressed,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('FtermAutomationSettingsTab', () {
    testWidgets('toggles driver on and off and updates live status label', (
      tester,
    ) async {
      final driver = _FakeAutomationDriverViewModel(port: 9911);
      addTearDown(driver.dispose);

      await _pumpTab(tester, driver);

      expect(
        tester.widget<Checkbox>(_byKey('automation-enable-switch')).value,
        isFalse,
      );
      expect(find.text('Listening on 127.0.0.1:9911'), findsNothing);

      await tester.tap(_byKey('automation-enable-switch'));
      await tester.pump();

      expect(driver.enabledCalls, equals(const [true]));
      expect(driver.isRunning, isTrue);
      expect(
        tester.widget<Checkbox>(_byKey('automation-enable-switch')).value,
        isTrue,
      );
      expect(find.text('Listening on 127.0.0.1:9911'), findsOneWidget);

      await tester.tap(_byKey('automation-enable-switch'));
      await tester.pump();

      expect(driver.enabledCalls, equals(const [true, false]));
      expect(driver.isRunning, isFalse);
      expect(find.text('Listening on 127.0.0.1:9911'), findsNothing);
    });

    testWidgets('displays red error banner on bind failure and clears later', (
      tester,
    ) async {
      final driver = _FakeAutomationDriverViewModel()
        ..failNextStartWith = 'Failed to bind 127.0.0.1:9911 (address in use)';
      addTearDown(driver.dispose);

      await _pumpTab(tester, driver);
      expect(_byKey('automation-error-banner'), findsNothing);

      await tester.tap(_byKey('automation-enable-switch'));
      await tester.pump();

      expect(driver.isRunning, isFalse);
      expect(_byKey('automation-error-banner'), findsOneWidget);
      expect(
        find.text('Failed to bind 127.0.0.1:9911 (address in use)'),
        findsOneWidget,
      );

      // Next toggle succeeds and clears the error banner.
      await tester.tap(_byKey('automation-enable-switch'));
      await tester.pump();

      expect(driver.isRunning, isTrue);
      expect(_byKey('automation-error-banner'), findsNothing);
      expect(find.text('Listening on 127.0.0.1:9911'), findsOneWidget);

      // External error notification also surfaces immediately.
      driver.setErrorExternally('Socket closed unexpectedly');
      await tester.pump();
      expect(_byKey('automation-error-banner'), findsOneWidget);
      expect(find.text('Socket closed unexpectedly'), findsOneWidget);
    });

    testWidgets(
      'validates port 1..65535, rejects invalid values, and locks while running',
      (tester) async {
        final driver = _FakeAutomationDriverViewModel(port: 9911);
        addTearDown(driver.dispose);

        await _pumpTab(tester, driver);

        expect(find.text('127.0.0.1 :'), findsOneWidget);
        final portField = _byKey('automation-port-field');
        expect(tester.widget<TextField>(portField).enabled, isTrue);

        for (final invalid in const ['', '0', '-1', '65536', '99999', 'abc']) {
          await tester.enterText(portField, invalid);
          await tester.pump();
          expect(
            _byKey('automation-port-error'),
            findsOneWidget,
            reason: 'Expected validation error for "$invalid"',
          );
          expect(driver.committedPorts, isEmpty);
          expect(driver.port, 9911);
        }

        await tester.enterText(portField, '1');
        await tester.pump();
        expect(_byKey('automation-port-error'), findsNothing);
        expect(driver.port, 1);

        await tester.enterText(portField, '65535');
        await tester.pump();
        expect(_byKey('automation-port-error'), findsNothing);
        expect(driver.port, 65535);

        await tester.enterText(portField, '9922');
        await tester.pump();
        expect(driver.port, 9922);
        expect(driver.committedPorts, equals(const [1, 65535, 9922]));

        // Leave an invalid draft, then start the driver: field locks and snaps
        // back to the bound port while clearing the inline error.
        await tester.enterText(portField, '0');
        await tester.pump();
        expect(_byKey('automation-port-error'), findsOneWidget);

        await tester.tap(_byKey('automation-enable-switch'));
        await tester.pump();

        expect(driver.isRunning, isTrue);
        final lockedField = tester.widget<TextField>(portField);
        expect(lockedField.enabled, isFalse);
        expect(lockedField.controller?.text, '9922');
        expect(_byKey('automation-port-error'), findsNothing);
        expect(find.text('Listening on 127.0.0.1:9922'), findsOneWidget);
      },
    );

    testWidgets(
      'masks password by default and toggles visibility on icon click',
      (tester) async {
        final driver = _FakeAutomationDriverViewModel(
          password: 'alpha-bravo-charl-delta',
        );
        addTearDown(driver.dispose);

        await _pumpTab(tester, driver);

        final fieldFinder = _byKey('automation-password-field');
        final initialField = tester.widget<TextField>(fieldFinder);
        expect(initialField.readOnly, isTrue);
        expect(initialField.obscureText, isTrue);
        expect(initialField.controller?.text, 'alpha-bravo-charl-delta');

        await tester.tap(_byKey('automation-password-visibility-btn'));
        await tester.pump();
        expect(tester.widget<TextField>(fieldFinder).obscureText, isFalse);

        await tester.tap(_byKey('automation-password-visibility-btn'));
        await tester.pump();
        expect(tester.widget<TextField>(fieldFinder).obscureText, isTrue);
      },
    );

    testWidgets(
      'copies raw password on click and URL + header on Shift+click',
      (tester) async {
        final driver = _FakeAutomationDriverViewModel(
          port: 9944,
          password: 'token-12345-abcde-67890',
        );
        addTearDown(driver.dispose);

        final copied = <String>[];
        var shiftHeld = false;

        await _pumpTab(
          tester,
          driver,
          onCopyText: (text) async => copied.add(text),
          isShiftPressed: () => shiftHeld,
        );

        await tester.tap(_byKey('automation-password-copy-btn'));
        await tester.pump();

        expect(copied, equals(const ['token-12345-abcde-67890']));
        expect(_byKey('automation-password-feedback'), findsOneWidget);
        expect(find.text('Password copied to clipboard.'), findsOneWidget);

        shiftHeld = true;
        await tester.tap(_byKey('automation-password-copy-btn'));
        await tester.pump();

        expect(
          copied.last,
          equals(
            'http://127.0.0.1:9944\n'
            'Authorization: Bearer token-12345-abcde-67890',
          ),
        );
        expect(
          find.text('Copied URL and Authorization header.'),
          findsOneWidget,
        );

        // Confirmation clears after the brief feedback timer elapses.
        await tester.pump(const Duration(seconds: 2));
        expect(_byKey('automation-password-feedback'), findsNothing);
      },
    );

    testWidgets(
      'regenerates password with confirmation and disables when env override active',
      (tester) async {
        final driver = _FakeAutomationDriverViewModel(
          password: 'first-token-11111-22222',
        );
        addTearDown(driver.dispose);

        await _pumpTab(tester, driver);

        final regenBtn = _byKey('automation-password-regen-btn');
        expect(tester.widget<IconButton>(regenBtn).onPressed, isNotNull);

        await tester.tap(regenBtn);
        await tester.pump();

        expect(driver.regenerateCount, 1);
        expect(
          tester
              .widget<TextField>(_byKey('automation-password-field'))
              .controller
              ?.text,
          'regen-1-xxxxx-yyyyy',
        );
        expect(find.text('Password regenerated.'), findsOneWidget);

        // Drain the feedback timer cleanly before switching to env-override test.
        await tester.pump(const Duration(seconds: 2));
        expect(_byKey('automation-password-feedback'), findsNothing);

        final overriddenDriver = _FakeAutomationDriverViewModel(
          password: 'env-override-token',
          hasEphemeralTokenOverride: true,
        );
        addTearDown(overriddenDriver.dispose);

        await _pumpTab(tester, overriddenDriver);

        final disabledButton = tester.widget<IconButton>(regenBtn);
        expect(disabledButton.onPressed, isNull);
        expect(disabledButton.tooltip, contains('FTERM_AUTOMATION_TOKEN'));
        expect(_byKey('automation-ephemeral-token-hint'), findsOneWidget);

        await tester.tap(regenBtn);
        await tester.pump();
        expect(overriddenDriver.regenerateCount, 0);
      },
    );

    testWidgets(
      'toggles Allow PTY checkbox and renders amber warning caption',
      (tester) async {
        final driver = _FakeAutomationDriverViewModel();
        addTearDown(driver.dispose);

        await _pumpTab(tester, driver);

        final checkboxFinder = _byKey('automation-allow-pty-checkbox');
        expect(tester.widget<Checkbox>(checkboxFinder).value, isFalse);
        expect(_byKey('automation-pty-warning'), findsOneWidget);

        await tester.tap(checkboxFinder);
        await tester.pump();

        expect(driver.allowPty, isTrue);
        expect(driver.allowPtyCalls, equals(const [true]));
        expect(tester.widget<Checkbox>(checkboxFinder).value, isTrue);

        await tester.tap(checkboxFinder);
        await tester.pump();

        expect(driver.allowPty, isFalse);
        expect(driver.allowPtyCalls, equals(const [true, false]));
      },
    );

    testWidgets('disables controls when driver is unsupported', (tester) async {
      final driver = _FakeAutomationDriverViewModel(isSupported: false);
      addTearDown(driver.dispose);

      await _pumpTab(tester, driver);

      expect(
        tester.widget<Checkbox>(_byKey('automation-enable-switch')).onChanged,
        isNull,
      );
      expect(
        tester.widget<TextField>(_byKey('automation-port-field')).enabled,
        isFalse,
      );
      expect(
        tester
            .widget<IconButton>(_byKey('automation-password-regen-btn'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<Checkbox>(_byKey('automation-allow-pty-checkbox'))
            .onChanged,
        isNull,
      );
    });

    testWidgets(
      'reflects pre-running state, initial error, and external driver updates',
      (tester) async {
        final driver = _FakeAutomationDriverViewModel(
          isRunning: true,
          port: 8123,
          allowPty: true,
          lastError: 'Previous warning',
        );
        addTearDown(driver.dispose);

        await _pumpTab(tester, driver);

        expect(
          tester.widget<Checkbox>(_byKey('automation-enable-switch')).value,
          isTrue,
        );
        expect(find.text('Listening on 127.0.0.1:8123'), findsOneWidget);
        expect(
          tester.widget<TextField>(_byKey('automation-port-field')).enabled,
          isFalse,
        );
        expect(
          tester
              .widget<Checkbox>(_byKey('automation-allow-pty-checkbox'))
              .value,
          isTrue,
        );
        expect(_byKey('automation-error-banner'), findsOneWidget);
        expect(find.text('Previous warning'), findsOneWidget);

        // Stop externally and change port externally; port field syncs cleanly.
        await driver.setEnabled(false);
        driver.setPort(8456);
        await tester.pump();

        final portField = tester.widget<TextField>(
          _byKey('automation-port-field'),
        );
        expect(portField.enabled, isTrue);
        expect(portField.controller?.text, '8456');
        expect(_byKey('automation-error-banner'), findsNothing);
      },
    );
  });
}
