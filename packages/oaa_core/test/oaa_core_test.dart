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
}
