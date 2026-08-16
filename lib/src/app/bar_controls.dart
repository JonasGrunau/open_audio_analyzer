// SPDX-License-Identifier: GPL-3.0-or-later

// The two shapes the status bar is built from.
//
// They live here rather than in `bel_app.dart` because the bar is not assembled
// in one file: `RemoteDisplayControl` owns a socket and an mDNS responder and
// therefore has to stay in `lib/src/remote/`, but the thing it puts in the row
// is a button like any other. It was a stock `TextButton` for a whole phase —
// borderless, ink-rippled and Material-sized in a row of four bordered
// `BarButton`s — which is what a private widget in `bel_app.dart` costs.
//
// They are *not* `BelButton` and they never will be. `bel_ui`'s buttons are
// sized for a panel, where a control has a whole row to itself; these are sized
// for a 40 px bar that also has to hold the source, the clock, the calibration
// and the frame rate.

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';

/// The height of everything bordered in the status bar.
///
/// `BelControl.height` for the bar, and it exists for the reason that one does.
/// Both shapes below used to take their height from their own text style plus
/// their own vertical padding, and the two styles are not the same: `caption` at
/// 11 px on a 1.4 line box made the chip 25.4 px tall, `label` at 10 px on a 1.2
/// one made the button 22. So the delivery target sat 3.4 px taller than the
/// four buttons beside it, with its border crossing theirs — the defect nobody
/// can name and everybody sees, in a row where the borders are the only thing
/// drawing a horizontal line.
///
/// A height a control is *given* rather than one it happens to add up to. The
/// text is centred in it, so changing a style here changes the weight of a word
/// and nothing about the row.
const double _barControlHeight = Space.lg;

/// A bordered readout in the bar. Not interactive on its own — the caller puts
/// one inside a `PopupMenuButton`.
///
/// **The buttons' metrics, and one step down in tone.** It takes their height
/// and their 10 px capitals, because it is the face of a menu and opens on a
/// click like the four to its right — a control that can be pressed and looks
/// nothing like the pressable things beside it is a control people do not find.
///
/// Its border stays `hairline` where theirs is `hairlineStrong`, and that one
/// step is the whole distinction: matched on every other count, the row read as
/// five buttons in a line, and the one that reports what the meters are
/// measured against was indistinguishable from the four that do something.
/// Tone is the right axis to separate them on — it survives the metrics being
/// identical, which is what keeps the row a row.
class BarChip extends StatelessWidget {
  const BarChip({required this.text, super.key});

  /// Shown in capitals. The value keeps its own capitals everywhere else —
  /// a target the user named is theirs, and the menu, the settings panel and
  /// every report print it as they typed it.
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Container(
      height: _barControlHeight,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      decoration: BoxDecoration(
        borderRadius: BelRadius.allXs,
        border: Border.all(color: colors.hairline, width: BelStroke.hairline),
      ),
      // `Center`, not `Container.alignment`: an aligned `Container` expands to
      // whatever bounded width it is offered, and this one is offered 220 px by
      // the `ConstrainedBox` around the calibration picker — so the chip would
      // be 220 px wide whatever it said. A width factor of 1 shrink-wraps the
      // text and still centres it in the fixed height.
      child: Center(
        widthFactor: 1,
        // Calibration names run long ("Streaming (−14 LUFS)"), and this chip
        // sits in a Row that has no slack. Ellipsis rather than overflow.
        child: Text(
          text.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          softWrap: false,
          style: BelType.label.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

/// A button in the status bar.
class BarButton extends StatelessWidget {
  const BarButton({
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.semanticLabel,
    this.lit = false,
    super.key,
  });

  final String label;
  final VoidCallback onPressed;

  /// Shown on hover. Carries the scope of anything whose one-word label cannot
  /// — see `RESET`.
  final String? tooltip;

  /// Only for a button whose label is a glyph. Where the label is a word, the
  /// word is the announcement and this stays null rather than repeating it.
  final String? semanticLabel;

  /// Whether this button is reporting a state that is currently *on*.
  ///
  /// Brightness rather than hue, and deliberately so: `accent` in this bar
  /// means "in spec", because it is the colour a loudness reading turns when it
  /// meets its target. A second meaning for it a few pixels away turns every
  /// lit thing in the row into a possible verdict on the numbers beside it. The
  /// bar already says "on" this way — see the source picker's dot.
  final bool lit;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final button = BelFocusable(
      onActivate: onPressed,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) => Container(
        height: _barControlHeight,
        padding: const EdgeInsets.symmetric(horizontal: Space.smd),
        decoration: BoxDecoration(
          borderRadius: BelRadius.allXs,
          color: hovered ? colors.panelRaised : null,
          border: Border.all(
            color: focused ? colors.textPrimary : colors.hairlineStrong,
            width: BelStroke.hairline,
          ),
        ),
        // See `BarChip` for why the height is centred with a width factor
        // rather than with `Container.alignment`.
        child: Center(
          widthFactor: 1,
          child: Text(
            label,
            style: BelType.label.copyWith(
              color: lit ? colors.textPrimary : colors.textMuted,
            ),
          ),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
