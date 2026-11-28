import 'package:characters/characters.dart';

import 'ktty_probe_assets.dart';

/// Support state for an individual terminal capability probe.
enum KttyCapabilityStatus {
  /// Query sent; awaiting terminal reply or `DA1` sentinel.
  pending,

  /// Terminal replied positively to the capability query.
  supported,

  /// Terminal either rejected the capability or ignored it prior to `DA1`.
  unsupported,

  /// Optional capability was not probed or is disabled by terminal policy.
  optionalDisabled,
}

/// Classification tier distinguishing required core probes from opt-in probes.
enum KttyCapabilityTier {
  /// Core terminal protocol probe counted toward `--strict` and `--self-test`.
  core,

  /// Opt-in or policy-gated probe (e.g. `t=t` temp files, `t=s` shared memory).
  optional,
}

/// Wire-level options controlling optional probes and multiplexer passthrough.
final class KttyProbeOptions {
  /// Whether to wrap Kitty Graphics `APC` probe commands in `tmux` DCS passthrough.
  final bool wrapTmuxPassthrough;

  /// Optional local temporary RGBA file path for probing Kitty `a=q,t=t`.
  final String? tempProbeFilePath;

  /// Optional POSIX shared-memory object name for probing Kitty `a=q,t=s`.
  final String? shmProbeName;

  /// Optional local regular RGBA file path for probing Kitty `a=q,t=f`.
  final String? fileProbeFilePath;

  /// Creates [KttyProbeOptions].
  const KttyProbeOptions({
    this.wrapTmuxPassthrough = false,
    this.tempProbeFilePath,
    this.shmProbeName,
    this.fileProbeFilePath,
  });
}

/// Diagnostic snapshot of an enclosing terminal multiplexer (`tmux` / `screen`).
final class KttyMultiplexerDiagnostics {
  /// Detected multiplexer name (`'tmux'` or `'screen'`).
  final String multiplexer;

  /// Value of `tmux` `allow-passthrough` (`'off'`, `'on'`, `'all'`, or `null`).
  final String? allowPassthrough;

  /// Whether truecolor (`RGB` or `Tc`) support is advertised by multiplexer config.
  final bool hasTrueColor;

  /// Actionable remediation hints for enabling passthrough or truecolor.
  final List<String> hints;

  /// Creates a [KttyMultiplexerDiagnostics] snapshot.
  const KttyMultiplexerDiagnostics({
    required this.multiplexer,
    this.allowPassthrough,
    this.hasTrueColor = false,
    this.hints = const [],
  });

  /// Serializes multiplexer diagnostics to a JSON-compatible map.
  Map<String, Object?> toJsonMap() => {
    'multiplexer': multiplexer,
    'allowPassthrough': allowPassthrough,
    'hasTrueColor': hasTrueColor,
    'hints': hints,
  };
}

/// Comparison result produced by [KttyProbeReport.diffAgainstBaseline].
final class KttyProbeDiff {
  /// Capability IDs that regressed from `supported` (`PASS`) to `unsupported` (`MISS`).
  final List<String> regressions;

  /// Capability IDs that improved from non-`supported` to `supported` (`PASS`).
  final List<String> improvements;

  /// Capability IDs whose status did not change relative to the baseline.
  final List<String> unchanged;

  /// Capability IDs present in the current report but absent from the baseline.
  final List<String> added;

  /// Capability IDs present in the baseline but absent from the current report.
  final List<String> removed;

  /// Creates a [KttyProbeDiff].
  const KttyProbeDiff({
    required this.regressions,
    required this.improvements,
    required this.unchanged,
    this.added = const [],
    this.removed = const [],
  });

  /// Whether any capability regressed (`PASS -> MISS`).
  bool get hasRegressions => regressions.isNotEmpty;

  /// Count of capabilities whose status matched the baseline.
  int get unchangedCount => unchanged.length;

  /// Serializes this diff to a JSON-compatible map.
  Map<String, Object?> toJsonMap() => {
    'hasRegressions': hasRegressions,
    'regressions': regressions,
    'improvements': improvements,
    'unchangedCount': unchangedCount,
    'added': added,
    'removed': removed,
  };

  /// Formats a human-readable baseline comparison summary.
  String formatPlainSummary({bool ansiColor = true}) {
    final reset = ansiColor ? '\x1b[0m' : '';
    final red = ansiColor ? '\x1b[31m' : '';
    final green = ansiColor ? '\x1b[32m' : '';
    final cyan = ansiColor ? '\x1b[36m' : '';
    final sb = StringBuffer()
      ..writeln(
        '${cyan}Baseline Comparison:$reset '
        '${regressions.length} regressions, '
        '${improvements.length} improvements, '
        '$unchangedCount unchanged',
      );
    for (final id in regressions) {
      sb.writeln('  ${red}REGRESSION (PASS -> MISS):$reset $id');
    }
    for (final id in improvements) {
      sb.writeln('  ${green}IMPROVED (-> PASS):$reset $id');
    }
    if (added.isNotEmpty) {
      sb.writeln('  Added probes (${added.length}): ${added.join(', ')}');
    }
    if (removed.isNotEmpty) {
      sb.writeln('  Removed probes (${removed.length}): ${removed.join(', ')}');
    }
    return sb.toString();
  }
}

/// Lifecycle handle for local temp-file (`t=t`) and shared-memory (`t=s`) probe
/// fixtures created outside Web-safe core libraries.
abstract interface class KttyLocalMediaProbeSession {
  /// Absolute path to the temporary RGBA probe file, or `null` when unavailable.
  String? get tempFilePath;

  /// POSIX shared-memory object name, or `null` when unavailable.
  String? get shmObjectName;

  /// Whether the temporary probe file still exists on disk (verifying `a=q` did not unlink it).
  bool get tempFileStillExists;

  /// Whether the shared-memory probe object still exists (verifying `a=q` did not unlink it).
  bool get shmStillExists;

  /// Removes any temporary probe artifacts created by this session.
  void dispose();
}

/// Decoded `DECRQM` (`CSI ? Pm ; Ps $ y`) mode report status.
enum DecrqmModeState {
  /// Mode is not recognized (`Ps = 0`).
  notRecognized(0, 'Unrecognized (0)', false),

