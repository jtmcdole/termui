import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, VoidCallback;

import '../settings_storage.dart';
import 'update_service.dart';

/// Factory signature for scheduling cancellable one-shot timers (injectable in
/// tests so zero timers leak).
typedef UpdateTimerFactory = Timer Function(
  Duration duration,
  VoidCallback callback,
);

/// MVVM ViewModel coordinating `fterm` release checks, archive staging,
/// download progress, and restart/apply-on-quit actions.
///
/// Separates fine-grained download progress notifications ([notifyListeners])
/// from coarse chrome/pill transitions (`onCoarseStateChanged`) so streaming a
/// 20 MB archive never rebuilds the workspace scaffold on every chunk.
final class UpdateViewModel extends ChangeNotifier {
  /// Delay after workspace start before running an automatic `daily` check.
  static const Duration startupDailyCheckDelay = Duration(seconds: 10);

  /// Minimum interval between automatic `daily` checks.
  static const Duration dailyCheckInterval = Duration(hours: 24);

  final UpdateService _service;
  final FtermPreferences Function() _readPreferences;
  final void Function(FtermPreferences next) _writePreferences;
  final Future<void> Function()? _beforeExitTeardown;
  final List<String> _relaunchArgs;
  final VoidCallback? _onCoarseStateChanged;
  final Clock _clock;
  final UpdateTimerFactory _timerFactory;

  UpdateStatus _status = UpdateStatus.idle;
  AvailableUpdate? _availableUpdate;
  StagedUpdate? _stagedUpdate;
  DownloadProgress? _downloadProgress;
  String? _statusMessage;
  String? _errorMessage;
  bool _applyOnQuit = false;
  bool _disposed = false;
  bool _started = false;
  bool _busyApplying = false;
  Timer? _startupCheckTimer;

  /// Creates an [UpdateViewModel].
  UpdateViewModel({
    required this._service,
    required this._readPreferences,
    required this._writePreferences,
    this._beforeExitTeardown,
    List<String> relaunchArgs = const [],
    this._onCoarseStateChanged,
    Clock? clock,
    UpdateTimerFactory? timerFactory,
  }) : _relaunchArgs = relaunchArgs.isEmpty
           ? const []
           : List<String>.unmodifiable(relaunchArgs),
       _clock = clock ?? const Clock(),
       _timerFactory = timerFactory ?? Timer.new;

  /// Running semantic version (`kFtermBuildVersion`).
  FtermSemVer get currentVersion => _service.currentVersion;

  /// Self-update capability of this installation.
  SelfUpdateCapability get capability => _service.capability;

  /// Whether this host supports showing the desktop Updates settings section.
  bool get isSupportedDesktop =>
      capability != SelfUpdateCapability.unsupportedWeb;

  /// Whether this installation can download and swap updates in place.
  bool get canStageInPlace =>
      capability == SelfUpdateCapability.supported ||
      capability == SelfUpdateCapability.macosAppManagementDenied;

  /// Current coarse lifecycle state.
  UpdateStatus get status => _status;

  /// Available release metadata when [status] is `available`, `downloading`,
  /// `readyToRestart`, or `error` (during staging/swap).
  AvailableUpdate? get availableUpdate => _availableUpdate;

  /// Staged payload handle when [status] is `readyToRestart` (or TCC denied).
  StagedUpdate? get stagedUpdate => _stagedUpdate;

  /// Current download byte progress when [status] is `downloading`.
  DownloadProgress? get downloadProgress => _downloadProgress;

  /// Informational status label (e.g. `'Up to date (v0.2.2)'`).
  String? get statusMessage => _statusMessage;

  /// Latest failure explanation when [status] is `error`.
  String? get errorMessage => _errorMessage;

  /// Whether a staged update should be applied automatically when quitting.
  bool get applyOnQuit => _applyOnQuit;

  /// Whether an update badge dot or corner pill token should be displayed.
  bool get hasActionableUpdate =>
      _status == UpdateStatus.available ||
      _status == UpdateStatus.readyToRestart;

  /// Corner pill label (`'UPDATE'` or `'RESTART TO UPDATE'`), or `null` when
  /// no actionable update is pending.
  String? get cornerPillLabel => switch (_status) {
    UpdateStatus.readyToRestart => 'RESTART TO UPDATE',
    UpdateStatus.available => 'UPDATE',
    _ => null,
  };

  /// Arms automatic `daily` cadence after startup (waiting 10 seconds).
  void start() {
    if (_started || _disposed || !isSupportedDesktop) return;
    _started = true;
    _scheduleStartupCheckIfNeeded();
  }

