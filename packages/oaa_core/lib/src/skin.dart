// SPDX-License-Identifier: MIT

/// A skin: the palette, as data.
///
/// The whole point of this file is that a skin is a JSON document a user writes
/// in a text editor, not a Dart class somebody compiles. Decibel ships skins as
/// opaque binary resources, which means the set of skins is whatever shipped;
/// ours is whatever anybody drops in a directory. That only works if the palette
/// is a closed, named set of *semantic* roles — "the colour that means over" —
/// rather than a set of literal colours a painter picks from. A skin that had to
/// name `spectrumPeakHoldLine` would break every time a module was added.
///
/// This lives in `oaa_core` and therefore stores integers rather than
/// `dart:ui` `Color`s: the tablet display, the CLI and the plugin all parse
/// presets and none of them may drag Flutter in. `oaa_ui` owns the one adapter
/// that turns these into a `OaaColors`.
library;

/// The roles a skin assigns a colour to.
///
/// Every value here is a field of `OaaColors` in `oaa_ui`, and the pairing is
/// asserted by a test in that package rather than by a comment here — the two
/// lists living in different packages is the price of `oaa_core` staying free of
/// Flutter, and an unchecked price is a price that gets paid later.
enum SkinColor {
  background('background'),
  panel('panel'),
  panelRaised('panel_raised'),
  hairline('hairline'),
  hairlineStrong('hairline_strong'),
  textPrimary('text_primary'),
  textMuted('text_muted'),
  textFaint('text_faint'),
  accent('accent'),
  warn('warn'),
  over('over'),
  meterTrack('meter_track'),
  meterFill('meter_fill');

  const SkinColor(this.key);

  /// The key this role has in a skin file. Stable — renaming one silently
  /// reverts that role to the default in every skin anybody has written.
  final String key;

  static SkinColor? fromKey(String key) {
    for (final role in SkinColor.values) {
      if (role.key == key) return role;
    }
    return null;
  }
}

/// A named palette.
///
/// [colors] is allowed to be partial. A skin that only wants to change the
/// accent says so in three lines and inherits the rest, which is the difference
/// between a format people edit and a format people copy-paste-and-abandon.
/// Resolution against the base happens in [resolve], not at parse time, so a
/// skin file round-trips through [toJson] as the sparse thing its author wrote.
class Skin {
  const Skin({
    required this.id,
    required this.name,
    required this.colors,
    this.isLight = false,
    this.note = '',
  });

  /// Stable identifier. Stored in presets and in settings.
  final String id;

  /// What the user picks from a menu.
  final String name;

  /// Role → 0xAARRGGBB. May omit roles; see [resolve].
  final Map<SkinColor, int> colors;

  /// Whether this palette is dark text on a light ground.
  ///
  /// Not derivable reliably from the background alone, and it decides one thing
  /// no colour can: which system chrome brightness the window asks for. A light
  /// skin under a dark title bar looks like a rendering bug.
  final bool isLight;

  /// Free text shown under the name.
  final String note;

  /// The colour for [role], falling back to [base] and finally to the built-in
  /// default.
  ///
  /// Never returns null and never throws. A skin file with a typo in one key
  /// renders with one wrong colour; the alternative — refusing to load — turns a
  /// typo into an app that will not start.
  int resolve(SkinColor role, {Skin? base}) =>
      colors[role] ??
      base?.colors[role] ??
      BuiltInSkins.precisionInstrument.colors[role]!;

  /// This skin with every role filled in.
  Skin resolved({Skin? base}) => Skin(
    id: id,
    name: name,
    isLight: isLight,
    note: note,
    colors: {
      for (final role in SkinColor.values) role: resolve(role, base: base),
    },
  );

