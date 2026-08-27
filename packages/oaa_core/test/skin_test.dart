// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:test/test.dart';

void main() {
  group('SkinColor', () {
    test('keys are unique and round-trip', () {
      // These strings are the schema of every skin file anybody writes.
      // Renaming one silently reverts that role to the default in all of them.
      final keys = SkinColor.values.map((role) => role.key).toList();
      expect(keys.toSet().length, keys.length);

      for (final role in SkinColor.values) {
        expect(SkinColor.fromKey(role.key), role);
      }
      expect(SkinColor.fromKey('not_a_role'), isNull);
    });
  });

  group('colour parsing', () {
    test('accepts the forms a human writes', () {
      expect(Skin.parseColor('#35E0C4'), 0xFF35E0C4);
      expect(Skin.parseColor('35e0c4'), 0xFF35E0C4);
      expect(Skin.parseColor('0x35E0C4'), 0xFF35E0C4);
      expect(Skin.parseColor('#8035E0C4'), 0x8035E0C4);
      expect(Skin.parseColor('  #35E0C4  '), 0xFF35E0C4);
      expect(Skin.parseColor(0xFF35E0C4), 0xFF35E0C4);
    });

    test('expands #RGB shorthand', () {
      expect(Skin.parseColor('#0AF'), 0xFF00AAFF);
    });

    test('a colour without an alpha is opaque', () {
      // The alternative — defaulting to transparent — produces a skin that
      // loads without error and renders an invisible interface.
      expect(Skin.parseColor('#000000'), 0xFF000000);
    });

    test('rejects what is not a colour', () {
      for (final bad in ['', 'teal', '#12345', '#GGGGGG', '#1234567', null]) {
        expect(Skin.parseColor(bad), isNull, reason: 'accepted $bad');
      }
    });

    test('formats back to the shortest exact form', () {
      expect(Skin.formatHex(0xFF35E0C4), '#35E0C4');
      expect(Skin.formatHex(0x8035E0C4), '#8035E0C4');
    });
  });

  group('Skin', () {
    test('a sparse skin inherits every role it does not name', () {
      // This is the property that makes the format worth having: changing one
      // colour is a three-line file, not a thirteen-line one.
      const accentOnly = Skin(
        id: 'accent-only',
        name: 'Accent only',
        colors: {SkinColor.accent: 0xFFFF00FF},
      );

      expect(accentOnly.resolve(SkinColor.accent), 0xFFFF00FF);
      expect(
        accentOnly.resolve(SkinColor.background),
        BuiltInSkins.precisionInstrument.colors[SkinColor.background],
      );
    });

    test('resolves against an explicit base before the default', () {
      const sparse = Skin(id: 'sparse', name: 'Sparse', colors: {});
      expect(
        sparse.resolve(SkinColor.background, base: BuiltInSkins.daylight),
        BuiltInSkins.daylight.colors[SkinColor.background],
      );
    });

    test('resolved() fills in every role', () {
      const sparse = Skin(id: 'sparse', name: 'Sparse', colors: {});
      final full = sparse.resolved();
      expect(full.colors.length, SkinColor.values.length);
      for (final role in SkinColor.values) {
        expect(full.colors[role], isNotNull);
      }
    });

    test('round-trips through JSON', () {
      final json = BuiltInSkins.daylight.toJson();
      final parsed = Skin.fromJson(json)!;

      expect(parsed.id, BuiltInSkins.daylight.id);
      expect(parsed.name, BuiltInSkins.daylight.name);
      expect(parsed.isLight, isTrue);
      expect(parsed.colors, BuiltInSkins.daylight.colors);
    });

    test('a sparse skin round-trips sparse', () {
      // Writing back the thirteen resolved values would quietly turn "follow
      // the default" into "pin these colours", and the skin would stop tracking
      // a later change to the palette it was derived from.
      const sparse = Skin(
        id: 'sparse',
        name: 'Sparse',
        colors: {SkinColor.accent: 0xFF112233},
      );
      final parsed = Skin.fromJson(sparse.toJson())!;
      expect(parsed.colors.length, 1);
    });

    test('an unknown colour key is ignored, not fatal', () {
      // A skin written for a later version of Open Audio Analyzer has to load
      // in this one.
      final parsed = Skin.fromJson({
        'id': 'future',
        'name': 'Future',
        'colors': {'accent': '#112233', 'spectrogram_floor': '#445566'},
      })!;

      expect(parsed.colors[SkinColor.accent], 0xFF112233);
      expect(parsed.colors.length, 1);
    });

    test('an unparseable colour costs that colour and nothing else', () {
      final parsed = Skin.fromJson({
        'id': 'typo',
        'name': 'Typo',
        'colors': {'accent': 'not a colour', 'over': '#FF0000'},
      })!;

      expect(parsed.colors.containsKey(SkinColor.accent), isFalse);
      expect(parsed.colors[SkinColor.over], 0xFFFF0000);
      expect(parsed.resolve(SkinColor.accent), isNotNull);
    });

    test('refuses a document that is not a skin', () {
      expect(Skin.fromJson({'name': 'No id'}), isNull);
      expect(Skin.fromJson({'id': 'no-name'}), isNull);
      expect(Skin.fromJson({'id': '', 'name': ''}), isNull);
    });

    test('a skin with no colours at all still renders', () {
      final parsed = Skin.fromJson({'id': 'empty', 'name': 'Empty'})!;
      for (final role in SkinColor.values) {
        expect(parsed.resolve(role), isNotNull);
      }
    });
  });

  group('BuiltInSkins', () {
    test('every built-in defines every role', () {
      // A sparse *user* skin is fine because it falls back to a built-in. A
      // sparse built-in has nothing behind it.
      for (final skin in BuiltInSkins.all) {
        for (final role in SkinColor.values) {
          expect(
            skin.colors[role],
            isNotNull,
            reason: '${skin.id} does not define ${role.key}',
          );
        }
      }
    });

    test('ids are unique and resolvable', () {
      final ids = BuiltInSkins.all.map((skin) => skin.id).toList();
      expect(ids.toSet().length, ids.length);
      for (final id in ids) {
        expect(BuiltInSkins.byId(id), isNotNull);
      }
      expect(BuiltInSkins.byId('nothing'), isNull);
    });

    test('the roles that carry meaning are distinguishable', () {
      // In spec, approaching a limit and over a limit are three different
      // answers to the same question. A skin that renders any two of them as
      // the same colour has removed the meter's ability to say which.
      for (final skin in BuiltInSkins.all) {
        final signals = {
          skin.colors[SkinColor.accent],
          skin.colors[SkinColor.warn],
          skin.colors[SkinColor.over],
        };
        expect(signals.length, 3, reason: '${skin.id} reuses a signal colour');
      }
    });

    test('the light skin is marked as one', () {
      expect(BuiltInSkins.daylight.isLight, isTrue);
      expect(BuiltInSkins.precisionInstrument.isLight, isFalse);
    });
  });
}
