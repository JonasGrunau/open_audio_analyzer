// SPDX-License-Identifier: MIT

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
        expect(restored.vuReference, original.vuReference);
      }
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
      // and must survive browsing.
      final preset = PresetSpec.fromJson({'name': 'X', 'tabs': const []});
      expect(preset.calibrationId, isNull);
      expect(preset.toJson().containsKey('calibration'), isFalse);
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