  /// Mode is recognized and currently set (`Ps = 1`).
  set(1, 'Set (1)', true),

  /// Mode is recognized and currently reset (`Ps = 2`).
  reset(2, 'Reset (2)', true),

  /// Mode is permanently set (`Ps = 3`).
  permanentlySet(3, 'Perm Set (3)', true),

  /// Mode is permanently reset (`Ps = 4`).
  permanentlyReset(4, 'Perm Reset (4)', true);

  /// Raw `Ps` integer reported by the terminal.
  final int code;

  /// Human-readable description of the `Ps` value.
  final String label;

  /// Whether this `Ps` value means the mode is supported by the terminal.
  final bool isSupported;

  const DecrqmModeState(this.code, this.label, this.isSupported);

  /// Resolves a `DECRQM` `Ps` integer to a [DecrqmModeState].
  static DecrqmModeState fromCode(int code) => switch (code) {
    1 => set,
    2 => reset,
    3 => permanentlySet,
    4 => permanentlyReset,
    _ => notRecognized,
  };
}

/// Snapshot of a single probed terminal capability row.
final class KttyCapabilityEntry {
  /// Stable identifier key (e.g. `'apc_query'`, `'kitty_kb'`).
  final String id;

  /// Display title shown in the capability matrix.
  final String name;

  /// Short wire-protocol label (e.g. `'APC a=q'`, `'CSI ? u'`).
  final String protocol;

  /// Whether this capability is a core requirement or an opt-in check.
  final KttyCapabilityTier tier;

  /// Current probe status.
  KttyCapabilityStatus status;

  /// Decoded detail string or error explanation.
  String detail;

  /// Creates a capability row entry.
  KttyCapabilityEntry({
    required this.id,
    required this.name,
    required this.protocol,
    this.tier = .core,
    this.status = .pending,
    this.detail = 'Probing...',
  });
}

/// Reactive model holding all probed KTTY and VT capability results.
final class KttyProbeReport {
  final Map<String, KttyCapabilityEntry> _entries = {};
  final List<void Function()> _listeners = [];
  final Map<String, String> _xtgettcapCapabilities = {};
  final Set<String> _xtgettcapUnsupported = {};
  final List<String> _decrqssReplies = [];

  (int row, int col)? _cprBeforeOsc66;
  int _colorStackSampleCount = 0;
  String? _colorStackBaselineHex;
  bool _colorStackOverrideSeen = false;
  bool _animFrameOk = false;
  int _animControlOkCount = 0;
  String? _animError;

  /// Number of probe passes initiated in this session.
  int probeRunCount = 0;

  /// Whether the `DA1` sentinel reply has completed the active probe pass.
  bool isComplete = false;

  /// Optional diagnostics for an enclosing `tmux` or `screen` multiplexer.
  KttyMultiplexerDiagnostics? multiplexerDiagnostics;

  /// Terminal version string reported by `XTVERSION` (`DCS > | ... ST`), if any.
  String? xtVersion;

  /// Kitty keyboard progressive enhancement bitmask reported by `CSI ? flags u`.
  int? kittyKeyboardFlags;

  /// Default foreground color reported by `OSC 10`, normalized to `#RRGGBB`.
  String? defaultForegroundHex;

  /// Default background color reported by `OSC 11`, normalized to `#RRGGBB`.
  String? defaultBackgroundHex;

  /// Active color scheme reported by `CSI ? 997 ; 1|2 n` (`'dark'` or `'light'`).
  String? colorScheme;

  /// Most recent `OSC 52` clipboard read payload, if the host replied to `OSC 52;?`.
  String? osc52ClipboardReply;

  /// Viewport width in pixels reported by `CSI 14 t` (`CSI 4 ; h ; w t`).
  int viewportPixelWidth = 0;

  /// Viewport height in pixels reported by `CSI 14 t` (`CSI 4 ; h ; w t`).
  int viewportPixelHeight = 0;

  /// Cell width in pixels (reported by `CSI 16 t` or configured by host).
  int cellPixelWidth = 9;

  /// Cell height in pixels (reported by `CSI 16 t` or configured by host).
  int cellPixelHeight = 18;

  /// Summary of the most recent SGR / SGR-Pixels mouse packet observed on the wire.
  String lastWireMousePacket = 'Move or click mouse to inspect ?1006 / ?1016';

  static const String _defaultOsc99Ack =
      'None (press [N] then click toast Activate/Dismiss)';

  /// Most recent `OSC 99` notification activation or close reply received on the wire.
  String lastOsc99Ack = _defaultOsc99Ack;

  /// Whether at least one `OSC 99` reply has arrived during the active session.
  bool hasOsc99Ack = false;

  /// Creates a [KttyProbeReport] initialized with all 38 KTTY probe entries
  /// (33 core + 5 optional).
  KttyProbeReport() {
    _initEntries();
  }

