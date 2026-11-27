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

  /// Creates [KttyProbeOptions].
  const KttyProbeOptions({
    this.wrapTmuxPassthrough = false,
    this.tempProbeFilePath,
    this.shmProbeName,
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

  /// Creates a [KttyProbeReport] initialized with all 28 standard KTTY probe entries.
  KttyProbeReport() {
    _initEntries();
  }

  void _initEntries() {
    final specs = <(String, String, String, KttyCapabilityTier)>[
      ('apc_query', 'Kitty Graphics Query', 'APC a=q', .core),
      ('apc_rgba', 'Kitty Graphics RGBA32', 'APC f=32', .core),
      ('apc_zlib', 'Kitty Graphics Zlib', 'APC o=z', .core),
      ('apc_png', 'Kitty Graphics PNG', 'APC f=100', .core),
      ('apc_chunked', 'Kitty Graphics Chunked', 'APC m=1/0', .core),
      ('apc_place_persist', 'Kitty Place Persistence', 'APC d=a/a=p', .core),
      ('apc_image_num', 'Kitty Image Number', 'APC I=', .core),
      ('apc_temp_file', 'Kitty Temp File Medium', 'APC t=t', .optional),
      ('apc_shm', 'Kitty Shared Memory', 'APC t=s', .optional),
      ('kitty_kb', 'Kitty Keyboard Protocol', 'CSI ? u', .core),
      ('xtversion', 'Terminal Identity', 'XTVERSION', .core),
      ('osc10', 'Default Foreground', 'OSC 10;?', .core),
      ('osc11', 'Default Background', 'OSC 11;?', .core),
      ('osc_22_pointer', 'Mouse Pointer Shapes', 'OSC 22;?', .core),
      ('osc_99_query', 'Notification Query', 'OSC 99;p=?', .core),
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
  void resetForNewProbe() {
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
    for (final entry in _entries.values) {
      entry.status = .pending;
      entry.detail = 'Probing...';
    }
    _notify();
  }

  static final RegExp _controlCharsRegex = RegExp(r'[\x00-\x1F\x7F-\x9F]');
  static const int _maxDetailLength = 200;

  static String _sanitizeDetail(String raw) {
    final cleaned = raw.replaceAll(_controlCharsRegex, '').trim();
    return cleaned.length <= _maxDetailLength
        ? cleaned
        : '${cleaned.substring(0, _maxDetailLength)}...';
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
      ..write('\x1b]10;?\x1b\\')
      ..write('\x1b]11;?\x1b\\')
      ..write('\x1b]22;?pointer,text,ktty-invalid\x1b\\')
      ..write('\x1b]99;i=ktty-probe:p=?;\x1b\\')
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
      kttyProbeTempId => 'apc_temp_file',
      kttyProbeShmId => 'apc_shm',
      _ => null,
    };
  }

  static String _formatApcOkDetail(
    int imageId, {
    int? imageNumber,
    int? placementId,
  }) {
    if (imageNumber != null) {
      return imageId > 0
          ? 'OK (i=$imageId,I=$imageNumber)'
          : 'OK (I=$imageNumber)';
    }
    if (placementId != null) return 'OK (i=$imageId,p=$placementId)';
    return 'OK (i=$imageId)';
  }

  /// Records a Kitty Graphics `APC` reply (`ESC _ G i=<id>,I=<num>,p=<pid>;<status> ESC \`).
  void recordApcReply(
    int imageId,
    String statusMessage, {
    int? imageNumber,
    int? placementId,
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
          )
        : trimmed;
    _updateEntry(key, status, detail);
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
