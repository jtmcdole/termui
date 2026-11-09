import 'ktty_probe_assets.dart';

/// Support state for an individual terminal capability probe.
enum KttyCapabilityStatus {
  /// Query sent; awaiting terminal reply or `DA1` sentinel.
  pending,

  /// Terminal replied positively to the capability query.
  supported,

  /// Terminal either rejected the capability or ignored it prior to `DA1`.
  unsupported,
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

  /// Current probe status.
  KttyCapabilityStatus status;

  /// Decoded detail string or error explanation.
  String detail;

  /// Creates a capability row entry.
  KttyCapabilityEntry({
    required this.id,
    required this.name,
    required this.protocol,
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

  /// Terminal version string reported by `XTVERSION` (`DCS > | ... ST`), if any.
  String? xtVersion;

  /// Kitty keyboard progressive enhancement bitmask reported by `CSI ? flags u`.
  int? kittyKeyboardFlags;

  /// Default foreground color reported by `OSC 10`, normalized to `#RRGGBB`.
  String? defaultForegroundHex;

  /// Default background color reported by `OSC 11`, normalized to `#RRGGBB`.
  String? defaultBackgroundHex;

  /// Most recent `OSC 52` clipboard read payload, if the host replied to `OSC 52;?`.
  String? osc52ClipboardReply;

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

  /// Creates a [KttyProbeReport] initialized with all standard KTTY probe entries.
  KttyProbeReport() {
    _initEntries();
  }

  void _initEntries() {
    final specs = <(String, String, String)>[
      ('apc_query', 'Kitty Graphics Query', 'APC a=q'),
      ('apc_rgba', 'Kitty Graphics RGBA32', 'APC f=32'),
      ('apc_zlib', 'Kitty Graphics Zlib', 'APC o=z'),
      ('apc_png', 'Kitty Graphics PNG', 'APC f=100'),
      ('kitty_kb', 'Kitty Keyboard Protocol', 'CSI ? u'),
      ('xtversion', 'Terminal Identity', 'XTVERSION'),
      ('osc10', 'Default Foreground', 'OSC 10;?'),
      ('osc11', 'Default Background', 'OSC 11;?'),
      ('decrqm_2026', 'Synchronized Output', 'DECRQM ?2026'),
      ('decrqm_1016', 'SGR-Pixels Mouse', 'DECRQM ?1016'),
      ('decrqm_2027', 'Grapheme Clustering', 'DECRQM ?2027'),
      ('decrqm_2004', 'Bracketed Paste', 'DECRQM ?2004'),
      ('decrqm_1004', 'Focus Reporting', 'DECRQM ?1004'),
      ('decrqm_1006', 'SGR Mouse Encoding', 'DECRQM ?1006'),
      ('xtwinops_18t', 'Text Grid Size', 'CSI 18 t'),
      ('da2', 'Secondary Device Attrs', 'CSI > c'),
      ('da1', 'Primary DA Sentinel', 'CSI c'),
    ];
    for (final (id, name, proto) in specs) {
      _entries[id] = KttyCapabilityEntry(id: id, name: name, protocol: proto);
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
    lastOsc99Ack = _defaultOsc99Ack;
    hasOsc99Ack = false;
    for (final entry in _entries.values) {
      entry.status = .pending;
      entry.detail = 'Probing...';
    }
    _notify();
  }

  /// Builds the wire-protocol query burst ending with the `DA1` (`\x1b[c`) sentinel.
  static String buildWireProbeSequence() {
    final sb = StringBuffer()
      ..write(buildKittyApcProbeCommands())
      ..write('\x1b[?u')
      ..write('\x1b[>0q')
      ..write('\x1b]10;?\x1b\\')
      ..write('\x1b]11;?\x1b\\')
      ..write('\x1b[?2026\$p')
      ..write('\x1b[?1016\$p')
      ..write('\x1b[?2027\$p')
      ..write('\x1b[?2004\$p')
      ..write('\x1b[?1004\$p')
      ..write('\x1b[?1006\$p')
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

  /// Records a Kitty Graphics `APC` reply (`ESC _ G i=<id>;<status> ESC \`).
  void recordApcReply(int imageId, String statusMessage) {
    final ok = statusMessage.trim().toUpperCase() == 'OK';
    final key = switch (imageId) {
      kttyProbeQueryId => 'apc_query',
      kttyProbeRgbaId => 'apc_rgba',
      kttyProbeZlibId => 'apc_zlib',
      kttyProbePngId => 'apc_png',
      _ => null,
    };
    if (key == null) return;
    _updateEntry(
      key,
      ok ? .supported : .unsupported,
      ok ? 'OK (i=$imageId)' : statusMessage,
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
    xtVersion = version;
    _updateEntry('xtversion', .supported, version);
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

  /// Records cell pixel dimensions reported by `XTWINOPS 16t` (`CSI 6 ; h ; w t`).
  void recordCellPixelSize(int widthPx, int heightPx) {
    if (widthPx > 0) cellPixelWidth = widthPx;
    if (heightPx > 0) cellPixelHeight = heightPx;
    _notify();
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

  /// Records the Primary Device Attributes (`DA1`) sentinel and marks any
  /// earlier unanswered queries as [KttyCapabilityStatus.unsupported].
  void recordDa1Sentinel(String params) {
    _updateEntry('da1', .supported, 'CSI ? $params c', notify: false);
    finalizePending('No reply before DA1');
  }

  /// Marks any remaining [KttyCapabilityStatus.pending] probes as unsupported.
  void finalizePending(String reason) {
    for (final entry in _entries.values) {
      if (entry.status == .pending) {
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
    'xtVersion': xtVersion,
    'kittyKeyboardFlags': kittyKeyboardFlags,
    'defaultForeground': defaultForegroundHex,
    'defaultBackground': defaultBackgroundHex,
    'capabilities': [
      for (final e in _entries.values)
        {
          'id': e.id,
          'name': e.name,
          'protocol': e.protocol,
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
      '($supportedCount/${_entries.length} supported)',
    );
    sb.writeln('─' * 74);
    for (final entry in _entries.values) {
      final (badge, color) = switch (entry.status) {
        .supported => ('PASS', green),
        .unsupported => ('MISS', red),
        .pending => ('WAIT', yellow),
      };
      final nameCol = entry.name.padRight(25);
      final protoCol = entry.protocol.padRight(14);
      sb.writeln('[$color$badge$reset] $nameCol $protoCol ${entry.detail}');
    }
    sb.writeln('─' * 74);
    return sb.toString();
  }
}