  void _initEntries() {
    const specs = <(String, String, String, KttyCapabilityTier)>[
      ('apc_query', 'Kitty Graphics Query', 'APC a=q', .core),
      ('apc_rgba', 'Kitty Graphics RGBA32', 'APC f=32', .core),
      ('apc_zlib', 'Kitty Graphics Zlib', 'APC o=z', .core),
      ('apc_png', 'Kitty Graphics PNG', 'APC f=100', .core),
      ('apc_chunked', 'Kitty Graphics Chunked', 'APC m=1/0', .core),
      ('apc_place_persist', 'Kitty Place Persistence', 'APC d=a/a=p', .core),
      ('apc_image_num', 'Kitty Image Number', 'APC I=', .core),
      ('apc_crop_layer', 'Kitty Crop & Z-Layer', 'APC x,y,z=-1', .core),
      ('apc_animation', 'Kitty Animation Frames', 'APC a=f/a/c', .core),
      ('apc_temp_file', 'Kitty Temp File Medium', 'APC t=t', .optional),
      ('apc_shm', 'Kitty Shared Memory', 'APC t=s', .optional),
      ('apc_file_medium', 'Kitty File Medium', 'APC t=f', .optional),
      ('termui_shader_apc', 'TermUI Shader APC', 'APC S query', .optional),
      ('termui_audio_apc', 'TermUI Audio APC', 'APC A wave', .optional),
      ('kitty_kb', 'Kitty Keyboard Protocol', 'CSI ? u', .core),
      ('xtversion', 'Terminal Identity', 'XTVERSION', .core),
      ('xtgettcap', 'Terminfo Capabilities', 'DCS +q', .core),
      ('decrqss', 'Status String Query', r'DCS $q', .core),
      ('osc10', 'Default Foreground', 'OSC 10;?', .core),
      ('osc11', 'Default Background', 'OSC 11;?', .core),
      ('osc_30001_colors', 'Color Stack Push/Pop', 'OSC 30001', .core),
      ('osc_66_sizing', 'Kitty Text Sizing', 'OSC 66 + CPR', .core),
      ('osc_22_pointer', 'Mouse Pointer Shapes', 'OSC 22;?', .core),
      ('osc_99_query', 'Notification Query', 'OSC 99;p=?', .core),
      ('osc_5522_clip', 'Kitty Clipboard Write', 'OSC 5522', .core),
      ('decrqm_2026', 'Synchronized Output', 'DECRQM ?2026', .core),
      ('decrqm_1016', 'SGR-Pixels Mouse', 'DECRQM ?1016', .core),
      ('decrqm_2027', 'Grapheme Clustering', 'DECRQM ?2027', .core),
      ('decrqm_2004', 'Bracketed Paste', 'DECRQM ?2004', .core),
      ('decrqm_1004', 'Focus Reporting', 'DECRQM ?1004', .core),
      ('decrqm_1006', 'SGR Mouse Encoding', 'DECRQM ?1006', .core),
      ('decrqm_2031', 'Color Scheme Updates', 'DECRQM ?2031', .core),
      ('csi_996_scheme', 'Color Scheme Query', 'CSI ? 996 n', .core),
      ('xtwinops_14t', 'Viewport Pixel Size', 'CSI 14 t', .core),
      ('xtwinops_16t', 'Cell Pixel Size', 'CSI 16 t', .core),
      ('xtwinops_18t', 'Text Grid Size', 'CSI 18 t', .core),
      ('da2', 'Secondary Device Attrs', 'CSI > c', .core),
      ('da1', 'Primary DA Sentinel', 'CSI c', .core),
    ];
    for (final (id, name, proto, tier) in specs) {
      _entries[id] = KttyCapabilityEntry(
        id: id,
        name: name,
        protocol: proto,
        tier: tier,
      );
    }
  }

  /// Ordered list of all capability entries in the report.
  List<KttyCapabilityEntry> get entries =>
      List<KttyCapabilityEntry>.unmodifiable(_entries.values);

  /// Decoded supported `XTGETTCAP` capabilities (`name -> value`).
  Map<String, String> get xtgettcapCapabilities =>
      Map<String, String>.unmodifiable(_xtgettcapCapabilities);

  /// Decoded unsupported `XTGETTCAP` capability names (`0+r`).
  Set<String> get xtgettcapUnsupported =>
      Set<String>.unmodifiable(_xtgettcapUnsupported);

  /// Whether the active probe pass is awaiting `CSI row;col R` CPR replies for
  /// `OSC 66` cursor-advance verification.
  bool get isExpectingCpr =>
      !isComplete && _entries['osc_66_sizing']?.status == .pending;

  /// Looks up a capability entry by [id].
  KttyCapabilityEntry? operator [](String id) => _entries[id];

  /// Count of capabilities currently marked [KttyCapabilityStatus.supported].
  int get supportedCount =>
      _entries.values.where((e) => e.status == .supported).length;

  /// Count of capabilities currently marked [KttyCapabilityStatus.unsupported].
  int get unsupportedCount =>
      _entries.values.where((e) => e.status == .unsupported).length;

  /// Count of capabilities still awaiting a reply.
  int get pendingCount =>
      _entries.values.where((e) => e.status == .pending).length;

  /// Count of [KttyCapabilityTier.core] capabilities marked supported.
  int get coreSupportedCount => _entries.values
      .where((e) => e.tier == .core && e.status == .supported)
      .length;

  /// Total number of [KttyCapabilityTier.core] capabilities in the report.
  int get coreTotalCount =>
      _entries.values.where((e) => e.tier == .core).length;

  /// Count of [KttyCapabilityTier.core] capabilities marked unsupported.
  int get coreUnsupportedCount => _entries.values
      .where((e) => e.tier == .core && e.status == .unsupported)
      .length;

  /// Count of [KttyCapabilityTier.optional] capabilities marked disabled or skipped.
  int get optionalDisabledCount =>
      _entries.values.where((e) => e.status == .optionalDisabled).length;

  /// Registers a change listener invoked when probe results update.
  void addListener(void Function() listener) => _listeners.add(listener);

  /// Removes a previously registered listener.
  void removeListener(void Function() listener) => _listeners.remove(listener);

  void _notify() {
    for (final listener in List<void Function()>.of(_listeners)) {
      listener();
    }
  }

  /// Resets all entries to [KttyCapabilityStatus.pending] for a fresh probe run.
  ///
  /// When [options] is provided, optional media entries whose host fixture is
  /// unavailable on the current platform are immediately marked
  /// [KttyCapabilityStatus.optionalDisabled] instead of remaining pending until
  /// `DA1`.
  void resetForNewProbe({KttyProbeOptions? options}) {
    probeRunCount++;
    isComplete = false;
    xtVersion = null;
    kittyKeyboardFlags = null;
    defaultForegroundHex = null;
    defaultBackgroundHex = null;
    colorScheme = null;
    viewportPixelWidth = 0;
    viewportPixelHeight = 0;
    lastOsc99Ack = _defaultOsc99Ack;
    hasOsc99Ack = false;
    _xtgettcapCapabilities.clear();
    _xtgettcapUnsupported.clear();
    _decrqssReplies.clear();
    _cprBeforeOsc66 = null;
    _colorStackSampleCount = 0;
    _colorStackBaselineHex = null;
    _colorStackOverrideSeen = false;
    _animFrameOk = false;
    _animControlOkCount = 0;
    _animError = null;
    for (final entry in _entries.values) {
      entry.status = .pending;
      entry.detail = 'Probing...';
    }
    if (options != null) {
      if (options.tempProbeFilePath == null ||
          options.tempProbeFilePath!.isEmpty) {
        _updateEntry(
          'apc_temp_file',
          .optionalDisabled,
          'Unavailable on this platform',
          notify: false,
        );
      }
      if (options.shmProbeName == null || options.shmProbeName!.isEmpty) {
        _updateEntry(
          'apc_shm',
          .optionalDisabled,
          'Unavailable on this platform',
          notify: false,
        );
      }
      if (options.fileProbeFilePath == null ||
          options.fileProbeFilePath!.isEmpty) {
        _updateEntry(
          'apc_file_medium',
          .optionalDisabled,
          'Unavailable on this platform',
          notify: false,
        );
      }
    }
    _notify();
  }

