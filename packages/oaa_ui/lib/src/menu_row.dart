// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import 'glyph.dart';
import 'tokens.dart';

/// One row of a popup menu, and the two marks that say which value it holds.
///
/// **The current value is a band and a check, not brighter ink.** Every menu in
/// the application marked its selection with [OaaColors.textPrimary] against
/// [OaaColors.textMuted] and nothing else, which made the lightest row in the
/// menu the one choice pressing it cannot change, and left the options you can
/// still take reading as the disabled ones. Selection everywhere else in this
/// interface is a fill — a list row, a segment of a segmented control — so a
/// menu that carried it in ink alone was also the one control that expressed
/// selection differently from the rest of the panel it opened over.
///
/// **The band is [OaaColors.hairlineStrong] at a quarter of its strength, and
/// it used to be [OaaColors.background].** That was the deepest surface in the
/// skin, chosen so the row would be *recessed* rather than brightened; what it
/// produced in Precision Instrument was a near-black band inside a menu drawn
/// two steps above it — a hole punched in the menu rather than a row of it.
/// `hairlineStrong` is what the rest of a panel already means by selection —
/// see the role — and the only change here is that a row is an area rather than
/// an edge, so it is laid down as a wash instead of as a two-pixel border. It
/// is mixed *into* the menu's own surface, so the band moves with the skin
/// rather than being a colour of its own, and the direction is whichever way
/// that skin runs: up from `panelRaised` in a dark skin, down from white in a
/// light one. Direction is not what carries the signal any more — the check is.
///
/// **The quarter is a measurement, not a taste.** `hairline` was tried first,
/// on the reasoning that a hairline is by definition the smallest step a skin
/// can take and still be seen; it comes out at 1.09:1 against `panelRaised` in
/// Precision Instrument and 1.31:1 in Daylight, so one value gave two
/// noticeably different strengths and the dark skin got the weak one. This mix
/// is about 1.22:1 in both, which is legible without the band competing with
/// the label sitting on it.
///
/// **The band spans the menu, edge to edge.** It used to inset itself by
/// [Space.xs] a side with a small radius, on the reasoning that the menu's
/// corners are rounded and its `Material` does not clip, so a full-bleed fill
/// on the first or last row would paint over the arc. That reasoning was about
/// a menu with no padding of its own, and there is no such menu here: Material
/// pads the item list by 8 px top and bottom (`PopupMenuThemeData.menuPadding`,
/// which nothing in this repository overrides) — twice [OaaRadius.sm] — so the
/// first row starts well below the corner and the band meets two straight
/// sides. An inset fill reads as a chip that happens to be sitting in a menu;
/// a full-bleed one reads as the row being selected, which is what it is. **A
/// call site that sets `menuPadding: EdgeInsets.zero` must also pass
/// `clipBehavior: Clip.antiAlias`,** or it gets the corner back.
///
/// **[selected] is tri-state, and `null` is not `false`.** A menu of actions —
/// add a module, rename a tab — holds no value: it takes `null`, gets no band
/// and no check column, and its rows sit where a menu row has always sat.
/// `false` is the stronger claim that this row is an option in a menu that
/// *has* a current value and is not it, which is what reserves the column: the
/// rows that are not the value indent by exactly as much as the row that is, or
/// the labels step sideways every time the value moves and the menu reads as
/// two lists.
///
/// **[reservesCheck] is that third case for a menu that is both.** The File
/// menu is four actions and two toggles, and tri-state alone gave it two
/// columns of labels with a divider between them — the actions where a menu
/// row has always sat, the toggles a check's width to the right of them, in one
/// menu that a Mac draws in the system bar with every label in one column. A
/// row that can never carry a check still keeps its column when the menu it is
/// in has rows that can.
///
/// It owns the row's padding because the fill has to span it. A
/// `PopupMenuItem` pads its own child, so a decoration built inside that
/// padding stops short of the menu's edges. Callers build the item with
/// `padding: EdgeInsets.zero` and `height: OaaMenuRow.height`, and this
/// supplies the same [Space.md] inset Material would have.
///
/// **And it holds its label to one line.** Material caps a popup menu at 280 px
/// — five 56 px steps — which is not a lot once the padding and the check
/// column are out of it, and the row states its own height, so a label that
/// wrapped would overflow the row it is in rather than making the menu taller.
/// A capture device's name is arbitrarily long and comes from the operating
/// system, so this is reached in the field and not in any test written here.
/// The ellipsis is set once, on the row, rather than at four call sites that
/// would each have to remember it.
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
    this.reservesCheck = false,
    super.key,
  });

  /// The palette, resolved by the caller. See the note above.
  final OaaColors colors;

  /// Whether this row is the value the menu currently holds, or `null` where
  /// the menu holds no value at all. See the note above.
  final bool? selected;

  /// The row's content. Normally the label, and nothing else — the mark that
  /// says this row is the current value belongs to this widget now.
  final Widget child;

  /// Whether to keep the check's column on a row that can never carry one.
  ///
  /// For a menu that mixes actions with values — see the note above. Ignored
  /// where [selected] is not null, because such a row reserves the column by
  /// being what it is.
  final bool reservesCheck;

  /// What the `PopupMenuItem` above one of these must be built with.
  ///
  /// The fill cannot stretch to the item's height from inside it —
  /// `PopupMenuItem` aligns its child rather than stretching it — so the row
  /// states the height instead of inheriting it, and an item built to a
  /// different one would show a fill that does not reach its own edges.
  static const double height = OaaControl.height;

  /// The column the check sits in, and the indent every row of a menu that
  /// holds a value takes whether it is the value or not.
  static const double _column = Space.md;

  /// The check inside that column. A stroked mark at the size of a line of
  /// body text rather than the column's full width: a tick as wide as the gap
  /// it sits in crowds the label it is annotating.
  static const double _mark = Space.smd;

  /// How far the band travels from the menu's surface towards
  /// [OaaColors.hairlineStrong]. See the note above for where the quarter
  /// comes from.
  static const double _band = 0.25;

  /// The band under the row a menu already holds, in [colors].
  ///
  /// Exposed because it is a value with a floor to hold rather than a
  /// decoration — `test/menu_row_test.dart` asserts what it comes out at
  /// against the menu's own surface, in every shipped skin.
  static Color bandOn(OaaColors colors) =>
      Color.lerp(colors.panelRaised, colors.hairlineStrong, _band)!;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: selected ?? false ? bandOn(colors) : null,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: Row(
            children: [
              if (selected != null || reservesCheck)
                SizedBox(
                  width: _column,
                  child: selected ?? false
                      ? Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: OaaGlyph(
                            OaaMark.check,
                            color: colors.textPrimary,
                            size: _mark,
                          ),
                        )
                      : null,
                ),
              Flexible(
                child: DefaultTextStyle.merge(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: child,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
