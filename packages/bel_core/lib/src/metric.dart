// SPDX-License-Identifier: MIT

/// Everything the engine can measure, as a closed set.
///
/// This enum is the vocabulary a Number Box picks from, the key a report is
/// serialised under, and the identifier that travels over the wire to a remote
/// display. Those three uses are why [id] is declared explicitly rather than
/// derived from the enum name: a rename in Dart must not silently invalidate
/// every saved preset and every stored report on disk.
enum Metric {
  lufsMomentary('lufs_m', 'LUFS-M', 'LUFS', 1),
  lufsShort('lufs_s', 'LUFS-S', 'LUFS', 1),
  lufsIntegrated('lufs_i', 'LUFS-I', 'LUFS', 1),
  loudnessRange('lra', 'LRA', 'LU', 1),

  truePeak('tp', 'True Peak', 'dBTP', 1),
  truePeakMax('tp_max', 'TP Max', 'dBTP', 1),
  samplePeakMax('peak_max', 'Peak Max', 'dBFS', 1),
  peak('peak', 'Peak', 'dBFS', 1),
  rms('rms', 'RMS', 'dBFS', 1),

  crestFactor('crest', 'Crest', 'dB', 1),
  dynamicRangeShort('dr_s', 'DR-S', 'LU', 1),
  dynamicRangeIntegrated('dr_i', 'DR-I', 'LU', 1),
  peakToLoudnessRatio('plr', 'PLR', 'LU', 1),
  peakToShortTermRatio('psr', 'PSR', 'LU', 1),

  correlation('corr', 'Correlation', '', 2),
  balance('balance', 'Balance', '', 2);

  const Metric(this.id, this.label, this.unit, this.decimals);

  /// Stable identifier for presets, reports and the wire protocol. Never
  /// change one of these; add a new metric instead.
  final String id;

  /// What a human sees next to the number.
  final String label;

  /// Unit suffix, or empty for dimensionless quantities.
  final String unit;

  /// Digits after the decimal point. Loudness is conventionally shown to 0.1;
  /// correlation and balance need a second digit to be readable at all.
  final int decimals;

  /// True when this metric is per-channel rather than programme-wide.
  bool get isPerChannel => this == Metric.peak || this == Metric.rms;

  static Metric? fromId(String id) {
    for (final metric in Metric.values) {
      if (metric.id == id) return metric;
    }
    return null;
  }

  /// Format [value] for display.
  ///
  /// A NaN reading means the engine does not measure this quantity in this
  /// build, and it renders as an em dash. That is the whole reason this
  /// function exists rather than a bare `toStringAsFixed`: `NaN.toStringAsFixed`
  /// produces the string "NaN", which looks like a bug report waiting to
  /// happen, and `0.0` — the other obvious placeholder — looks like a
  /// measurement.
  String format(double value) {
    if (value.isNaN) return '—';
    if (!value.isFinite) return value.isNegative ? '-∞' : '∞';
    return value.toStringAsFixed(decimals);
  }
}