  static final RegExp _controlCharsRegex = RegExp(r'[\x00-\x1F\x7F-\x9F]');
  static const int _maxDetailLength = 200;

  static String _sanitizeDetail(String raw) {
    final cleaned = raw.replaceAll(_controlCharsRegex, '').trim();
    final chars = cleaned.characters;
    return chars.length <= _maxDetailLength
        ? cleaned
        : '${chars.take(_maxDetailLength)}...';
  }

  /// Builds the wire-protocol query burst ending with the `DA1` (`\x1b[c`) sentinel.
  static String buildWireProbeSequence({
    KttyProbeOptions options = const KttyProbeOptions(),
  }) {
    final apcCommands = buildKittyApcProbeCommands(options: options);
    final sb = StringBuffer()
      ..write(apcCommands)
      ..write('\x1b[?u')
      ..write('\x1b[>0q')
      // XTGETTCAP: RGB (524742), Smulx (536d756c78), Setulc (536574756c63), Sync (53796e63)
      ..write('\x1bP+q524742;536d756c78;536574756c63;53796e63\x1b\\')
      // DECRQSS: active SGR ('m') and cursor shape (' q')
      ..write('\x1bP\$qm\x1b\\')
      ..write('\x1bP\$q q\x1b\\')
      ..write('\x1b]10;?\x1b\\')
      ..write('\x1b]11;?\x1b\\')
      // OSC 30001/30101 color stack push/override/pop verification on palette slot 255
      ..write('\x1b]4;$kttyProbeColorStackIndex;?\x1b\\')
      ..write('\x1b]30001\x1b\\')
      ..write(
        '\x1b]4;$kttyProbeColorStackIndex;$kttyProbeColorStackSentinelHex\x1b\\',
      )
      ..write('\x1b]4;$kttyProbeColorStackIndex;?\x1b\\')
      ..write('\x1b]30101\x1b\\')
      ..write('\x1b]4;$kttyProbeColorStackIndex;?\x1b\\')
      ..write('\x1b]104;$kttyProbeColorStackIndex\x1b\\')
      // OSC 66 text sizing cursor-advance probe (CSI 6 n delta == +2)
      ..write('\x1b7\r\x1b[6n\x1b]66;w=2; \x1b\\\x1b[6n\r  \r\x1b8')
      ..write('\x1b]22;?pointer,text,ktty-invalid\x1b\\')
      ..write('\x1b]99;i=ktty-probe:p=?;\x1b\\')
      // OSC 5522 clipboard write probe (upstream Kitty 3-packet format with base64 mime=text/plain)
      ..write('\x1b]5522;type=write:id=$kttyProbeOsc5522Id;\x1b\\')
      ..write('\x1b]5522;type=wdata:mime=dGV4dC9wbGFpbg==;a3R0eQ==\x1b\\')
      ..write('\x1b]5522;type=wdata;\x1b\\')
      ..write('\x1b[?2026\$p')
      ..write('\x1b[?1016\$p')
      ..write('\x1b[?2027\$p')
      ..write('\x1b[?2004\$p')
      ..write('\x1b[?1004\$p')
      ..write('\x1b[?1006\$p')
      ..write('\x1b[?2031\$p')
      ..write('\x1b[?996n')
      ..write('\x1b[14t')
      ..write('\x1b[16t')
      ..write('\x1b[18t')
      ..write('\x1b[>c')
      ..write('\x1b[c');
    return sb.toString();
  }

  void _updateEntry(
    String id,
    KttyCapabilityStatus status,
    String detail, {
    bool notify = true,
  }) {
    final entry = _entries[id];
    if (entry == null) return;
    entry.status = status;
    entry.detail = detail;
    if (notify) _notify();
  }

  static String? _resolveApcCapabilityKey(
    int imageId, {
    int? imageNumber,
    int? placementId,
  }) {
    if (imageNumber == kttyProbeImageNumber) return 'apc_image_num';
    return switch (imageId) {
      kttyProbeQueryId => 'apc_query',
      kttyProbeRgbaId => 'apc_rgba',
      kttyProbeZlibId => 'apc_zlib',
      kttyProbePngId => 'apc_png',
      kttyProbeChunkedId => 'apc_chunked',
      kttyProbePlaceId =>
        placementId == kttyProbePlacementId ? 'apc_place_persist' : null,
      kttyProbeCropLayerId =>
        placementId == kttyProbeCropPlacementId ? 'apc_crop_layer' : null,
      kttyProbeAnimId => 'apc_animation',
      kttyProbeTempId => 'apc_temp_file',
      kttyProbeShmId => 'apc_shm',
      kttyProbeFileId => 'apc_file_medium',
      _ => null,
    };
  }

  static String _formatApcOkDetail(
    int imageId, {
    int? imageNumber,
    int? placementId,
    int? frameNumber,
  }) {
    if (imageNumber != null) {
      return imageId > 0
          ? 'OK (i=$imageId,I=$imageNumber)'
          : 'OK (I=$imageNumber)';
    }
    if (placementId != null) return 'OK (i=$imageId,p=$placementId)';
    if (frameNumber != null) return 'OK (i=$imageId,r=$frameNumber)';
    return 'OK (i=$imageId)';
  }

