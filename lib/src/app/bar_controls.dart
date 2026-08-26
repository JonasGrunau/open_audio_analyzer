// SPDX-License-Identifier: GPL-3.0-or-later

// The three shapes the window's two bars are built from, and the widths they
// come to.
//
// The menu bar across the top holds the commands and the open document's name;
// the status bar across the bottom holds the readings and the two menus that
// say what a reading is. One set of shapes for both, because they frame the same
// canvas: a chip in the lower row that did not look like the buttons in the
// upper one would read as a different kind of thing rather than as a quieter
// one.
//
// They live here rather than in `oaa_app.dart` because neither row is assembled
// in one file: `PublishSwitch` owns a socket and an mDNS responder and
// therefore has to stay in `lib/src/remote/`, but the thing it puts in the row
// is a control like any other. It was a stock `TextButton` for a whole phase —
// borderless, ink-rippled and Material-sized in a row of four bordered
// `BarButton`s — which is what a private widget in `oaa_app.dart` costs.
//
// They are *not* `OaaButton` and they never will be. `oaa_ui`'s buttons are
// sized for a panel, where a control has a whole row to itself; these are sized
// for a 40 px row that also has to hold a source name, a playhead, a clock and
// a delivery target. `BarSwitch` is not `OaaToggle` for the same reason and one
// more, which is about colour rather than size — see its own note.

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';

/// What the controls in the two bars measure, with the typefaces Open Audio
/// Analyzer ships.
///
/// **A table, because every gate in either row is arithmetic on it.** A gate is
/// the width at which everything up to and including one item still fits, so it
/// is a sum of the widths either side of it — which is why one control becoming
/// three used to move every gate in the old single bar by 165 px, and why the
/// eight hand-measured totals that replaced them could only be re-derived by
/// measuring all eight again. The rows read this and add up; nothing in
/// `oaa_app.dart` carries a width of its own.
///
/// Each number is an **upper bound** on what the widget it names actually
/// measures, and `test/scaling_test.dart` holds it there from both sides: it
/// loads the real fonts, pumps the real row, and fails with the number to write
/// here if a label grows or if a bound has gone slack. That is the check the
/// gates never had. Twice a gate was measured against a string the running
/// application replaced — `REMOTE · 12` outgrew `REMOTE`, and the default
/// delivery target's name is 100 px shorter than the longest one a user can
/// pick — and both times the suite stayed green while the row ran off its edge.
abstract final class BarMetrics {
  /// The height of both rows.
  ///
  /// **The same number as `menuBarHeight` in `MainFlutterWindow.swift`.**
  /// Nothing can share it — that file is compiled before Dart runs, and the
  /// window buttons have to be centred on the top row in the first frame — so
  /// moving one without the other leaves them a few points off the row they are
  /// part of, which reads as a fault in the row. The bottom row is the same
  /// height because it is built from the same 24 px controls and the same
  /// seams; two bars framing the canvas at two heights would read as one of
  /// them being wrong.
  static const double rowHeight = 40;

  // The top row. Three of these are marks rather than words, and all three come
  // to the same number: a mark button is its padding, its border and
  // `OaaGlyph`'s own size, and has nothing to do with what it means.
  static const double file = 50;
  static const double pairingCode = 42;
  static const double publish = 107;
  static const double attach = 72;
  static const double analyse = 106;
  static const double settings = 42;
  static const double reset = 42;
  static const double help = 34;

  // The bottom row. The two pickers are not here: both are capped and
  // ellipsised rather than measured, and the source is `Flexible` on top of
  // that — see [pickerCap] and [chipFloor]. Neither is the playhead, which
  // publishes its own width — see `TransportReadout.defaultWidth`.
  //
  // The format readout is the longest string a device can produce
  // (`192.0 kHz · 24 ch`, 127 px) rather than the one this machine happens to
  // be running at (`48.0 kHz · 2 ch`, 112) — that difference is exactly the
  // kind that ships, and a gate 15 px short of its own item is a gate that
  // holds until somebody plugs in an interface with more than nine channels.
  static const double format = 127;
  static const double elapsed = 60;

  /// What either picker may grow to before its name ellipsises.
  static const double pickerCap = 220;