  Skin copyWith({String? id, String? name, Map<SkinColor, int>? colors}) =>
      Skin(
        id: id ?? this.id,
        name: name ?? this.name,
        colors: colors ?? this.colors,
        isLight: isLight,
        note: note,
      );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    if (isLight) 'light': true,
    if (note.isNotEmpty) 'note': note,
    'colors': {
      for (final entry in colors.entries) entry.key.key: formatHex(entry.value),
    },
  };

  /// Parses a skin, or returns null if it is not one.
  ///
  /// Tolerant by design: unknown colour keys are ignored (a skin written for a
  /// later version loads and simply does not colour the role this build has not
  /// got), and an unparseable value is skipped rather than fatal. Only a missing
  /// id or name is refused, because a skin with neither cannot be selected or
  /// stored.
  static Skin? fromJson(Map<String, Object?> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || id.isEmpty) return null;
    if (name is! String || name.isEmpty) return null;

    final colors = <SkinColor, int>{};
    final raw = json['colors'];
    if (raw is Map) {
      for (final entry in raw.entries) {
        final role = SkinColor.fromKey('${entry.key}');
        if (role == null) continue;
        final value = parseColor(entry.value);
        if (value != null) colors[role] = value;
      }
    }

    return Skin(
      id: id,
      name: name,
      colors: colors,
      isLight: json['light'] == true,
      note: json['note'] as String? ?? '',
    );
  }

  /// Accepts `#RGB`, `#RRGGBB`, `#AARRGGBB` (with or without the `#`) and a
  /// plain integer.
  ///
  /// Hex strings are what a human writes and what every other tool in a
  /// designer's life uses; integers are what a machine-generated skin will
  /// contain. Supporting both costs eight lines.
  static int? parseColor(Object? value) {
    if (value is int) return value & 0xFFFFFFFF;
    if (value is! String) return null;

    var text = value.trim();
    if (text.startsWith('#')) text = text.substring(1);
    if (text.startsWith('0x') || text.startsWith('0X')) {
      text = text.substring(2);
    }

    // #RGB shorthand, because people write it and being the one tool that
    // rejects it is not a principled stand.
    if (text.length == 3) {
      text = text.split('').map((digit) => '$digit$digit').join();
    }

    final parsed = int.tryParse(text, radix: 16);
    if (parsed == null) return null;

    return switch (text.length) {
      6 => 0xFF000000 | parsed, // opaque by default
      8 => parsed,
      _ => null,
    };
  }

  static String formatHex(int argb) {
    final alpha = (argb >> 24) & 0xFF;
    final rgb = (argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0');
    return alpha == 0xFF
        ? '#$rgb'.toUpperCase()
        : '#${alpha.toRadixString(16).padLeft(2, '0')}$rgb'.toUpperCase();
  }
}

/// The skins Open Audio Analyzer ships with.
///
/// Two, and deliberately two. A built-in skin is a maintenance obligation — it
/// has to be re-checked every time a module introduces a new way of using a
/// role — and the value of a third dark variant is close to zero once users can
/// write their own. What the pair does buy is proof that the roles are
/// semantic: [daylight] inverts the entire lightness ordering, and if any
/// painter had reached for "the dark one" instead of a role it would be obvious
/// immediately.
abstract final class BuiltInSkins {
  /// Graphite, one signal hue, no gradients. The default.
  ///
  /// These are the same values as `OaaColors.precisionInstrument`, and a test in
  /// `oaa_ui` asserts they have not drifted apart.
  static const Skin precisionInstrument = Skin(
    id: 'precision-instrument',
    name: 'Precision Instrument',
    note: 'The default. Graphite, one signal hue, no gradients.',
    colors: {
      SkinColor.background: 0xFF0B0C0E,
      SkinColor.panel: 0xFF121417,
      SkinColor.panelRaised: 0xFF171A1E,
      SkinColor.hairline: 0xFF1F2328,
      SkinColor.hairlineStrong: 0xFF5A646E,
      SkinColor.textPrimary: 0xFFE6E8EB,
      SkinColor.textMuted: 0xFF8A9199,
      SkinColor.textFaint: 0xFF565E67,
      SkinColor.accent: 0xFF35E0C4,
      SkinColor.warn: 0xFFF2B01E,
      SkinColor.over: 0xFFFF4D4D,
      SkinColor.meterTrack: 0xFF323942,
      SkinColor.meterFill: 0xFF6E7A85,
    },
  );

  /// Dark ink on paper, for a room with a window in it.
  ///
  /// The accent, warn and over hues are all darker than their dark-skin
  /// counterparts rather than the same colour on a different ground: `#35E0C4`
  /// on white is a little over 1.5:1 against the panel and effectively
  /// unreadable at readout sizes. Keeping the *hue* and moving the *value* is
  /// what makes "in spec" still read as the same idea.
  static const Skin daylight = Skin(
    id: 'daylight',
    name: 'Daylight',
    isLight: true,
    note: 'For a bright room. Same hues, values inverted.',
    colors: {
      SkinColor.background: 0xFFEDEFF2,
      SkinColor.panel: 0xFFFAFBFC,
      SkinColor.panelRaised: 0xFFFFFFFF,
      SkinColor.hairline: 0xFFDDE1E6,
      SkinColor.hairlineStrong: 0xFF828C96,
      SkinColor.textPrimary: 0xFF14171A,
      SkinColor.textMuted: 0xFF4E565E,
      SkinColor.textFaint: 0xFF8A9199,
      SkinColor.accent: 0xFF00806B,
      SkinColor.warn: 0xFF9A6A00,
      SkinColor.over: 0xFFC62828,
      SkinColor.meterTrack: 0xFFC2C9D1,
      SkinColor.meterFill: 0xFF7A848E,
    },
  );

  static const List<Skin> all = [precisionInstrument, daylight];

  static const Skin fallback = precisionInstrument;

  static Skin? byId(String id) {
    for (final skin in all) {
      if (skin.id == id) return skin;
    }
    return null;
  }
}