  void _recordAnimApcReply({
    required bool ok,
    required String detail,
    int? frameNumber,
  }) {
    if (!ok) {
      _animError = detail;
      _updateEntry('apc_animation', .unsupported, detail);
      return;
    }
    if (_animError != null) return;
    if (frameNumber != null) {
      _animFrameOk = true;
    } else {
      _animControlOkCount++;
    }
    final summary = _animFrameOk && _animControlOkCount >= 2
        ? 'OK (i=$kttyProbeAnimId, a=f/a/c)'
        : _formatApcOkDetail(kttyProbeAnimId, frameNumber: frameNumber);
    _updateEntry('apc_animation', .supported, summary);
  }

  /// Records a Kitty Graphics `APC` reply (`ESC _ G i=<id>,I=<num>,p=<pid>,r=<frame>;<status> ESC \`).
  void recordApcReply(
    int imageId,
    String statusMessage, {
    int? imageNumber,
    int? placementId,
    int? frameNumber,
  }) {
    final trimmed = _sanitizeDetail(statusMessage);
    final upper = trimmed.toUpperCase();
    final ok = upper == 'OK';
    final key = _resolveApcCapabilityKey(
      imageId,
      imageNumber: imageNumber,
      placementId: placementId,
    );
    if (key == null) return;
    final entry = _entries[key];
    if (entry == null) return;

    if (key == 'apc_animation') {
      _recordAnimApcReply(ok: ok, detail: trimmed, frameNumber: frameNumber);
      return;
    }

    final isOptionalDisabled =
        entry.tier == .optional &&
        (upper.startsWith('EINVAL:UNSUPPORTED') ||
            upper.startsWith('EPERM:') ||
            upper.startsWith('ENOTSUP:'));
    final KttyCapabilityStatus status;
    if (ok) {
      status = .supported;
    } else if (isOptionalDisabled) {
      status = .optionalDisabled;
    } else {
      status = .unsupported;
    }

    final detail = ok
        ? _formatApcOkDetail(
            imageId,
            imageNumber: imageNumber,
            placementId: placementId,
            frameNumber: frameNumber,
          )
        : trimmed;
    _updateEntry(key, status, detail);
  }

  /// Records an optional TermUI Shader APC capability reply (`ESC _ S a=caps,... ST`).
  void recordShaderApcReply(Map<String, String> control) {
    final backend = _sanitizeDetail(control['backend'] ?? 'none');
    final glsl = control['glsl'] == '1';
    final xform = control['xform'] == '1';
    final region = control['region'] == '1';
    final hasBackend = backend != 'none' && backend != 'disabled';
    final active = hasBackend || glsl || xform || region;
    if (!active) {
      _updateEntry(
        'termui_shader_apc',
        .optionalDisabled,
        'Disabled (backend=$backend)',
      );
      return;
    }
    _updateEntry(
      'termui_shader_apc',
      .supported,
      'backend=$backend glsl=${glsl ? 1 : 0} xform=${xform ? 1 : 0} region=${region ? 1 : 0}',
    );
  }

  /// Records an optional TermUI Audio APC waveform reply (`ESC _ A a=waver,q=<id>;... ST`).
  void recordAudioApcReply({
    required String requestId,
    required int sampleCount,
  }) {
    final safeId = _sanitizeDetail(requestId);
    final payloadInfo = sampleCount > 0 ? '$sampleCount f32 samples' : 'silent';
    _updateEntry(
      'termui_audio_apc',
      .supported,
      'OK (q=$safeId, $payloadInfo)',
    );
  }

  /// Records a Kitty Keyboard query reply (`CSI ? <flags> u`).
  void recordKittyKeyboardFlags(int flags) {
    kittyKeyboardFlags = flags;
    _updateEntry(
      'kitty_kb',
      .supported,
      'Flags=0x${flags.toRadixString(16).padLeft(2, '0')} ($flags)',
    );
  }

  /// Records an `XTVERSION` reply (`DCS > | <version> ST`).
  void recordXtVersion(String version) {
    final safe = _sanitizeDetail(version);
    xtVersion = safe;
    _updateEntry('xtversion', .supported, safe);
  }

  /// Records a decoded `XTGETTCAP` (`DCS 1+r` or `0+r`) capability reply.
  void recordXtgettcapReply(
    String name, {
    String value = '',
    required bool supported,
  }) {
    final safeName = _sanitizeDetail(name);
    if (safeName.isEmpty) return;
    if (supported) {
      _xtgettcapCapabilities[safeName] = _sanitizeDetail(value);
      _xtgettcapUnsupported.remove(safeName);
    } else if (!_xtgettcapCapabilities.containsKey(safeName)) {
      _xtgettcapUnsupported.add(safeName);
    }
    if (_xtgettcapCapabilities.isNotEmpty) {
      _updateEntry(
        'xtgettcap',
        .supported,
        _xtgettcapCapabilities.keys.join(', '),
      );
    } else {
      _updateEntry(
        'xtgettcap',
        .unsupported,
        'Unsupported (${_xtgettcapUnsupported.join(', ')})',
      );
    }
  }

  /// Records a `DECRQSS` (`DCS 1$r...` or `DCS 0$r`) status string reply.
  void recordDecrqssReply({required bool valid, required String body}) {
    final safeBody = _sanitizeDetail(body);
    if (valid && safeBody.isNotEmpty) {
      final label = safeBody.endsWith(' q')
          ? 'DECSCUSR=$safeBody'
          : safeBody.endsWith('m')
          ? 'SGR=$safeBody'
          : safeBody;
      if (!_decrqssReplies.contains(label)) {
        _decrqssReplies.add(label);
      }
      _updateEntry('decrqss', .supported, _decrqssReplies.join(', '));
      return;
    }
    if (_decrqssReplies.isEmpty) {
      _updateEntry('decrqss', .unsupported, 'Rejected (0\$r)');
    }
  }

  /// Records a `CSI row;col R` Cursor Position Report for `OSC 66` delta verification.
  void recordCursorPositionReport(int row, int col) {
    if (!isExpectingCpr) return;
    final first = _cprBeforeOsc66;
    if (first == null) {
      _cprBeforeOsc66 = (row, col);
      return;
    }
    final deltaCol = col - first.$2;
    final sameRow = row == first.$1;
    if (sameRow && deltaCol == 2) {
      _updateEntry('osc_66_sizing', .supported, 'OK (CPR delta=+2)');
    } else {
      _updateEntry(
        'osc_66_sizing',
        .unsupported,
        'CPR delta=$deltaCol (row ${first.$1}->$row, expected +2)',
      );
    }
  }