  /// What the source picker shrinks *to*: its dot, its padding and its border,
  /// with the name given up entirely.
  ///
  /// It is `Flexible`, so this is the floor the bottom row's gates are measured
  /// against — the cap above is a ceiling on the same item and would put every
  /// gate 186 px too high.
  static const double chipFloor = 36;

  /// The document's name, centred in the top row.
  ///
  /// The cap is what a name is allowed to grow to, not what it reserves: the
  /// title is centred in the *window* and takes whatever the two groups leave
  /// symmetrically either side of it. The floor is where a name stops being
  /// readable and the row drops it whole rather than showing an ellipsis and a
  /// letter — the same rule the rest of both bars follows.
  static const double titleCap = 200;
  static const double titleFloor = 64;

  /// The gap between the title and whichever group is nearest it.
  ///
  /// A group boundary rather than a seam between controls, on both sides, and
  /// it is what stops a centred name reading as the last word of the left-hand
  /// group.
  static const double titleGap = Space.lg;

  /// The smallest gap either row is willing to show between its two groups.
  ///
  /// Every gate is a sum of the widths above it plus this. It is not a
  /// fudge factor for arithmetic that might be wrong — the sums are exact, and
  /// the widths are held against the widgets by a test. It is what stops a gate
  /// admitting an item at the exact width the row runs out of space, which
  /// looks like a mistake rather than like a full row, and it is the only slack
  /// either row has for a typeface this application does not ship.
  static const double margin = Space.lg;
}

/// The height of everything bordered in the two bars.
///
/// `OaaControl.height` for the bar, and it exists for the reason that one does.
/// The shapes below used to take their height from their own text style plus
/// their own vertical padding, and the styles are not the same: `caption` at
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

/// A bordered readout in a bar. Not interactive on its own — the caller puts
/// one inside a `PopupMenuButton`.
///
/// **The buttons' metrics, and one step down in tone.** It takes their height
/// and their 10 px capitals, because it is the face of a menu and opens on a
/// click like the commands in the row above — a control that can be pressed and
/// looks nothing like the pressable things in the window is a control people do
/// not find.
///
/// Its border stays `hairline` where theirs is `hairlineStrong`, and that one
/// step is the whole distinction. It was measured when the two shapes stood side
/// by side: matched on every other count, the row read as five buttons in a
/// line, and the one that reports what the meters are measured against was
/// indistinguishable from the four that do something. They no longer share a
/// row — the readings have their own — and the step is kept rather than dropped,
/// because a chip and a button are still a few pixels apart across the canvas
/// and the difference between reporting and doing is not one the rows can carry
/// on their own.
///
/// **Two menus wear this shape, and they are the two that report what a reading
/// is.** The delivery target is what every PASS and FAIL is a
/// verdict against; the signal source is what is being measured at all. The
/// source spent eight phases as a dot and a bare word beside four bordered
/// controls, which read as a caption rather than as the menu it is — the
/// commonest thing anybody changes in either row was the one item that did
/// not look changeable. It carries [lit] because it has a state the target does
/// not.
class BarChip extends StatelessWidget {
  const BarChip({required this.text, this.lit, super.key});

  /// Shown in capitals. The value keeps its own capitals everywhere else —
  /// a target the user named is theirs, and the menu, the settings panel and
  /// every report print it as they typed it.
  final String text;

