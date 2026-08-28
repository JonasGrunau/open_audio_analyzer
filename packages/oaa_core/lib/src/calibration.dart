// SPDX-License-Identifier: GPL-3.0-or-later

/// A delivery target: the contract a mix is being measured against.
///
/// Decibel calls this a "Calibration" and treats it as a first-class object,
/// separate from both the layout and the colour scheme, so that the same screen
/// of meters can be pointed at a different platform without being rebuilt. That
/// separation is worth copying exactly — it is the difference between "a meter"
/// and "a tool you deliver with".
///
/// Every field is a number somebody publishes, so every field is data. The
/// built-in library below is compiled in only because it has to start
/// somewhere; the loader treats it identically to a JSON file a user dropped in
/// their config directory, which is what makes the set community-editable
/// without a release.
class Calibration {
  const Calibration({
    required this.id,
    required this.name,
    required this.lufsTarget,
    required this.lufsTolerance,
    required this.truePeakMax,
    required this.loudnessRangeMax,
    this.odrIntegratedFloor,
    this.odrShortFloor,
    this.vuReference = -18.0,
    this.note = '',
  });

  /// Stable identifier, stored in presets.
  final String id;

  /// What the user picks from a menu.
  final String name;

  /// Integrated loudness to aim for, LUFS.
  final double lufsTarget;

  /// How far from [lufsTarget] still counts as hitting it, LU.
  ///
  /// Decibel defaults this to 0.5, which is the tolerance most delivery specs
  /// state, and it matters more than it looks: without it every target is a
  /// pass/fail on an infinitely thin line, and no real programme lands there.
  final double lufsTolerance;

  /// Ceiling above which true peak is reported as an overshoot, dBTP.
  final double truePeakMax;

  /// Loudness range above which the programme is flagged as too dynamic for
  /// the target, LU.
  final double loudnessRangeMax;

  /// ODR-I — true peak max over integrated loudness — below which the
  /// programme is flagged as too compressed for the target, LU; or null, when
  /// the target sets no floor.
  ///
  /// The one limit here that runs the other way: everything else is a ceiling,
  /// and this is what stops a master being *squashed* to hit the ceiling. It is
  /// also the one limit no platform publishes. Every streaming service states a
  /// normalisation level and most state a peak ceiling; none states how much
  /// dynamic range it wants, so none of the built-in targets carries a floor
  /// and a file that omits `odr_i_min` gets none. It exists for the specs that do
  /// say — a label's house standard, a mastering engineer's own line, the
  /// "ODR-I of 8 or better" that circulates as advice — and for those it is a
  /// number in a file rather than a feature request.
  ///
  /// Nullable where the others are not, deliberately. A floor of zero would
  /// pass everything and read as a real requirement in every place the target
  /// is printed; "none" is a different statement from "at least nothing".
  final double? odrIntegratedFloor;

  /// ODR-S — true peak over short-term loudness — below which any three
  /// seconds of the programme count as too compressed, LU; or null for no
  /// floor.
  ///
  /// The stricter of the two floors, and the one a "too loud" rule actually
  /// means. [odrIntegratedFloor] is one peak against the whole programme's
  /// loudness, and a quiet intro with a single transient in it rescues a
  /// chorus that has been flattened; this is checked against the *lowest* ODR-S
  /// the programme reached, which is the chorus after the limiter. In a
  /// report that is the ODR-S minimum; on the canvas the Validator keeps its own
  /// since the last reset, and a Number Box on ODR-S turns red the moment the
  /// live reading dips under.
  final double? odrShortFloor;

  /// The dBFS level that reads as 0 VU. Only the VU meter uses it.
  final double vuReference;

  /// Free text shown under the name — where the numbers come from.
  final String note;

  /// Whether an integrated loudness reading meets this target.
  ///
  /// NaN is not a pass. It is not a fail either, but callers that only ask this
  /// question get the conservative answer; ask [isMeasured] first if the
  /// difference matters.
  bool meetsLoudnessTarget(double lufsIntegrated) {
    if (lufsIntegrated.isNaN) return false;
    return (lufsIntegrated - lufsTarget).abs() <= lufsTolerance;
  }

  bool exceedsTruePeak(double truePeakDbtp) {
    if (truePeakDbtp.isNaN) return false;
    return truePeakDbtp > truePeakMax;
  }

  bool exceedsLoudnessRange(double lra) {
    if (lra.isNaN) return false;
    return lra > loudnessRangeMax;
  }

  /// Whether an ODR-I reading falls short of this target's floor.
  ///
  /// False when the target sets none, and false for NaN — the same
  /// conservative shape as the other three: an unmeasured reading is neither a
  /// pass nor a fail, and a target with no floor has nothing to fail.
  bool undercutsOdrIntegrated(double odrI) {
    final floor = odrIntegratedFloor;
    if (floor == null || odrI.isNaN) return false;
    return odrI < floor;
  }

  /// The same question of an ODR-S — live, or the programme's lowest.
  bool undercutsOdrShort(double odrS) {
    final floor = odrShortFloor;
    if (floor == null || odrS.isNaN) return false;
    return odrS < floor;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'lufs_target': lufsTarget,
    'lufs_tolerance': lufsTolerance,
    'true_peak_max': truePeakMax,
    'lra_max': loudnessRangeMax,
    // Absent rather than null, so a file written by the editor reads the same
    // as one written by hand that never mentioned it.
    if (odrIntegratedFloor != null) 'odr_i_min': odrIntegratedFloor,
    if (odrShortFloor != null) 'odr_s_min': odrShortFloor,
    'vu_reference': vuReference,
    if (note.isNotEmpty) 'note': note,
  };