  /// Records an `OSC 4;255` color sample for `OSC 30001`/`30101` stack verification.
  void recordOsc4ColorStackSample(String? normalizedHex, {String? rawSpec}) {
    final entry = _entries['osc_30001_colors'];
    if (entry == null || entry.status != .pending) return;
    final color = normalizedHex ?? _sanitizeDetail(rawSpec ?? '');
    _colorStackSampleCount++;
    if (_colorStackSampleCount == 1) {
      _colorStackBaselineHex = color;
      return;
    }
    if (_colorStackSampleCount == 2) {
      _colorStackOverrideSeen =
          color.toUpperCase() == kttyProbeColorStackSentinelHex;
      return;
    }
    final restored =
        _colorStackOverrideSeen &&
        _colorStackBaselineHex != null &&
        color == _colorStackBaselineHex;
    if (restored) {
      _updateEntry(
        'osc_30001_colors',
        .supported,
        'OK (restored $_colorStackBaselineHex)',
      );
    } else if (!_colorStackOverrideSeen) {
      _updateEntry('osc_30001_colors', .unsupported, 'OSC 4 override ignored');
    } else {
      _updateEntry(
        'osc_30001_colors',
        .unsupported,
        'Not restored (got $color, expected $_colorStackBaselineHex)',
      );
    }
  }

  /// Records an `OSC 10` (foreground) or `OSC 11` (background) color reply.
  void recordOscColor(int oscCode, String rawSpec, String? normalizedHex) {
    final display = normalizedHex != null
        ? '$normalizedHex ($rawSpec)'
        : rawSpec;
    if (oscCode == 10) {
      defaultForegroundHex = normalizedHex ?? rawSpec;
      _updateEntry('osc10', .supported, display);
    } else if (oscCode == 11) {
      defaultBackgroundHex = normalizedHex ?? rawSpec;
      _updateEntry('osc11', .supported, display);
    }
  }

  /// Records an `OSC 22` mouse pointer shape query reply (`ESC ] 22 ; 1,1,0 ST`).
  void recordOsc22PointerQuery(String rawReply) {
    final trimmed = _sanitizeDetail(rawReply);
    final tokens = trimmed.split(',');
    final valid =
        tokens.length == 3 &&
        tokens[0] == '1' &&
        tokens[1] == '1' &&
        tokens[2] == '0';
    _updateEntry(
      'osc_22_pointer',
      valid ? .supported : .unsupported,
      valid ? 'OK ($trimmed)' : 'Unexpected reply ($trimmed)',
    );
  }

  /// Records an `OSC 99` capability query reply (`ESC ] 99 ; ...:p=?;... ST`).
  void recordOsc99CapabilityQuery(String capabilities) {
    final trimmed = _sanitizeDetail(capabilities);
    final hasCaps = trimmed.isNotEmpty;
    _updateEntry(
      'osc_99_query',
      hasCaps ? .supported : .unsupported,
      hasCaps ? trimmed : 'Empty capability reply',
    );
  }

  /// Records an `OSC 5522` clipboard status reply (`type=write:status=DONE`).
  void recordOsc5522Reply({
    required String type,
    required String status,
    String raw = '',
  }) {
    if (type != 'write') return;
    final safeStatus = _sanitizeDetail(status);
    if (safeStatus == 'DONE') {
      _updateEntry('osc_5522_clip', .supported, 'OK (type=write:status=DONE)');
    } else {
      final info = safeStatus.isNotEmpty ? safeStatus : _sanitizeDetail(raw);
      _updateEntry('osc_5522_clip', .unsupported, 'type=write:status=$info');
    }
  }

  /// Records an `OSC 52` clipboard read reply if the terminal sent one.
  void recordOsc52Reply(String decodedText) {
    osc52ClipboardReply = decodedText;
    _notify();
  }

  /// Records an incoming `OSC 99` notification activation or close reply (`ESC ] 99 ; ... ST`).
  void recordOsc99Ack(String summary) {
    lastOsc99Ack = summary;
    hasOsc99Ack = true;
    _notify();
  }

  /// Records a `DECRQM` reply (`CSI ? <mode> ; <state> $ y`).
  void recordDecrqm(int mode, int stateCode) {
    final id = 'decrqm_$mode';
    if (!_entries.containsKey(id)) return;
    final state = DecrqmModeState.fromCode(stateCode);
    _updateEntry(
      id,
      state.isSupported ? .supported : .unsupported,
      state.label,
    );
  }

  /// Records a color scheme query reply (`CSI ? 997 ; 1|2 n`).
  void recordColorScheme(int mode) {
    final label = switch (mode) {
      1 => 'dark',
      2 => 'light',
      _ => null,
    };
    if (label == null) {
      _updateEntry('csi_996_scheme', .unsupported, 'Unknown mode ($mode)');
      return;
    }
    colorScheme = label;
    _updateEntry('csi_996_scheme', .supported, '$label (CSI ?997;${mode}n)');
  }

  /// Records viewport pixel dimensions reported by `XTWINOPS 14t` (`CSI 4 ; h ; w t`).
  void recordViewportPixelSize(int widthPx, int heightPx) {
    if (widthPx > 0) viewportPixelWidth = widthPx;
    if (heightPx > 0) viewportPixelHeight = heightPx;
    if (widthPx > 0 && heightPx > 0) {
      _updateEntry('xtwinops_14t', .supported, '${widthPx}x${heightPx}px');
    } else {
      _notify();
    }
  }

  /// Records cell pixel dimensions reported by `XTWINOPS 16t` (`CSI 6 ; h ; w t`).
  void recordCellPixelSize(int widthPx, int heightPx) {
    if (widthPx > 0) cellPixelWidth = widthPx;
    if (heightPx > 0) cellPixelHeight = heightPx;
    if (widthPx > 0 && heightPx > 0) {
      _updateEntry('xtwinops_16t', .supported, '${widthPx}x${heightPx}px');
    } else {
      _notify();
    }
  }