  /// Notifies the ViewModel that update-related preferences changed (such as
  /// toggling `Check daily` or `Include pre-releases`).
  void onPreferencesChanged() {
    if (_disposed || !isSupportedDesktop) return;
    final prefs = _readPreferences();
    if (prefs.updateCheckMode != UpdateCheckMode.daily) {
      _cancelStartupTimer();
    } else if (_started &&
        _startupCheckTimer == null &&
        _isDailyCheckDue(prefs)) {
      _scheduleStartupCheckIfNeeded();
    }
    notifyListeners();
  }

  /// Triggers a background `daily` check when returning to the foreground once
  /// 24 hours have elapsed since `lastUpdateCheckUtc`.
  void onAppResumed() {
    if (_disposed || !isSupportedDesktop) return;
    if (_startupCheckTimer?.isActive ?? false) return;
    final prefs = _readPreferences();
    if (prefs.updateCheckMode == UpdateCheckMode.daily &&
        _isDailyCheckDue(prefs) &&
        _canStartBackgroundCheck) {
      unawaited(checkForUpdates(isBackground: true));
    }
  }

  bool get _canStartBackgroundCheck =>
      _status == UpdateStatus.idle || _status == UpdateStatus.available;

  bool _isDailyCheckDue(FtermPreferences prefs) {
    final last = prefs.lastUpdateCheckUtc;
    if (last == null) return true;
    return _clock.now().toUtc().difference(last.toUtc()) >= dailyCheckInterval;
  }

  void _scheduleStartupCheckIfNeeded() {
    _cancelStartupTimer();
    final prefs = _readPreferences();
    if (prefs.updateCheckMode != UpdateCheckMode.daily ||
        !_isDailyCheckDue(prefs)) {
      return;
    }
    _startupCheckTimer = _timerFactory(startupDailyCheckDelay, () {
      _startupCheckTimer = null;
      if (_disposed) return;
      final latest = _readPreferences();
      if (latest.updateCheckMode == UpdateCheckMode.daily &&
          _isDailyCheckDue(latest) &&
          _canStartBackgroundCheck) {
        unawaited(checkForUpdates(isBackground: true));
      }
    });
  }

  void _cancelStartupTimer() {
    _startupCheckTimer?.cancel();
    _startupCheckTimer = null;
  }

  /// Queries GitHub for a newer immutable release.
  ///
  /// When [isBackground] is `true`, errors and skipped versions stay quiet so
  /// daily background checks never interrupt active terminal work.
  Future<void> checkForUpdates({bool isBackground = false}) async {
    if (_disposed || !isSupportedDesktop) return;
    if (_status == UpdateStatus.checking ||
        _status == UpdateStatus.downloading ||
        _status == UpdateStatus.readyToRestart) {
      return;
    }
    _cancelStartupTimer();
    _errorMessage = null;
    _statusMessage = null;
    _transitionStatus(UpdateStatus.checking);

    final prefs = _readPreferences();
    try {
      final outcome = await _service.checkForUpdates(
        includePrereleases: prefs.includePrereleases,
        lastEtag: prefs.lastReleaseTagEtag,
        cachedTags: prefs.cachedReleaseTags,
      );
      if (_disposed) return;
      _persistCheckOutcome(outcome);
      _applyDiscoveredUpdate(
        outcome.availableUpdate,
        isBackground: isBackground,
      );
    } on Object catch (e) {
      if (_disposed) return;
      if (isBackground) {
        _transitionStatus(
          _availableUpdate != null ? UpdateStatus.available : UpdateStatus.idle,
        );
        return;
      }
      _errorMessage = '$e';
      _transitionStatus(UpdateStatus.error);
    }
  }

  void _persistCheckOutcome(UpdateCheckOutcome outcome) {
    final nowUtc = _clock.now().toUtc();
    final current = _readPreferences();
    final next = outcome.cacheTagState
        ? current.copyWith(
            lastUpdateCheckUtc: nowUtc,
            lastReleaseTagEtag: outcome.tagEtag,
            clearLastReleaseTagEtag: outcome.tagEtag == null,
            cachedReleaseTags: outcome.cachedTags,
          )
        : current.copyWith(lastUpdateCheckUtc: nowUtc);
    _writePreferences(next);
  }

  void _applyDiscoveredUpdate(
    AvailableUpdate? candidate, {
    required bool isBackground,
  }) {
    if (candidate == null) {
      _availableUpdate = null;
      _statusMessage = isBackground ? null : 'Up to date (v$currentVersion)';
      _transitionStatus(UpdateStatus.idle);
      return;
    }
    final skipped = _readPreferences().skippedUpdateVersion;
    if (isBackground && skipped == candidate.version.toString()) {
      _availableUpdate = null;
      _transitionStatus(UpdateStatus.idle);
      return;
    }
    _availableUpdate = candidate;
    _statusMessage = null;
    _transitionStatus(UpdateStatus.available);
  }

