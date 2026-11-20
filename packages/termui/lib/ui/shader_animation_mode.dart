/// Controls when time-varying terminal fragment shaders advance their `iTime`
/// animation clock.
enum ShaderAnimationMode {
  /// Continuously advance `iTime` whenever the widget is mounted and tickers
  /// are active.
  always('always'),

  /// Advance `iTime` only while the terminal pane holds keyboard focus.
  focused('focused'),

  /// Advance `iTime` briefly after terminal output, cursor movement, or input.
  onActivity('on_activity'),

  /// Never advance `iTime`; render static shader frames only.
  staticOnly('static_only');

  /// Canonical JSON and wire identifier for this animation mode.
  final String wireName;

  const ShaderAnimationMode(this.wireName);

  /// Parses [raw] from its [wireName] (or enum [name]), returning [fallback]
  /// when [raw] is unrecognized.
  static ShaderAnimationMode fromWireName(
    Object? raw, {
    ShaderAnimationMode fallback = ShaderAnimationMode.focused,
  }) => switch (raw) {
    'always' => always,
    'focused' => focused,
    'on_activity' || 'onActivity' => onActivity,
    'static_only' || 'staticOnly' => staticOnly,
    _ => fallback,
  };
}
