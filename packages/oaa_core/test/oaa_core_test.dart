// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

void main() {
  group('Metric', () {
    test('ids are unique and stable', () {
      // These strings live in saved presets, exported reports and the wire
      // protocol. A collision would silently alias two metrics; a rename would
      // invalidate every file on a user's disk.
      final ids = Metric.values.map((m) => m.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('the retired dynamics names still open on the same reading', () {
      // `DR-S` and `DR-I` were the two dynamics readings under a second name.
      // A preset that saved a Number Box on either has to open on the reading
      // it meant, under the name it has now.
      expect(Metric.fromId('dr_s'), Metric.odrShort);
      expect(Metric.fromId('dr_i'), Metric.odrIntegrated);
      for (final naming in DynamicsNaming.values) {
        final labels = Metric.values.map((m) => m.labelIn(naming));
        expect(labels, isNot(contains('DR-S')), reason: naming.id);
        expect(labels, isNot(contains('DR-I')), reason: naming.id);
      }
    });

    test('the two dynamics readings have two spellings, and only those', () {
      // ODR § 6.4: one measurement, labelled either by the AES's names or by
      // the specification's, never both at once. The AES names are the
      // default because they are what every other meter prints; the plain
      // `label` is that default, so a site that has not been handed the
      // user's choice prints the name most people are looking for.
      expect(DynamicsNaming.defaultNaming, DynamicsNaming.psr);
      for (final metric in Metric.values) {
        expect(metric.label, metric.labelIn(DynamicsNaming.defaultNaming));
      }
      expect(Metric.odrShort.labelIn(DynamicsNaming.psr), 'PSR');
      expect(Metric.odrIntegrated.labelIn(DynamicsNaming.psr), 'PLR');
      expect(Metric.odrShort.labelIn(DynamicsNaming.odr), 'ODR-S');
      expect(Metric.odrIntegrated.labelIn(DynamicsNaming.odr), 'ODR-I');
      // Every other metric has one name whatever is asked.
      for (final metric in Metric.values) {
        if (metric == Metric.odrShort || metric == Metric.odrIntegrated) {
          continue;
        }
        for (final naming in DynamicsNaming.values) {
          expect(metric.labelIn(naming), metric.label, reason: metric.id);
        }
      }
      for (final naming in DynamicsNaming.values) {
        expect(DynamicsNaming.fromId(naming.id), naming);
      }
      expect(DynamicsNaming.fromId('dr'), isNull);
    });

    test('the five the engine accumulates are named, and only those', () {
      // The line is "since reset" against "a window that has already moved
      // on", and it decides what a summary of a programme may take an extreme
      // over — an Alert Meter's latch at one end, `analyseFile`'s running
      // minima at the other.
      expect(Metric.values.where((m) => m.isAccumulated).toSet(), {
        Metric.lufsIntegrated,
        Metric.loudnessRange,
        Metric.truePeakMax,
        Metric.samplePeakMax,
        Metric.odrIntegrated,
      });
      // The pair that has to fall on opposite sides, and the reason any of
      // this is written down: ODR-S is a three-second window whose minimum is
      // a real passage of the programme, and ODR-I is derived from two figures
      // the engine is still converging on.
      expect(Metric.odrShort.isAccumulated, isFalse);
      expect(Metric.odrIntegrated.isAccumulated, isTrue);
    });

    test('worse is the direction the quantity actually fails in', () {
      // Louder is worse for a level.
      expect(Metric.lufsShort.isWorse(-8.0, -14.0), isTrue);
      expect(Metric.truePeak.isWorse(-6.0, -1.0), isFalse);

      // Lower is worse for a ratio a floor is set under, and for correlation,
      // which fails into anti-phase.
      expect(Metric.odrShort.isWorse(6.0, 9.0), isTrue);
      expect(Metric.correlation.isWorse(-0.4, 0.2), isTrue);

      // **Crest is one of those, and read the other way until 0.14.1.** It is
      // peak minus RMS, so the highest crest of a session is its most open
      // moment — held up and printed as the worst of it.
      expect(
        Metric.crestFactor.isWorse(4.0, 14.0),
        isTrue,
        reason: 'a squashed block is the failure, not the open one',
      );
      expect(Metric.crestFactor.isWorse(18.0, 14.0), isFalse);

      // Balance fails in both directions, being signed around a centre. A
      // plain `>` never noticed a mix pulled hard left at all.
      expect(Metric.balance.isWorse(-0.6, 0.3), isTrue);
      expect(Metric.balance.isWorse(0.1, -0.5), isFalse);

      // Nothing measured yet loses to everything, on every metric.
      for (final metric in Metric.values) {
        expect(metric.isWorse(0.0, double.nan), isTrue, reason: metric.label);
      }
    });

    test('every id round-trips', () {
      for (final metric in Metric.values) {
        expect(Metric.fromId(metric.id), metric);
      }
      expect(Metric.fromId('not_a_metric'), isNull);
    });

    test('NaN formats as an em dash, not as "NaN" or zero', () {
      // The whole honesty contract in one assertion: an unmeasured quantity
      // must not reach the screen looking like a reading.
      expect(Metric.lufsIntegrated.format(double.nan), '—');
      expect(Metric.lufsIntegrated.format(0), '0.0');
      // Deliberately not a .x5 value: half-way cases assert Dart's tie-breaking
      // rule, which is not something this project has an opinion about.
      expect(Metric.lufsIntegrated.format(-14.23), '-14.2');
      expect(Metric.correlation.format(-1), '-1.00');
    });

    test('infinities are shown as infinities', () {
      expect(Metric.rms.format(double.negativeInfinity), '-∞');
      expect(Metric.rms.format(double.infinity), '∞');
    });

    test('a level at the floor is silence, not a four-figure reading', () {
      // The engine clamps every dB level at the floor, so `-144.0` reaching
      // the formatter means "at or below it" and never "measured −144".
      // Printed as a number it is precise, plausible and nobody's
      // measurement — and it disagrees with the scale beside it, whose
      // bottom tick already reads `-∞`.
      expect(Metric.rms.format(MeterShape.dbFloor), '-∞');
      expect(Metric.lufsIntegrated.format(MeterShape.dbFloor), '-∞');
      expect(Metric.truePeakMax.format(MeterShape.dbFloor), '-∞');
      expect(Metric.peak.format(MeterShape.dbFloor - 10), '-∞');
      // A hair above it is a level again, and prints as one.
      expect(Metric.rms.format(MeterShape.dbFloor + 0.1), '-143.9');
    });

    test('a difference at the floor is a difference', () {
      // The ranges and the two dynamics readings are subtractions of two
      // levels, so they never reach the clamp: −144 LU is an ordinary — if
      // absurd — reading and must print as one. Listing one of these as an
      // absolute level would silently turn it into `-∞`.
      for (final metric in [
        Metric.loudnessRange,
        Metric.crestFactor,
        Metric.odrShort,
        Metric.odrIntegrated,
      ]) {
        expect(metric.isAbsoluteLevel, isFalse, reason: metric.id);
        expect(metric.format(MeterShape.dbFloor), '-144.0', reason: metric.id);
      }
    });
  });

  group('Calibration', () {
    test('built-in ids are unique and resolvable', () {
      final ids = BuiltInCalibrations.all.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final calibration in BuiltInCalibrations.all) {
        expect(BuiltInCalibrations.byId(calibration.id), same(calibration));
      }
      expect(BuiltInCalibrations.byId('nope'), isNull);
    });

    test('tolerance is a band, not a point', () {
      const streaming = BuiltInCalibrations.streaming; // -14 ± 0.5
      expect(streaming.meetsLoudnessTarget(-14.0), isTrue);
      expect(streaming.meetsLoudnessTarget(-14.5), isTrue);
      expect(streaming.meetsLoudnessTarget(-13.5), isTrue);
      expect(streaming.meetsLoudnessTarget(-14.6), isFalse);
      expect(streaming.meetsLoudnessTarget(-13.4), isFalse);
    });

    test('an unmeasured value never passes a target', () {
      // Conservative by design: NaN is not a pass, and it is not an overshoot
      // either. Callers that need the distinction check availability first.
      const streaming = BuiltInCalibrations.streaming;
      expect(streaming.meetsLoudnessTarget(double.nan), isFalse);
      expect(streaming.exceedsTruePeak(double.nan), isFalse);
      expect(streaming.exceedsLoudnessRange(double.nan), isFalse);
    });

    test('true peak ceiling is exclusive', () {
      const streaming = BuiltInCalibrations.streaming; // -1.0 dBTP
      expect(streaming.exceedsTruePeak(-1.0), isFalse);
      expect(streaming.exceedsTruePeak(-0.9), isTrue);
    });

    test('round-trips through JSON', () {
      for (final original in BuiltInCalibrations.all) {
        final restored = Calibration.fromJson(original.toJson());
        expect(restored.id, original.id);
        expect(restored.lufsTarget, original.lufsTarget);
        expect(restored.lufsTolerance, original.lufsTolerance);
        expect(restored.truePeakMax, original.truePeakMax);
        expect(restored.loudnessRangeMax, original.loudnessRangeMax);
        expect(restored.odrIntegratedFloor, original.odrIntegratedFloor);
        expect(restored.vuReference, original.vuReference);
      }
    });

    test('no built-in sets a dynamics floor, because no platform does', () {
      for (final calibration in BuiltInCalibrations.all) {
        expect(calibration.odrIntegratedFloor, isNull, reason: calibration.id);
        expect(calibration.undercutsOdrIntegrated(0.0), isFalse);
      }
    });

    test('a dynamics floor is absent from the file, not null in it', () {
      const house = Calibration(
        id: 'house',
        name: 'House',
        lufsTarget: -14,
        lufsTolerance: 0.5,
        truePeakMax: -1,
        loudnessRangeMax: 20,
        odrIntegratedFloor: 8,
      );
      final json = house.toJson();
      expect(json['odr_i_min'], 8.0);
      expect(Calibration.fromJson(json).odrIntegratedFloor, 8.0);

      final none = BuiltInCalibrations.streaming.toJson();
      expect(none.containsKey('odr_i_min'), isFalse);

      // The floor runs the other way from every other limit: under is out.
      expect(house.undercutsOdrIntegrated(7.9), isTrue);
      expect(house.undercutsOdrIntegrated(8.0), isFalse);
      expect(house.undercutsOdrIntegrated(double.nan), isFalse);

      // The second floor is independent of the first: this target has none.
      expect(house.odrShortFloor, isNull);
      expect(house.undercutsOdrShort(0.0), isFalse);
      final strict = Calibration.fromJson({...json, 'odr_s_min': 6});
      expect(strict.odrShortFloor, 6.0);
      expect(strict.undercutsOdrShort(5.9), isTrue);
      expect(strict.toJson()['odr_s_min'], 6.0);
    });
  });

  group('GridRect', () {
    test('overlap is exclusive at the shared edge', () {
      const a = GridRect(column: 0, row: 0, columns: 4, rows: 4);
      const abutting = GridRect(column: 4, row: 0, columns: 4, rows: 4);
      const overlapping = GridRect(column: 3, row: 3, columns: 4, rows: 4);

      // Two modules sharing an edge are adjacent, not colliding. Getting this
      // wrong makes it impossible to place anything next to anything.
      expect(a.overlaps(abutting), isFalse);
      expect(a.overlaps(overlapping), isTrue);
      expect(overlapping.overlaps(a), isTrue);
    });
  });

  group('layout serialisation', () {
    test('a preset round-trips', () {
      const preset = PresetSpec(
        name: 'Mastering',
        calibrationId: 'streaming-14',
        tabs: [
          TabSpec(
            name: 'Overview',
            modules: [
              ModuleSpec(
                id: 'm1',
                kind: ModuleKind.numberBox,
                rect: GridRect(column: 0, row: 0, columns: 4, rows: 2),
                options: {'metric': 'lufs_i'},
              ),
            ],
          ),
        ],
      );

      final restored = PresetSpec.fromJson(preset.toJson());
      expect(restored.name, 'Mastering');
      expect(restored.calibrationId, 'streaming-14');
      expect(restored.tabs.single.modules.single.kind, ModuleKind.numberBox);
      expect(restored.tabs.single.modules.single.metric, Metric.lufsIntegrated);
    });

    test('a module kind this build lacks is skipped, not fatal', () {
      // A preset written by a newer version must still open. Losing one module
      // beats refusing the file.
      final json = {
        'name': 'From the future',
        'tabs': [
          {
            'name': 'Tab',
            'modules': [
              {
                'id': 'a',
                'kind': 'holographic_meter',
                'rect': {'c': 0, 'r': 0, 'w': 4, 'h': 4},
              },
              {
                'id': 'b',
                'kind': 'number_box',
                'rect': {'c': 4, 'r': 0, 'w': 2, 'h': 1},
              },
            ],
          },
        ],
      };

      final preset = PresetSpec.fromJson(json);
      expect(preset.tabs.single.modules, hasLength(1));
      expect(preset.tabs.single.modules.single.id, 'b');
    });

    test('an absent calibration means "follow the preset"', () {
      // Null is not a missing value here, it is a mode. See PresetSpec's doc
      // comment: null follows the preset, a concrete id was pinned by the user
      // and must survive opening another one.
      final preset = PresetSpec.fromJson({'name': 'X', 'tabs': const []});
      expect(preset.calibrationId, isNull);
      expect(preset.toJson().containsKey('calibration'), isFalse);
    });

    test('copyWith can clear a carried id as well as set one', () {
      // The File menu's two rows move these between null and an id in both
      // directions, and `copyWith(calibrationId: null)` cannot mean "clear" —
      // it is indistinguishable from not passing it at all.
      const preset = PresetSpec(
        name: 'X',
        tabs: [TabSpec(name: 'T', modules: [])],
        calibrationId: 'ebu-r128',
        skinId: 'daylight',
      );

      expect(preset.copyWith(name: 'Y').calibrationId, 'ebu-r128');
      expect(
        preset.copyWith(calibrationId: 'streaming-14').calibrationId,
        'streaming-14',
      );
      expect(preset.copyWith(clearCalibrationId: true).calibrationId, isNull);
      expect(preset.copyWith(clearCalibrationId: true).skinId, 'daylight');
      expect(preset.copyWith(clearSkinId: true).skinId, isNull);
    });

    group('tryFromJson', () {
      // What a file dialog hands back is any file at all, so this answers null
      // where `fromJson` throws. See its doc comment.
      test('accepts what fromJson accepts', () {
        const preset = PresetSpec(
          name: 'Mastering',
          tabs: [TabSpec(name: 'T', modules: [])],
        );
        expect(PresetSpec.tryFromJson(preset.toJson())?.name, 'Mastering');
      });

      test('refuses a document with no name', () {
        expect(
          PresetSpec.tryFromJson({
            'tabs': [
              {'name': 'T', 'modules': const []},
            ],
          }),
          isNull,
        );
      });

      test('refuses a document with no tabs', () {
        // `loadPreset` ignores an empty preset, so without this the interface
        // would report a successful open and show the layout already on screen.
        expect(PresetSpec.tryFromJson({'name': 'X', 'tabs': const []}), isNull);
      });

      test('refuses something that is not a preset at all', () {
        // A skin, which is the file most likely to be picked by mistake: it
        // lives in the directory next door and has the same extension.
        expect(
          PresetSpec.tryFromJson({
            'id': 'daylight',
            'name': 'Daylight',
            'colors': const <String, Object?>{},
          }),
          isNull,
        );
      });

      test('refuses a tab that is not shaped like one', () {
        expect(
          PresetSpec.tryFromJson({
            'name': 'X',
            'tabs': ['not a map'],
          }),
          isNull,
        );
      });
    });
  });

  group('the Alert Meter\'s settings', () {
    ModuleSpec alert(Map<String, Object?> options) => ModuleSpec(
      id: 'm',
      kind: ModuleKind.alertMeter,
      rect: const GridRect(column: 0, row: 0, columns: 4, rows: 3),
      options: options,
    );

    test('watches true peak until it is told otherwise', () {
      // The kind's own default, and the reason the module existed for four
      // phases with no metric row in its menu: it was the only reading it
      // could ever have been showing.
      //
      // The **live** reading, not the maximum since reset. Both print the same
      // number on a latch — the largest windowed peak of a session is that
      // session's peak — but only one of them is latched at all: `TP Max` is
      // the engine's to hold, so an Alert Meter on it reads rather than
      // latches, and the module shipped by default with the one behaviour it
      // exists for switched off.
      expect(alert(const {}).metric, Metric.truePeak);
      expect(alert(const {}).metric.isAccumulated, isFalse);
      expect(alert({'metric': 'lufs_i'}).metric, Metric.lufsIntegrated);
      expect(alert({'metric': 'lra'}).metric, Metric.loudnessRange);
    });

    test('states what it measured until it is asked for the distance', () {
      expect(alert(const {}).alertDelta, isFalse);
      expect(alert({'delta': true}).alertDelta, isTrue);
      expect(alert({'delta': false}).alertDelta, isFalse);
      // Anything that is not the boolean is off — the same rule the
      // oscilloscope's box follows, and what every preset written before this
      // existed meant.
      expect(alert({'delta': 'on'}).alertDelta, isFalse);
      expect(alert({'delta': 1}).alertDelta, isFalse);
    });

    test('carries both settings through a round trip', () {
      final spec = alert({'metric': 'lufs_i', 'delta': true});
      final back = ModuleSpec.fromJson(spec.toJson())!;
      expect(back.metric, Metric.lufsIntegrated);
      expect(back.alertDelta, isTrue);
    });
  });

  group('the Validator\'s checks', () {
    ModuleSpec validator(Map<String, Object?> options) => ModuleSpec(
      id: 'm',
      kind: ModuleKind.validator,
      rect: const GridRect(column: 0, row: 0, columns: 6, rows: 4),
      options: options,
    );

    test('judges everything until it is told otherwise', () {
      // What every preset written before the setting existed meant, and what a
      // freshly placed Validator opens on: a delivery table that starts by
      // leaving something out is one whose verdict cannot be read without
      // opening the menu first.
      expect(validator(const {}).validatorChecks, ValidatorCheck.values);
    });

    test('keeps an empty list empty', () {
      // The statement that separates "nothing chosen" from "nothing said". A
      // module the user emptied on purpose that silently refilled itself would
      // be the only setting here that does not stay put.
      expect(validator({'checks': const []}).validatorChecks, isEmpty);
    });

    test('reads the chosen ones in the order the table prints them', () {
      // Declaration order, not the file's. A preset lists whatever order the
      // rows were ticked in, and a table that reordered itself to match would
      // stop mirroring the report it exists to agree with.
      expect(
        validator({
          'checks': const ['odr_s', 'lufs_i'],
        }).validatorChecks,
        [ValidatorCheck.lufsIntegrated, ValidatorCheck.odrShort],
      );
    });

    test('ignores an id it does not know', () {
      // A preset written by a newer version names a check this build has never
      // heard of. It is not a check here, and it is not a parse failure either
      // — see the note on `ModuleSpec.options`.
      expect(
        validator({
          'checks': const ['lufs_i', 'phase_of_the_moon'],
        }).validatorChecks,
        [ValidatorCheck.lufsIntegrated],
      );
      // And a value that is not a list at all is a preset that says nothing.
      expect(
        validator({'checks': 'lufs_i'}).validatorChecks,
        ValidatorCheck.values,
      );
    });

    test('carries the set through a round trip', () {
      final spec = validator({
        'checks': const ['lufs_i', 'tp_max'],
      });
      final back = ModuleSpec.fromJson(spec.toJson())!;
      expect(back.validatorChecks, [
        ValidatorCheck.lufsIntegrated,
        ValidatorCheck.truePeak,
      ]);
    });

    test('only the dynamics rows depend on the target', () {
      // The three loudness criteria are in every target by construction; the
      // two floors are optional, and a row a target says nothing about is a
      // row that could not be judged. See `Calibration.odrIntegratedFloor`.
      const withoutFloors = Calibration(
        id: 'test_no_floors',
        name: 'No floors',
        lufsTarget: -14,
        lufsTolerance: 0.5,
        truePeakMax: -1,
        loudnessRangeMax: 20,
      );
      const withFloors = Calibration(
        id: 'test_floors',
        name: 'Floors',
        lufsTarget: -14,
        lufsTolerance: 0.5,
        truePeakMax: -1,
        loudnessRangeMax: 20,
        odrIntegratedFloor: 8,
        odrShortFloor: 6,
      );

      for (final check in ValidatorCheck.values) {
        expect(
          check.judgedBy(withoutFloors),
          check != ValidatorCheck.odrIntegrated &&
              check != ValidatorCheck.odrShort,
          reason: '${check.label} against a target with no dynamics floor',
        );
        expect(check.judgedBy(withFloors), isTrue, reason: check.label);
      }
    });

    test('names its rows after the metrics they judge, bar one', () {
      // The PSR row is judged against the lowest reading since the reset,
      // not the live one, and says so — a row reading `PSR` beside a number
      // that is not the PSR every other module is showing would be read as a
      // disagreement. It follows the metric's spelling, so under the
      // specification's names it is the ODR-S row that says MIN.
      expect(ValidatorCheck.lufsIntegrated.label, Metric.lufsIntegrated.label);
      expect(ValidatorCheck.odrShort.label, 'PSR MIN');
      expect(ValidatorCheck.odrShort.labelIn(DynamicsNaming.odr), 'ODR-S MIN');
      expect(ValidatorCheck.odrIntegrated.labelIn(DynamicsNaming.odr), 'ODR-I');
      expect(
        ValidatorCheck.lufsIntegrated.labelIn(DynamicsNaming.odr),
        Metric.lufsIntegrated.label,
      );
      // And its id is its metric's, so a preset holds one spelling of each.
      for (final check in ValidatorCheck.values) {
        expect(check.id, check.metric.id);
      }
    });
  });

  group('the oscilloscope\'s numbers', () {
    ModuleSpec scope(Map<String, Object?> options) => ModuleSpec(
      id: 'm',
      kind: ModuleKind.oscilloscope,
      rect: const GridRect(column: 0, row: 0, columns: 12, rows: 5),
      options: options,
    );

    test('a height written by the four-step menu still reads', () {
      // The steps this replaced were stored under the ids `1`, `2`, `4` and
      // `8`, which are the multipliers spelled — so every preset and every
      // restored session written before the zoom was continuous names a scale
      // this build understands. If this fails, somebody's layout silently
      // reverts to 1x.
      expect(scope({'zoom': '4'}).scopeZoom, 4);
      expect(scope({'zoom': '8'}).scopeZoom, 8);
      expect(scope({'zoom': 2.5}).scopeZoom, 2.5);
    });

    test('a height nothing set, or set to nonsense, is full scale', () {
      expect(scope(const {}).scopeZoom, ScopeZoom.defaultScale);
      expect(scope({'zoom': 'huge'}).scopeZoom, ScopeZoom.defaultScale);
      expect(scope({'zoom': double.nan}).scopeZoom, ScopeZoom.defaultScale);
      // Clamped rather than refused: a preset from a build with a longer
      // slider is still a preset worth opening.
      expect(scope({'zoom': 999}).scopeZoom, ScopeZoom.max);
      expect(scope({'zoom': -4}).scopeZoom, ScopeZoom.min);
    });

    test('the slider is even in octaves and prints multipliers', () {
      expect(ScopeZoom.scaleAt(0), ScopeZoom.min);
      expect(ScopeZoom.scaleAt(ScopeZoom.octaves), ScopeZoom.max);
      expect(ScopeZoom.scaleAt(1), 2);
      expect(ScopeZoom.scaleAt(3), 8);
      // Half the travel is the first quarter of the range, which is the whole
      // reason the control is not linear in the multiplier.
      expect(ScopeZoom.positionOf(8), closeTo(ScopeZoom.octaves * 0.6, 0.01));
      expect(ScopeZoom.label(4), '4.0x');
    });

    test('a level in dB is an amplitude a sample can be compared to', () {
      expect(ScopeThreshold.amplitude(0), closeTo(1, 1e-9));
      expect(ScopeThreshold.amplitude(-6), closeTo(0.5012, 1e-4));
      expect(ScopeThreshold.amplitude(-20), closeTo(0.1, 1e-9));
      // What is stored is what was printed — a control that commits more
      // precision than it shows has a readout of something else.
      expect(ScopeThreshold.quantise(-11.7323), -11.7);
      expect(ScopeThreshold.label(-12), '-12.0 dB');
    });

    test('a level nothing set is under the peaks and over the sustain', () {
      expect(scope(const {}).scopeThresholdDb, ScopeThreshold.defaultDb);
      expect(scope({'threshold': -30.0}).scopeThresholdDb, -30);
      expect(scope({'threshold': 12.0}).scopeThresholdDb, ScopeThreshold.maxDb);
      expect(
        scope({'threshold': 'loud'}).scopeThresholdDb,
        ScopeThreshold.defaultDb,
      );
    });

    test('AUTO sets the level under the peak, never at it', () {
      // Six decibels under, which is half the amplitude: the trigger fires on
      // a rising crossing, so a level at the top of the attack starts the
      // sweep at the peak and draws only the decay.
      expect(ScopeThreshold.autoAt(1), -ScopeThreshold.autoMarginDb);
      expect(ScopeThreshold.autoAt(0.5), -12);
      // Rounded to the step the slider moves in, not to the tenth a drag
      // stores: this one follows the audio, and a tenth of a decibel per
      // published block is forty-seven rebuilds a second of a line nobody can
      // see move.
      expect(ScopeThreshold.autoAt(0.8), -8);
      // Nothing to trigger on is not a measurement. The caller keeps the level
      // it had rather than dropping it onto the noise floor.
      expect(ScopeThreshold.autoAt(0), isNull);
      expect(ScopeThreshold.autoAt(-0.5), isNull);
      expect(ScopeThreshold.autoAt(0.0001), isNull);
    });

    test('the level follows the material only where it was asked to', () {
      expect(scope(const {}).scopeAutoThreshold, isFalse);
      expect(scope({'autoThreshold': true}).scopeAutoThreshold, isTrue);
      expect(scope({'autoThreshold': false}).scopeAutoThreshold, isFalse);
      // Anything that is not the boolean is off, which is what every preset
      // written before the box existed meant.
      expect(scope({'autoThreshold': 'yes'}).scopeAutoThreshold, isFalse);
      expect(scope({'autoThreshold': 1}).scopeAutoThreshold, isFalse);
    });

    test('a trigger nothing set is the one that always draws something', () {
      expect(scope(const {}).scopeTrigger, ScopeTrigger.auto);
      expect(scope(const {}).scopeTrigger.sweeps, isFalse);
      expect(scope({'trigger': 'transient'}).scopeTrigger.sweeps, isTrue);
      expect(scope({'trigger': 'chorus'}).scopeTrigger, ScopeTrigger.auto);
    });

    test('the channel in front is the left one until it is swapped', () {
      // The order the module drew in before the setting existed, which is what
      // every preset written before it means.
      expect(scope(const {}).scopeFront, ScopeFront.left);
      expect(scope({'front': 'right'}).scopeFront, ScopeFront.right);
      expect(scope({'front': 'middle'}).scopeFront, ScopeFront.left);
      expect(ScopeFront.left.swapped, ScopeFront.right);
      expect(ScopeFront.right.swapped, ScopeFront.left);
    });
  });

  group('ColorRamp', () {
    ModuleSpec module(ModuleKind kind, Map<String, Object?> options) =>
        ModuleSpec(
          id: 'm',
          kind: kind,
          rect: const GridRect(column: 0, row: 0, columns: 12, rows: 7),
          options: options,
        );

    test('both modules open on the skin ramp', () {
      // The default is the picture the two modules drew before the setting
      // existed, which is also the honest one — see ColorRamp. A preset that
      // says nothing must not come back rainbowed.
      expect(
        module(ModuleKind.spectrogram, const {}).colorRamp,
        ColorRamp.skin,
      );
      expect(
        module(ModuleKind.oscilloscope, const {}).colorRamp,
        ColorRamp.skin,
      );
    });

    test('the ids are the ones written into presets', () {
      expect(ColorRamp.fromId('skin'), ColorRamp.skin);
      expect(ColorRamp.fromId('rgb'), ColorRamp.rgb);
      expect(
        module(ModuleKind.spectrogram, {'ramp': 'rgb'}).colorRamp,
        ColorRamp.rgb,
      );
    });

    test('a ramp this build does not have is the default, not a failure', () {
      // An option map is written by other versions of this application and by
      // hand. A name nothing recognises leaves the module drawing something.
      expect(ColorRamp.fromId('turbo'), isNull);
      expect(
        module(ModuleKind.spectrogram, {'ramp': 'turbo'}).colorRamp,
        ColorRamp.skin,
      );
      expect(
        module(ModuleKind.spectrogram, {'ramp': 7}).colorRamp,
        ColorRamp.skin,
      );
    });

    test('the ramp survives a round trip through a preset', () {
      final restored = ModuleSpec.fromJson(
        module(ModuleKind.oscilloscope, {'ramp': 'rgb'}).toJson(),
      );
      expect(restored!.colorRamp, ColorRamp.rgb);
    });
  });

  group('SpectrumTilt', () {
    test('the pivot is the one level a tilt does not move', () {
      for (final tilt in SpectrumTilt.values) {
        expect(tilt.dbAt(SpectrumTilt.pivotHz), closeTo(0, 1e-9));
      }
    });

    test('an octave is worth what the setting says', () {
      // Above the pivot and below it, because a tilt that only added is an
      // offset with a slope and would take the whole picture off the top of
      // the scale.
      expect(SpectrumTilt.db4p5.dbAt(2000), closeTo(4.5, 1e-9));
      expect(SpectrumTilt.db4p5.dbAt(500), closeTo(-4.5, 1e-9));
      expect(SpectrumTilt.db3.dbAt(8000), closeTo(9, 1e-9));
      expect(SpectrumTilt.db0.dbAt(20000), 0);
    });

    test('the ends of the analyser sit where 4.5 dB an octave puts them', () {
      // 20 Hz to 20 kHz is 9.97 octaves, and the default rotates them apart by
      // 45 dB of the scale's 96. Pinned because it is the number that decides
      // whether a tilted mix fits on the plot at all.
      final low = SpectrumTilt.db4p5.dbAt(20);
      final high = SpectrumTilt.db4p5.dbAt(20000);
      expect(low, closeTo(-25.4, 0.1));
      expect(high, closeTo(19.4, 0.1));
      expect(high - low, closeTo(44.8, 0.1));
    });

    test('ids are unique and round-trip', () {
      final ids = SpectrumTilt.values.map((t) => t.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final tilt in SpectrumTilt.values) {
        expect(SpectrumTilt.fromId(tilt.id), tilt);
      }
      expect(SpectrumTilt.fromId('4.5 dB/oct'), isNull);
    });

    test('a module with no tilt written down draws the default', () {
      const spec = ModuleSpec(
        id: 'm1',
        kind: ModuleKind.spectrumAnalyzer,
        rect: GridRect(column: 0, row: 0, columns: 6, rows: 4),
      );
      expect(spec.spectrumTilt, SpectrumTilt.db4p5);
      expect(
        spec.copyWith(options: const {'tilt': '0'}).spectrumTilt,
        SpectrumTilt.db0,
      );
      // A tilt this build does not have, from a preset written by a newer one.
      expect(
        spec.copyWith(options: const {'tilt': '9'}).spectrumTilt,
        SpectrumTilt.db4p5,
      );
    });

    test('a module with no range written down draws 90 dB', () {
      for (final range in SpectrumRange.values) {
        expect(SpectrumRange.fromId(range.id), range);
        // The step divides the range, or the floor would carry no gridline.
        expect(range.decibels % range.step, 0);
      }
      expect(SpectrumRange.fromId('90 dB'), isNull);

      const spec = ModuleSpec(
        id: 'm1',
        kind: ModuleKind.spectrumAnalyzer,
        rect: GridRect(column: 0, row: 0, columns: 6, rows: 4),
      );
      expect(spec.spectrumRange, SpectrumRange.db90);
      expect(
        spec.copyWith(options: const {'range': '60'}).spectrumRange,
        SpectrumRange.db60,
      );
      // A range this build does not have, from a preset written by a newer one.
      expect(
        spec.copyWith(options: const {'range': '150'}).spectrumRange,
        SpectrumRange.db90,
      );
    });
  });

  group('ModuleKind', () {
    test('ids are unique and round-trip', () {
      final ids = ModuleKind.values.map((k) => k.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final kind in ModuleKind.values) {
        expect(ModuleKind.fromId(kind.id), kind);
      }
    });

    test('every module fits the canvas', () {
      for (final kind in ModuleKind.values) {
        expect(
          kind.minColumns,
          lessThanOrEqualTo(kGridColumns),
          reason: '${kind.id} cannot fit in a $kGridColumns-column grid',
        );
        expect(kind.minColumns, greaterThan(0));
        expect(kind.minRows, greaterThan(0));
      }
    });
  });

  // What a relay needs from a transport, and nothing the wire golden already
  // covers. `packages/oaa_wire/test/plugin_golden_test.dart` holds the timecode
  // arithmetic and the bar counting against bytes the plugin produced; these two
  // exist because the desktop forwards a plugin's playhead to its displays, and
  // both of them are how it decides what to send.
  group('Transport', () {
    const flags =
        Transport.flagPlaying |
        Transport.flagHasTimeSeconds |
        Transport.flagHasBpm;
    const rolling = Transport(flags: flags, timeSeconds: 12.5, bpm: 128);

    test('a playhead that moved is not the playhead that was sent', () {
      // The comparison the relay sends on. Ordinary playback changes nothing
      // *but* the position, so a transport that compared equal here would put
      // one frame on the wire and then hold a frozen clock on every tablet in
      // the building for the length of the session.
      expect(rolling, rolling);
      expect(
        rolling,
        isNot(const Transport(flags: flags, timeSeconds: 12.6, bpm: 128)),
      );
      expect(rolling.hashCode, rolling.hashCode);
    });

    test('stopping is a change, at the same position', () {
      // Two readings of the same frame, one rolling and one parked. The flags
      // are the only difference and it is the difference a display draws.
      const parked = Transport(
        flags: Transport.flagHasTimeSeconds | Transport.flagHasBpm,
        timeSeconds: 12.5,
        bpm: 128,
      );
      expect(parked, isNot(rolling));
    });

    test('an edge can be carried onto a later frame', () {
      final flagged = rolling.asDiscontinuous();

      expect(rolling.isDiscontinuous, isFalse);
      expect(flagged.isDiscontinuous, isTrue);

      // Everything else survives: the frame this becomes still reports the
      // position the playhead landed on, which is what `docs/WIRE.md` requires
      // of the frame that carries the bit.
      expect(flagged.timeSeconds, rolling.timeSeconds);
      expect(flagged.bpm, rolling.bpm);
      expect(flagged.isPlaying, isTrue);
      expect(flagged.hasBpm, isTrue);

      // And it is the same reading, so it must not compare equal to the one
      // without the edge — a relay that sends on change has to see this.
      expect(flagged, isNot(rolling));
    });

    test('carrying an edge that is already there changes nothing', () {
      final once = rolling.asDiscontinuous();
      expect(once.asDiscontinuous(), once);
      expect(identical(once.asDiscontinuous(), once), isTrue);
    });

    test('nothing known is nothing known', () {
      expect(Transport.none.isPresent, isFalse);
      expect(const Transport(), Transport.none);
    });
  });
}
