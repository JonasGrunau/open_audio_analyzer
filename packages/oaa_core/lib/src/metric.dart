// SPDX-License-Identifier: GPL-3.0-or-later

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

  // Open Dynamic Range, the two dynamics readings of this project's own
  // standard — defined in docs/METRICS.md, and the same arithmetic as the PSR
  // and PLR of AES TD1004 with the operands the AES leaves open pinned down.
  // They were offered as `PSR` / `PLR` and as `DR-S` / `DR-I` before the name
  // was chosen; "DR" is the TT Dynamic Range Meter's number, a different
  // measurement, which is the one spelling this pair must not have. Every old
  // id still resolves, in [fromId], so a preset that saved a Number Box on any
  // of them opens on the same reading under its current name.
  odrShort('odr_s', 'ODR-S', 'LU', 1),
  odrIntegrated('odr_i', 'ODR-I', 'LU', 1),

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
    return switch (id) {
      // Retired spellings of the two dynamics readings. Never reuse any of
      // these ids for anything else: a preset written under one means this.
      'psr' || 'dr_s' => Metric.odrShort,
      'plr' || 'dr_i' => Metric.odrIntegrated,
      _ => null,
    };
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