  /// Records a decoded wire-level SGR or SGR-Pixels mouse packet for live telemetry.
  void recordWireMousePacket(String summary) {
    lastWireMousePacket = summary;
    _notify();
  }

  /// Records an `XTWINOPS 18t` text grid size reply (`CSI 8 ; <rows> ; <cols> t`).
  void recordTextAreaSize(int cols, int rows) {
    _updateEntry('xtwinops_18t', .supported, '${cols}x$rows cells');
  }

  /// Records a Secondary Device Attributes reply (`CSI > <params> c`).
  void recordDa2(String params) {
    _updateEntry('da2', .supported, 'CSI > $params c');
  }

  /// Records the Primary Device Attributes (`DA1`) sentinel and finalizes any
  /// earlier unanswered queries.
  void recordDa1Sentinel(String params) {
    _updateEntry('da1', .supported, 'CSI ? $params c', notify: false);
    finalizePending('No reply before DA1');
  }

  /// Transitions remaining [KttyCapabilityStatus.pending] probes: optional rows
  /// become [KttyCapabilityStatus.optionalDisabled] and core rows become
  /// [KttyCapabilityStatus.unsupported].
  void finalizePending(String reason) {
    for (final entry in _entries.values) {
      if (entry.status != .pending) continue;
      if (entry.tier == .optional) {
        entry.status = .optionalDisabled;
        entry.detail = 'Optional ($reason)';
      } else {
        entry.status = .unsupported;
        entry.detail = reason;
      }
    }
    isComplete = true;
    _notify();
  }

  static Map<String, String> _parseBaselineStatuses(
    Map<String, Object?> baselineJson,
  ) {
    final rawCaps = baselineJson['capabilities'];
    if (rawCaps is! List<Object?>) {
      throw const FormatException('Baseline JSON missing "capabilities" list.');
    }
    final statuses = <String, String>{};
    for (final item in rawCaps) {
      if (item is! Map<Object?, Object?>) continue;
      final id = item['id'];
      final status = item['status'];
      if (id is String && status is String && id.isNotEmpty) {
        statuses[id] = status;
      }
    }
    return statuses;
  }

  /// Compares this report against a previously saved JSON report [baselineJson],
  /// identifying `PASS -> MISS` regressions, improvements, and unchanged rows.
  KttyProbeDiff diffAgainstBaseline(Map<String, Object?> baselineJson) {
    final baselineStatuses = _parseBaselineStatuses(baselineJson);
    final regressions = <String>[];
    final improvements = <String>[];
    final unchanged = <String>[];
    final added = <String>[];
    final removed = <String>[];

    for (final entry in _entries.values) {
      final prev = baselineStatuses[entry.id];
      if (prev == null) {
        added.add(entry.id);
      } else if (prev == KttyCapabilityStatus.supported.name &&
          entry.status != .supported) {
        regressions.add(entry.id);
      } else if (prev != KttyCapabilityStatus.supported.name &&
          entry.status == .supported) {
        improvements.add(entry.id);
      } else if (prev == entry.status.name) {
        unchanged.add(entry.id);
      }
    }
    for (final id in baselineStatuses.keys) {
      if (!_entries.containsKey(id)) removed.add(id);
    }

    return KttyProbeDiff(
      regressions: List<String>.unmodifiable(regressions),
      improvements: List<String>.unmodifiable(improvements),
      unchanged: List<String>.unmodifiable(unchanged),
      added: List<String>.unmodifiable(added),
      removed: List<String>.unmodifiable(removed),
    );
  }

  /// Computes actionable terminfo, environment, `XTGETTCAP`, and multiplexer
  /// diagnostic hints in pure Dart.
  List<String> buildDiagnosticHints({
    Map<String, String> environment = const {},
  }) {
    final hints = <String>[];
    void addHint(String hint) {
      if (!hints.contains(hint)) hints.add(hint);
    }

    final termEnv = (environment['TERM'] ?? '').trim();
    final colorTerm = (environment['COLORTERM'] ?? '').trim().toLowerCase();
    final hasTrueColorCap =
        _xtgettcapCapabilities.containsKey('RGB') ||
        _xtgettcapCapabilities.containsKey('Tc');

    if (termEnv.isEmpty || termEnv == 'dumb' || termEnv == 'vt100') {
      addHint(
        'Set TERM=xterm-256color (or terminal native terminfo like xterm-kitty).',
      );
    }
    if (colorTerm != 'truecolor' && colorTerm != '24bit' && !hasTrueColorCap) {
      addHint(
        'Truecolor not advertised via COLORTERM or XTGETTCAP (RGB/Tc); '
        'export COLORTERM=truecolor.',
      );
    }
    _appendProtocolDiagnosticHints(addHint);
    _appendMultiplexerDiagnosticHints(addHint);
    return List<String>.unmodifiable(hints);
  }

  void _appendProtocolDiagnosticHints(void Function(String hint) addHint) {
    if (_entries['xtgettcap']?.status == .unsupported) {
      addHint(
        'XTGETTCAP (DCS +q) unanswered; terminal or multiplexer may strip DCS queries.',
      );
    } else if (_entries['xtgettcap']?.status == .supported &&
        (!_xtgettcapCapabilities.containsKey('Smulx') ||
            !_xtgettcapCapabilities.containsKey('Setulc'))) {
      addHint(
        'Terminfo lacks Smulx/Setulc; colored or curly underlines (SGR 4:3 / 58) may degrade.',
      );
    }
    if (_entries['decrqm_2026']?.status == .unsupported &&
        !_xtgettcapCapabilities.containsKey('Sync')) {
      addHint(
        'Synchronized output (?2026 / Sync) unsupported; rapid redraws may tear.',
      );
    }
    if (_entries['osc_66_sizing']?.status == .unsupported) {
      addHint(
        'Kitty Text Sizing (OSC 66) unsupported by this terminal emulator.',
      );
    }
  }