  /// Marks the currently offered [availableUpdate] version as skipped and
  /// clears the update badge for automatic checks.
  void skipAvailableVersion() {
    final update = _availableUpdate;
    if (_disposed || update == null || _status == UpdateStatus.downloading) {
      return;
    }
    final prefs = _readPreferences();
    _writePreferences(
      prefs.copyWith(skippedUpdateVersion: update.version.toString()),
    );
    _availableUpdate = null;
    _statusMessage = 'Skipped v${update.version}';
    _errorMessage = null;
    _transitionStatus(UpdateStatus.idle);
  }

  /// Downloads, verifies, and extracts [availableUpdate] into staging.
  Future<void> downloadAvailableUpdate() async {
    final update = _availableUpdate;
    if (_disposed || update == null) return;
    if (_status == UpdateStatus.downloading ||
        _status == UpdateStatus.readyToRestart) {
      return;
    }
    _errorMessage = null;
    _statusMessage = null;
    _downloadProgress = DownloadProgress(
      receivedBytes: 0,
      totalBytes: update.asset?.size ?? 0,
    );
    _transitionStatus(UpdateStatus.downloading);

    try {
      final staged = await _service.stageUpdate(
        update,
        onProgress: _handleDownloadProgress,
      );
      if (_disposed) return;
      _stagedUpdate = staged;
      _downloadProgress = null;
      if (capability == SelfUpdateCapability.macosAppManagementDenied) {
        _errorMessage =
            'macOS App Management permission is required to replace fterm.app '
            'in place. Reveal the verified staged app in Finder to install it.';
        _transitionStatus(UpdateStatus.error);
        return;
      }
      _transitionStatus(UpdateStatus.readyToRestart);
    } on Object catch (e) {
      if (_disposed) return;
      _downloadProgress = null;
      _errorMessage = '$e';
      _transitionStatus(UpdateStatus.error);
    }
  }

  void _handleDownloadProgress(DownloadProgress progress) {
    if (_disposed || _status != UpdateStatus.downloading) return;
    _downloadProgress = progress;
    // Fine-grained notification: updates the Settings progress bar WITHOUT
    // firing _onCoarseStateChanged across workspace chrome.
    notifyListeners();
  }

  /// Arms or disarms applying [stagedUpdate] automatically when the user quits.
  void setApplyOnQuit(bool enabled) {
    if (_disposed || _applyOnQuit == enabled) return;
    _applyOnQuit = enabled;
    notifyListeners();
  }

  /// Checks whether any sibling `fterm` window from this portable folder is open.
  bool hasSiblingInstances() => _service.hasSiblingInstances();

  /// Applies [stagedUpdate] immediately and relaunches `fterm`.
  ///
  /// Returns `false` and populates [errorMessage] if sibling windows hold
  /// `.fterm-instance.lock` or an in-process swap step fails cleanly.
  Future<bool> restartToUpdate() => _applyStagedInternal(relaunch: true);

  /// Applies [stagedUpdate] without relaunching when `applyOnQuit` is armed and
  /// the user closes the application window.
  Future<bool> applyStagedOnQuitIfArmed() async {
    if (!_applyOnQuit || _stagedUpdate == null) return false;
    return _applyStagedInternal(relaunch: false);
  }

  Future<bool> _applyStagedInternal({required bool relaunch}) async {
    final staged = _stagedUpdate;
    if (_disposed || staged == null || _busyApplying) return false;
    if (_service.hasSiblingInstances()) {
      _errorMessage =
          'Close other open fterm windows from this folder before updating.';
      _transitionStatus(UpdateStatus.error);
      return false;
    }
    _busyApplying = true;
    _errorMessage = null;
    notifyListeners();
    try {
      await _service.applyStagedUpdateAndExit(
        staged,
        relaunch: relaunch,
        relaunchArgs: _relaunchArgs,
        beforeExitTeardown: _beforeExitTeardown,
      );
      return true;
    } on Object catch (e) {
      if (!_disposed) {
        _errorMessage = '$e';
        _transitionStatus(UpdateStatus.error);
      }
      return false;
    } finally {
      _busyApplying = false;
    }
  }

  /// Reveals [stagedUpdate] in macOS Finder when in-place `.app` replacement is
  /// blocked by `App Management` TCC.
  Future<void> revealStagedInFinder() async {
    final staged = _stagedUpdate;
    if (_disposed || staged == null) return;
    await _service.revealStagedInFinder(staged);
  }

  /// Runs post-first-frame background cleanup of `*.fterm-bak` and
  /// `.fterm-update*`.
  Future<void> runStartupCleanup() => _service.runStartupCleanup();

  void _transitionStatus(UpdateStatus next) {
    final changed = _status != next;
    _status = next;
    notifyListeners();
    if (changed) {
      _onCoarseStateChanged?.call();
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _cancelStartupTimer();
    _service.dispose();
    super.dispose();
  }
}