  factory Calibration.fromJson(Map<String, Object?> json) => Calibration(
    id: json['id']! as String,
    name: json['name']! as String,
    lufsTarget: (json['lufs_target']! as num).toDouble(),
    lufsTolerance: (json['lufs_tolerance'] as num?)?.toDouble() ?? 0.5,
    truePeakMax: (json['true_peak_max']! as num).toDouble(),
    loudnessRangeMax: (json['lra_max'] as num?)?.toDouble() ?? 20.0,
    odrIntegratedFloor: (json['odr_i_min'] as num?)?.toDouble(),
    odrShortFloor: (json['odr_s_min'] as num?)?.toDouble(),
    vuReference: (json['vu_reference'] as num?)?.toDouble() ?? -18.0,
    note: json['note'] as String? ?? '',
  );
}

/// The targets Open Audio Analyzer ships with.
///
/// These are the platforms' own published numbers, not folklore. Where a
/// platform states only a normalisation level and no peak ceiling, the −1 dBTP
/// convention is used and said so in the note, because lossy transcoding
/// downstream of delivery routinely adds a few tenths of a dB and a file
/// mastered to 0 dBTP will clip after it.
abstract final class BuiltInCalibrations {
  static const streaming = Calibration(
    id: 'streaming-14',
    name: 'Streaming (−14 LUFS)',
    lufsTarget: -14.0,
    lufsTolerance: 0.5,
    truePeakMax: -1.0,
    loudnessRangeMax: 20.0,
    note:
        'Spotify, Apple Music, YouTube, Amazon and Tidal all normalise to '
        'about −14 LUFS.',
  );

  static const spotifyLoud = Calibration(
    id: 'spotify-11',
    name: 'Spotify Loud',
    lufsTarget: -11.0,
    lufsTolerance: 0.5,
    truePeakMax: -2.0,
    loudnessRangeMax: 20.0,
    note:
        'Spotify\'s optional loud setting. It asks for −2 dBTP because it '
        'turns masters down, and limiting on playback would otherwise clip.',
  );

  static const podcast = Calibration(
    id: 'podcast-16',
    name: 'Podcast (−16 LUFS)',
    lufsTarget: -16.0,
    lufsTolerance: 0.5,
    truePeakMax: -1.0,
    loudnessRangeMax: 8.0,
    note:
        'Apple Podcasts and most spoken-word delivery. The tight LRA is '
        'deliberate: speech that swings widely is unlistenable in a car.',
  );

  static const ebuR128 = Calibration(
    id: 'ebu-r128',
    name: 'EBU R 128 (broadcast)',
    lufsTarget: -23.0,
    lufsTolerance: 0.5,
    truePeakMax: -1.0,
    loudnessRangeMax: 20.0,
    vuReference: -18.0,
    note: 'European broadcast. −23 LUFS, −1 dBTP.',
  );

  static const atscA85 = Calibration(
    id: 'atsc-a85',
    name: 'ATSC A/85 (US broadcast)',
    lufsTarget: -24.0,
    lufsTolerance: 2.0,
    truePeakMax: -2.0,
    loudnessRangeMax: 20.0,
    vuReference: -20.0,
    note:
        'US broadcast. The ±2 LU tolerance is the one the spec itself '
        'states.',
  );

  static const cd = Calibration(
    id: 'cd',
    name: 'CD / no normalisation',
    lufsTarget: -9.0,
    lufsTolerance: 3.0,
    truePeakMax: -0.3,
    loudnessRangeMax: 30.0,
    note:
        'No platform normalisation. The target is a loose convention, not a '
        'spec — watch true peak, not LUFS.',
  );

  static const List<Calibration> all = [
    streaming,
    spotifyLoud,
    podcast,
    ebuR128,
    atscA85,
    cd,
  ];

  static const Calibration fallback = streaming;

  static Calibration? byId(String id) {
    for (final calibration in all) {
      if (calibration.id == id) return calibration;
    }
    return null;
  }
}

/// The built-ins with the user's own files laid over them, by id.
///
/// A user file whose id matches a built-in **replaces** it rather than sitting
/// beside it, which is what makes the built-in list correctable without a
/// release: somebody who disagrees with our reading of ATSC A/85 writes an
/// `atsc-a85.json` and their number wins everywhere the id appears — including
/// in presets that already reference it.
///
/// One implementation, because there are two front ends. The app merged its
/// library in a provider and the `oaa` CLI did not merge at all: it knew the six
/// built-ins and nothing else, so the same corrected file passed in one and
/// failed in the other, and the CLI's exit code is the one a release pipeline
/// believes. Two answers to "what does this target require" is the one thing a
/// delivery check cannot have.
List<Calibration> mergeCalibrations(
  List<Calibration> base,
  List<Calibration> overrides,
) {
  final byId = <String, Calibration>{
    for (final calibration in base) calibration.id: calibration,
  };
  for (final calibration in overrides) {
    byId[calibration.id] = calibration;
  }
  return List.unmodifiable(byId.values);
}