  void _appendMultiplexerDiagnosticHints(void Function(String hint) addHint) {
    final mux = multiplexerDiagnostics;
    if (mux == null) return;
    if (mux.multiplexer == 'tmux' &&
        _entries['apc_query']?.status == .unsupported) {
      addHint(
        'Kitty Graphics failed inside tmux; enable allow-passthrough and pass --tmux-passthrough.',
      );
    }
    for (final hint in mux.hints) {
      addHint(hint);
    }
  }

  static String _formatEnvValue(Map<String, String> env, String key) {
    final trimmed = (env[key] ?? '').trim();
    return trimmed.isEmpty ? '(unset)' : trimmed;
  }

  String _formatMultiplexerStatus() {
    final mux = multiplexerDiagnostics;
    if (mux == null) return 'none';
    final passthrough = mux.allowPassthrough ?? 'unknown';
    final trueColor = mux.hasTrueColor ? 'yes' : 'no';
    return '${mux.multiplexer} (allow-passthrough=$passthrough, truecolor=$trueColor)';
  }

  /// Builds a formatted diagnostic report combining `$TERM`, `$COLORTERM`,
  /// `XTGETTCAP`, multiplexer status, and actionable remediation hints.
  String buildDiagnosticSummary({
    Map<String, String> environment = const {},
    bool ansiColor = false,
  }) {
    final colors = ansiColor
        ? (
            reset: '\x1b[0m',
            bold: '\x1b[1m',
            cyan: '\x1b[36m',
            yellow: '\x1b[33m',
            green: '\x1b[32m',
          )
        : (reset: '', bold: '', cyan: '', yellow: '', green: '');

    final termProgram = (environment['TERM_PROGRAM'] ?? '').trim();
    final capsText = _xtgettcapCapabilities.isEmpty
        ? '(none)'
        : _xtgettcapCapabilities.keys.join(', ');

    final sb = StringBuffer()
      ..writeln(
        '${colors.bold}${colors.cyan}KTTY Doctor / Environment Diagnostics${colors.reset}',
      )
      ..writeln('  TERM         : ${_formatEnvValue(environment, 'TERM')}')
      ..writeln(
        '  COLORTERM    : ${_formatEnvValue(environment, 'COLORTERM')}',
      );
    if (termProgram.isNotEmpty) {
      sb.writeln('  TERM_PROGRAM : $termProgram');
    }
    sb
      ..writeln('  XTVERSION    : ${xtVersion ?? "(unanswered)"}')
      ..writeln('  XTGETTCAP    : $capsText')
      ..writeln('  Multiplexer  : ${_formatMultiplexerStatus()}');

    final hints = buildDiagnosticHints(environment: environment);
    if (hints.isEmpty) {
      sb.writeln(
        '  ${colors.green}Status:${colors.reset} All inspected environment and protocol checks look healthy.',
      );
    } else {
      for (final hint in hints) {
        sb.writeln('  ${colors.yellow}Hint:${colors.reset} $hint');
      }
    }
    return sb.toString();
  }

  /// Serializes the capability report to a JSON-compatible map.
  Map<String, Object?> toJsonMap() => {
    'probeRunCount': probeRunCount,
    'isComplete': isComplete,
    'supportedCount': supportedCount,
    'unsupportedCount': unsupportedCount,
    'coreSupported': coreSupportedCount,
    'coreTotal': coreTotalCount,
    'coreUnsupported': coreUnsupportedCount,
    'xtVersion': xtVersion,
    'xtgettcap': _xtgettcapCapabilities,
    'kittyKeyboardFlags': kittyKeyboardFlags,
    'defaultForeground': defaultForegroundHex,
    'defaultBackground': defaultBackgroundHex,
    'colorScheme': colorScheme,
    'viewportPixelWidth': viewportPixelWidth,
    'viewportPixelHeight': viewportPixelHeight,
    'cellPixelWidth': cellPixelWidth,
    'cellPixelHeight': cellPixelHeight,
    if (multiplexerDiagnostics != null)
      'multiplexerDiagnostics': multiplexerDiagnostics!.toJsonMap(),
    'capabilities': [
      for (final e in _entries.values)
        {
          'id': e.id,
          'name': e.name,
          'protocol': e.protocol,
          'tier': e.tier.name,
          'status': e.status.name,
          'detail': e.detail,
        },
    ],
  };

  /// Formats a human-readable CLI summary table of all probed capabilities.
  String formatPlainReport({bool ansiColor = true}) {
    final sb = StringBuffer();
    final reset = ansiColor ? '\x1b[0m' : '';
    final bold = ansiColor ? '\x1b[1m' : '';
    final green = ansiColor ? '\x1b[32m' : '';
    final red = ansiColor ? '\x1b[31m' : '';
    final yellow = ansiColor ? '\x1b[33m' : '';
    final cyan = ansiColor ? '\x1b[36m' : '';

    sb.writeln(
      '$bold${cyan}KTTY Capability Probe Report$reset '
      '($coreSupportedCount/$coreTotalCount core supported, '
      '$supportedCount/${_entries.length} total)',
    );
    sb.writeln('─' * 74);
    for (final entry in _entries.values) {
      final (badge, color) = switch (entry.status) {
        .supported => ('PASS', green),
        .unsupported => ('MISS', red),
        .pending => ('WAIT', yellow),
        .optionalDisabled => ('OPT ', cyan),
      };
      final nameCol = entry.name.padRight(25);
      final protoCol = entry.protocol.padRight(14);
      sb.writeln('[$color$badge$reset] $nameCol $protoCol ${entry.detail}');
    }
    sb.writeln('─' * 74);
    _appendMultiplexerSummary(sb, yellow: yellow, reset: reset);
    return sb.toString();
  }

  void _appendMultiplexerSummary(
    StringBuffer sb, {
    required String yellow,
    required String reset,
  }) {
    final mux = multiplexerDiagnostics;
    if (mux == null) return;
    final passthrough = mux.allowPassthrough ?? 'unknown';
    final trueColor = mux.hasTrueColor ? 'yes' : 'no';
    sb.writeln(
      '${yellow}Multiplexer:$reset ${mux.multiplexer} '
      '(allow-passthrough=$passthrough, truecolor=$trueColor)',
    );
    for (final hint in mux.hints) {
      sb.writeln('  Hint: $hint');
    }
  }
}