  /// A state dot before the text: bright for true, dim for false.
  ///
  /// Null for a chip that reports a choice rather than a state — a delivery
  /// target is never on or off. The signal source is: bright means listening,
  /// dim means silence.
  final bool? lit;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    return Container(
      height: _barControlHeight,
      padding: const EdgeInsets.symmetric(horizontal: Space.sm),
      decoration: BoxDecoration(
        borderRadius: OaaRadius.allXs,
        border: Border.all(color: colors.hairline, width: OaaStroke.hairline),
      ),
      // `Center`, not `Container.alignment`: an aligned `Container` expands to
      // whatever bounded width it is offered, and this one is offered 220 px by
      // the `ConstrainedBox` around either picker — so the chip would be 220 px
      // wide whatever it said. A width factor of 1 shrink-wraps the row and
      // still centres it in the fixed height.
      child: Center(
        widthFactor: 1,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (lit != null) ...[
              _Dot(lit: lit!, colors: colors),
              const SizedBox(width: Space.sm),
            ],
            // `Flexible`, so the name gives ground before the row does.
            // Calibration names run long ("Streaming (−14 LUFS)") and a device
            // name is whatever an interface calls itself, and both chips sit in
            // a Row that has no slack: without this the text is measured against
            // unbounded width and takes it, inside the chip where the row's own
            // width gates cannot see it.
            Flexible(
              child: Text(
                text.toUpperCase(),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: OaaType.label.copyWith(color: colors.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The source chip's state dot.
///
/// Not the signal hue: this sits a few pixels from the meters, where `accent`
/// already means "in spec" — a lit teal dot beside a loudness number reads as a
/// verdict on it.
class _Dot extends StatelessWidget {
  const _Dot({required this.lit, required this.colors});

  final bool lit;
  final OaaColors colors;

  @override
  Widget build(BuildContext context) => Container(
    width: Space.xs + Space.xxs,
    height: Space.xs + Space.xxs,
    decoration: BoxDecoration(
      color: lit ? colors.textPrimary : colors.textFaint,
      borderRadius: OaaRadius.allXs,
    ),
  );
}

/// A button in one of the two bars.
class BarButton extends StatelessWidget {
  const BarButton({
    this.label,
    this.mark,
    required this.onPressed,
    this.tooltip,
    this.semanticLabel,
    this.lit = false,
    this.labelIsMark = false,
    super.key,
  }) : assert(
         mark == null || !labelIsMark,
         'A mark is already drawn at a mark\'s size.',
       ),
       assert(
         (label == null) != (mark == null),
         'A bar button carries a word or a mark, and not both.',
       ),
       assert(
         mark == null || semanticLabel != null,
         'A button drawn as a mark has no text to be announced by.',
       );

  /// The word on the button, in capitals. Null for a button drawn as a [mark].
  final String? label;

  /// Drawn in place of [label], at the row's own text size.
  ///
  /// For a button whose meaning is a picture rather than a word — the pairing
  /// code, whose label would be "QR" and would be read by nobody who did not
  /// already know. A mark costs about a third of the width of the shortest
  /// honest word, which is what buys it room in a row measured in tens of
  /// pixels; anything that can be said in a word is said in one.
  final OaaMark? mark;

  /// Null disables the button: it greys, stops taking focus and the pointer,
  /// and announces itself as disabled. A control that is present and inert says
  /// "not yet" where a control that has vanished says "not here", and the first
  /// is the truth for anything gated on a switch a few pixels away.
  final VoidCallback? onPressed;

  /// Shown on hover. Carries the scope of anything whose one-word label cannot
  /// — see `RESET`.
  final String? tooltip;

  /// Only for a button whose label is a glyph. Where the label is a word, the
  /// word is the announcement and this stays null rather than repeating it.
  final String? semanticLabel;

  /// Whether the [label] is a picture rather than a word, and should be drawn
  /// at a mark's size.
  ///
  /// One button uses it: `?`. It is the one label in the row that *is* the
  /// mark — no word for a sheet of key bindings is shorter or clearer — and it
  /// spent its life set at the row's 10 px like every other word. That was
  /// right while its neighbours were words. Beside two marks drawn in a 16 px
  /// box it reads as a smaller kind of thing than the controls either side of
  /// it, which is the same mismatch `OaaGlyph`'s own default exists to avoid:
  /// see the note at the mark's own branch below.
  ///
  /// Not the mark's box size. A `?` set at 16 px would be the loudest thing in
  /// the row, because a glyph's ink fills its em where a mark's fills about two
  /// thirds of its box. `body`'s 13 px puts its cap band where the marks'
  /// ink is, which is what matching on weight rather than on height means here.
  final bool labelIsMark;

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
    final colors = OaaTheme.of(context);
    final enabled = onPressed != null;

    // Disabled takes the ink a step down and the border with it, so the box
    // reads as inert rather than as a button somebody forgot to press. One step
    // is enough — it is the same distance `BarChip` uses to say "this is not
    // one of the four that do something".
    final ink = !enabled
        ? colors.textFaint
        : lit
        ? colors.textPrimary
        : colors.textMuted;

    final button = OaaFocusable(
      onActivate: onPressed,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) => Container(
        height: _barControlHeight,
        padding: const EdgeInsets.symmetric(horizontal: Space.smd),
        decoration: BoxDecoration(
          borderRadius: OaaRadius.allXs,
          color: hovered ? colors.panelRaised : null,
          border: Border.all(
            color: focused
                ? colors.textPrimary
                : enabled
                ? colors.hairlineStrong
                : colors.hairline,
            width: OaaStroke.hairline,
          ),
        ),
        // See `BarChip` for why the height is centred with a width factor
        // rather than with `Container.alignment`.
        child: Center(
          widthFactor: 1,
          child: mark != null
              // `OaaGlyph`'s own default, which is the size a mark is drawn at
              // in a panel row. A word in this bar is set at 10 px and a mark
              // shrunk to match it is a mark with its detail gone — the QR
              // code's finders close up below about 14 px — so the two are
              // matched on weight rather than on height.
              ? OaaGlyph(mark!, color: ink)
              : Text(
                  label!,
                  style: OaaType.label.copyWith(
                    color: ink,
                    fontSize: labelIsMark ? OaaType.body.fontSize : null,
                  ),
                ),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// A labelled on/off switch in the menu bar.
///
/// **Not `OaaToggle`, and the reason is colour rather than size.** `oaa_ui`'s
/// toggle fills with `accent` when it is on, and `accent` in this row means "in
/// spec" — it is what a loudness reading turns when it meets its target. A
/// second meaning for it a few pixels from the numbers turns every lit thing in
/// window into a possible verdict on them. So this says on the way `BarButton`
/// says it: brightness. The track fills with `textPrimary` and the knob is cut
/// out of it in `background`; off, the track is `meterTrack` inside the same
/// `hairlineStrong` outline every other control in the row wears.
///
/// The word and the track are one control, not a label beside a switch: the
/// whole box is the hit target and the whole box takes focus, so the row keeps
/// one tab stop per thing you can do to it.
class BarSwitch extends StatelessWidget {
  const BarSwitch({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.tooltip,
    super.key,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  /// What this switches, in a sentence. Unlike [BarButton] this is required:
  /// the label is one capitalised word and a switch announced as "PUBLISH" says
  /// nothing about what is published or to whom.
  final String semanticLabel;

  /// Shown on hover. Where a switch carries state the row has no room to print
  /// — see `PublishSwitch`, whose attached-display count lives here.
  final String? tooltip;

  /// The track, sized for a bar rather than for a panel row.
  ///
  /// `OaaToggle` is 34x18, which is drawn for a 32 px control in a panel row;
  /// this one sits inside a 24 px control in a 40 px bar. Composed from `Space`
  /// rather than written as numbers, like `_barControlHeight` above and for the
  /// same reason — the two lengths and the knob's inset are one proportion, and
  /// a raw 24 here is a value nobody can change without measuring three others.
  static const double _trackWidth = Space.lg;
  static const double _trackHeight = Space.smd;

  /// Leaves the knob exactly filling the track's height between its insets:
  /// `Space.xxs + _knob + Space.xxs == _trackHeight`.
  static const double _knob = _trackHeight - Space.xs;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    final control = OaaFocusable(
      onActivate: () => onChanged(!value),
      // Announces as a switch rather than as a button, and carries the state
      // with it. `OaaFocusable` drops the button role when this is set.
      toggled: value,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) => Container(
        height: _barControlHeight,
        padding: const EdgeInsets.symmetric(horizontal: Space.smd),
        decoration: BoxDecoration(
          borderRadius: OaaRadius.allXs,
          color: hovered ? colors.panelRaised : null,
          border: Border.all(
            color: focused ? colors.textPrimary : colors.hairlineStrong,
            width: OaaStroke.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              label,
              style: OaaType.label.copyWith(
                color: value ? colors.textPrimary : colors.textMuted,
              ),
            ),
            const SizedBox(width: Space.sm),
            Container(
              width: _trackWidth,
              height: _trackHeight,
              decoration: BoxDecoration(
                color: value ? colors.textPrimary : colors.meterTrack,
                borderRadius: const BorderRadius.all(
                  Radius.circular(_trackHeight / 2),
                ),
                border: Border.all(
                  color: value ? colors.textPrimary : colors.hairlineStrong,
                  width: OaaStroke.hairline,
                ),
              ),
              child: Align(
                alignment: value ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(Space.xxs),
                  child: Container(
                    width: _knob,
                    height: _knob,
                    decoration: BoxDecoration(
                      color: value ? colors.background : colors.textFaint,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return tooltip == null
        ? control
        : Tooltip(message: tooltip!, child: control);
  }
}
