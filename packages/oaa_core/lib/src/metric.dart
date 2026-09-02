// SPDX-License-Identifier: GPL-3.0-or-later

import 'meter_source.dart';

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

  // The two dynamics readings: Open Dynamic Range, this project's own
  // specification (docs/ODR.md), which is the peak-to-loudness arithmetic the
  // AES calls PSR and PLR with everything that note leaves open — the
  // channel, the window's alignment, the gate, the statistic, the display —
  // pinned down. The product prints the AES names by default, because they
  // are what every other meter prints and what a person looks for, and the
  // specification's own `ODR-S` / `ODR-I` a setting away; [labelIn] is the
  // one place the two spellings meet. "DR" is the TT Dynamic Range Meter's
  // number, a different measurement, and the one spelling this pair must not
  // have. The pair shipped as `DR-S` / `DR-I` too, and every old id still
  // resolves in [fromId], so a preset that saved a Number Box on any of them
  // opens on the same reading under its current name. The ids stay `odr_*`
  // whatever the label says: an id is a promise to files on disk.
  odrShort('odr_s', 'PSR', 'LU', 1),
  odrIntegrated('odr_i', 'PLR', 'LU', 1),

  correlation('corr', 'Correlation', '', 2),
  balance('balance', 'Balance', '', 2);

  const Metric(this.id, this.label, this.unit, this.decimals);

  /// Stable identifier for presets, reports and the wire protocol. Never
  /// change one of these; add a new metric instead.
  final String id;

  /// What a human sees next to the number, under [DynamicsNaming.defaultNaming].
  /// Anything that has the user's choice to hand asks [labelIn] instead.
  final String label;

  /// [label] under [naming]. Only the two dynamics readings have a second
  /// spelling; every other metric answers its [label] whatever is asked.
  String labelIn(DynamicsNaming naming) => switch (this) {
    Metric.odrShort => naming.short,
    Metric.odrIntegrated => naming.integrated,
    _ => label,
  };

  /// Unit suffix, or empty for dimensionless quantities.
  final String unit;

  /// Digits after the decimal point. Loudness is conventionally shown to 0.1;
  /// correlation and balance need a second digit to be readable at all.
  final int decimals;

  /// True when this metric is per-channel rather than programme-wide.
  bool get isPerChannel => this == Metric.peak || this == Metric.rms;

  /// True when this quantity is an absolute level, which the engine clamps at
  /// [MeterShape.dbFloor] instead of letting it run to negative infinity.
  ///
  /// The distinction is what [format] needs to tell a *reading* from a
  /// *clamp*: `-144.0` out of the engine does not mean the programme measured
  /// −144 dB, it means the level was at or below the floor — which for a
  /// stream of digital zeros is silence, and for anything else is a level no
  /// float this engine publishes can express. Every one of the eight below
  /// passes through `oaa_db_from_linear` or the loudness path's own clamp, and
  /// nothing else does: the ranges and differences — LRA, crest, the two ODRs
  /// — are subtractions of two levels, so their silent value is zero rather
  /// than the floor, and correlation and balance are not dB at all.
  ///
  /// Exhaustive rather than a set, so that a metric added later has to answer
  /// the question: a difference wrongly listed here would print `-∞` for a
  /// legitimate −144 LU, and a level wrongly left out prints the clamp as a
  /// measurement, which is the thing this exists to stop.
  bool get isAbsoluteLevel => switch (this) {
    Metric.lufsMomentary ||
    Metric.lufsShort ||
    Metric.lufsIntegrated ||
    Metric.truePeak ||
    Metric.truePeakMax ||
    Metric.samplePeakMax ||
    Metric.peak ||
    Metric.rms => true,
    Metric.loudnessRange ||
    Metric.crestFactor ||
    Metric.odrShort ||
    Metric.odrIntegrated ||
    Metric.correlation ||
    Metric.balance => false,
  };

  /// True when the engine holds this quantity over the programme itself,
  /// rather than over a window that has moved on by the time anybody looks.
  ///
  /// These five are computed from everything pushed since `oaa_engine_reset`;
  /// the other nine are a 400 ms, 3 s or single-block statistic. It is the
  /// difference between "what did this programme do" and "what is it doing" —
  /// so it decides what a summary of a whole programme may take an extreme
  /// over. **Two of the five converge rather than climb, which is what makes
  /// this worth stating**: `LUFS-I`, `LRA` and `ODR-I` swing wildly over their
  /// first seconds, when `LUFS-I` has cleared the −70 LUFS absolute gate on
  /// room tone and little else. An extreme taken over that swing is a fact
  /// about how the estimator converged and not about the audio — on a real
  /// master whose `ODR-I` is 8.6 LU, its minimum inside the first second is
  /// 7.6 and its maximum 33.5, and neither is a reading of anything.
  ///
  /// Two consumers, and they were written apart before this existed: the
  /// Alert Meter latches the worst of the nine and reads the five, and
  /// `analyseFile` takes a running minimum of `ODR-S` while deriving `ODR-I`
  /// from the finished figures — the same rule, reached twice, and the report
  /// says why in [AnalysisReport.odrShortMin]'s own note. `TP Max` and
  /// `Peak Max` belong here even though they only ever climb: an extreme over
  /// a running maximum is that maximum, so nothing reads differently for
  /// them, and a list that left them out would invite the question of why.
  bool get isAccumulated => switch (this) {
    Metric.lufsIntegrated ||
    Metric.loudnessRange ||
    Metric.truePeakMax ||
    Metric.samplePeakMax ||
    Metric.odrIntegrated => true,
    _ => false,
  };

  /// Whether [value] is a worse reading of this metric than [than].
  ///
  /// Which direction is "worse" is a property of the quantity, not of any
  /// target: a level is worse louder, a ratio a floor is set under is worse
  /// lower, and a correlation is worse the further into anti-phase it goes.
  /// Getting one backwards holds up the *best* moment of a programme and
  /// prints it as the worst — which is what an Alert Meter on `ODR-S` did
  /// through 0.14.0, and on `Crest` until this moved here: crest is peak minus
  /// RMS, so the highest crest of a session is its most open moment and the
  /// module was calling it the failure.
  ///
  /// **`Balance` is worse in both directions**, being signed around a centre
  /// rather than bounded at one end, so it is compared by magnitude — a mix
  /// pulled hard left is exactly as far out as one pulled hard right, and a
  /// plain `>` never noticed the left one at all.
  ///
  /// A NaN [than] is nothing yet, and anything is worse than nothing.
  bool isWorse(double value, double than) {
    if (than.isNaN) return true;
    return switch (this) {
      Metric.correlation ||
      Metric.crestFactor ||
      Metric.odrIntegrated ||
      Metric.odrShort => value < than,
      Metric.balance => value.abs() > than.abs(),
      _ => value > than,
    };
  }

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
  ///
  /// **An absolute level at [MeterShape.dbFloor] prints `-∞`, not `-144.0`.**
  /// The floor is a clamp, not a reading: every dB quantity is limited to it
  /// before it leaves C, so the number that reaches here for digital silence
  /// is a sentinel wearing four significant figures. Printed as one it is the
  /// worst kind of wrong number — plausible, precise, and measured by nobody
  /// — and it disagreed on screen with the meters beside it, whose scales
  /// label that same end of the track `-∞` already. Every level readout in the
  /// application comes through here, so this is the one place it is decided.
  ///
  /// This is a *statement about silence*, not a missing measurement: silence
  /// is a real thing for a meter to have measured, so it is `-∞` and not the
  /// em dash. Which quantities can reach the floor at all is
  /// [isAbsoluteLevel]'s question.
  String format(double value) {
    if (value.isNaN) return '—';
    if (!value.isFinite) return value.isNegative ? '-∞' : '∞';
    if (isAbsoluteLevel && value <= MeterShape.dbFloor) return '-∞';
    return value.toStringAsFixed(decimals);
  }
}

