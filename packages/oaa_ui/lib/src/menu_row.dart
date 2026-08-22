// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'tokens.dart';

/// One row of a popup menu, and the fill that marks the value the menu holds.
///
/// **The current value is recessed, not brightened.** Every menu in the
/// application marked its selection with [OaaColors.textPrimary] against
/// [OaaColors.textMuted] and nothing else, which made the lightest row in the
/// menu the one choice pressing it cannot change, and left the options you can
/// still take reading as the disabled ones. Selection everywhere else in this
/// interface is a fill — a list row, a segment of a segmented control — so a
/// menu that carried it in ink alone was also the one control that expressed
/// selection differently from the rest of the panel it opened over. The row
/// that is already chosen sits in a well; the options above and below it sit on
/// the raised surface the menu is drawn on.
///
/// The fill is [OaaColors.background] and not [OaaColors.panel] because a menu
/// is *already* drawn on [OaaColors.panelRaised], and `panel` is one step from
/// it — 0x121417 against 0x171A1E in Precision Instrument, 0xFAFBFC against
/// white in Daylight. That is a fill nobody can see. `background` is the
/// deepest surface in both shipped skins, which is what makes the direction
/// legible rather than merely present, and a skin that names a background
/// lighter than its own raised panel has bigger problems than this row.
///
/// It owns the row's padding because the fill has to span it. A
/// `PopupMenuItem` pads its own child, so a decoration built inside that
/// padding stops short of the menu's edges and reads as a floating chip rather
/// than as a seated row. Callers build the item with `padding:
/// EdgeInsets.zero` and `height: OaaMenuRow.height`, and this supplies the same
/// [Space.md] inset Material would have.
///
/// **The one widget in this package handed its palette instead of reading it.**
/// A menu is a route: `showMenu` builds its items under the `Navigator`, which
/// sits above `MaterialApp.home`, and unlike `showOaaPanel` it re-provides
/// nothing. `OaaApp` installs the palette above the navigator so an
/// `OaaTheme.of` here does resolve in the running application — and asserts in
/// any tree that wraps only its home, which is what five tests in
/// `canvas_test.dart` and `shortcuts_test.dart` did the moment this widget read
/// its own colours. Every call site already resolves the palette for the menu's
/// surface colour anyway; this takes the same value. Do not "tidy" it into an
/// `OaaTheme.of(context)`.
class OaaMenuRow extends StatelessWidget {
  const OaaMenuRow({
    required this.colors,
    required this.selected,
    required this.child,
    super.key,
  });

  /// The palette, resolved by the caller. See the note above.
  final OaaColors colors;

  /// Whether this row is the value the menu currently holds.
  final bool selected;

  /// The row's content. A label, or a label and a mark.
  final Widget child;

  /// What the `PopupMenuItem` above one of these must be built with.
  ///
  /// The fill cannot stretch to the item's height from inside it —
  /// `PopupMenuItem` aligns its child rather than stretching it — so the row
  /// states the height instead of inheriting it, and an item built to a
  /// different one would show a fill that does not reach its own edges.
  static const double height = OaaControl.height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Padding(
        // The fill insets from the menu's hairline rather than meeting it: the
        // menu's corners are rounded and its `Material` does not clip, so a
        // full-bleed fill on the first or last row would paint over the arc.
        // Together with the inner padding this is [Space.md] a side, which is
        // what `PopupMenuItem` pads with when left to itself.
        padding: const EdgeInsets.symmetric(
          horizontal: Space.xs,
          vertical: Space.xxs,
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: selected ? colors.background : null,
            borderRadius: OaaRadius.allSm,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.smd),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}