/// How the two dynamics readings are labelled: by the names the AES gives the
/// arithmetic, or by the Open Dynamic Range specification's own.
///
/// One measurement, two spellings, and never both at once — ODR § 6.4 forbids
/// presenting them as distinct, because a canvas reading `PSR 7.6` beside
/// `ODR-S 7.6` invites the question of which one is the real number. The AES
/// names are the default: Dynameter, MiRA, Nugen and Insight all print them,
/// and a mastering engineer who types "PSR" into a metric picker and finds
/// nothing concludes the meter does not measure it. The specification's names
/// exist for the reader who wants the label to say which definition it is.
///
/// This is a setting rather than a constant so that it can travel: the tablet
/// display is sent the desktop's choice over the wire, like the skin and the
/// target, so the two screens never label the same number two ways.
enum DynamicsNaming {
  psr('psr', 'PSR / PLR', short: 'PSR', integrated: 'PLR'),
  odr('odr', 'ODR-S / ODR-I', short: 'ODR-S', integrated: 'ODR-I');

  const DynamicsNaming(
    this.id,
    this.label, {
    required this.short,
    required this.integrated,
  });

  /// What is printed by an implementation that has not been asked, and what
  /// [Metric.label] answers.
  static const DynamicsNaming defaultNaming = DynamicsNaming.psr;

  /// Stable identifier, in `settings.json` and on the wire.
  final String id;

  /// What the settings panel calls this choice.
  final String label;

  /// The short-term reading's name: [Metric.odrShort].
  final String short;

  /// The integrated reading's name: [Metric.odrIntegrated].
  final String integrated;

  static DynamicsNaming? fromId(String id) {
    for (final naming in DynamicsNaming.values) {
      if (naming.id == id) return naming;
    }
    return null;
  }
}
