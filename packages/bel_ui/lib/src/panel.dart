// SPDX-License-Identifier: GPL-3.0-or-later

/// The chrome every Bel panel is built from.
///
/// Settings, the preset browser, the calibration editor and the Phase 5 report
/// all want the same thing: a bordered surface over the canvas, a title, a way
/// out, sections of labelled rows, and controls that look like the rest of the
/// instrument rather than like Material. Written once here, they cannot drift;
/// written per panel, they will.
///
/// Nothing in this file is a meter and nothing in it repaints per frame, so the
/// no-allocation-in-paint rule that governs `lib/src/modules/` does not apply —
/// these are ordinary widgets that rebuild when a human does something.
library;

import 'package:flutter/material.dart';

import 'focusable.dart';
import 'glyph.dart';
import 'theme.dart';
import 'tokens.dart';

/// Shows [builder]'s panel as a modal over the canvas.
///
/// **A panel takes its palette from above the [Navigator], because that is the
/// only palette that can still change while it is open.** A route pushed with
/// `showGeneralDialog` is built by the Navigator, so it sees what the
/// application installed above it and nothing that is under `MaterialApp.home`.
/// `MaterialApp` has always put its own `ThemeData` there, and for a phase the
/// `BelTheme` was under `home` and re-provided here as a *copy taken when the
/// panel opened* — so choosing a skin repainted the canvas, the window chrome
/// and every Material widget inside the panel, while the panel's own hairlines,
/// fills and text stayed in the previous skin until it was closed and reopened.
/// Skins are chosen in the settings panel, so the one place it showed was the
/// one place that mattered. `BelApp` installs the palette through
/// `MaterialApp.builder`, beside the Material theme; this reads it there.
///
/// The call site's palette is still read, for a tree that wraps only its home —
/// a widget test, mostly. Such a panel is drawn in the right colours and simply
/// cannot follow a change of skin, which is what asking a test to install a
/// palette above a Navigator it never mentions would cost more than it is
/// worth.
Future<T?> showBelPanel<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final captured = BelTheme.of(context);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // **The scrim is painted in the page rather than by the route's barrier.**
    // `barrierColor` is a value a route is *constructed* with and a skin change
    // happens afterwards, so a barrier is a wash of the old background over the
    // whole screen — the largest wrong-coloured thing on it, and larger than
    // the panel it surrounds. A transparent one is still a `ModalBarrier`, so
    // a tap outside the panel still dismisses it.
    barrierColor: Colors.transparent,
    // No slide, no scale, no fade beyond the scrim's own. A panel that animates
    // in is a panel you wait for, and this one is opened to change a number and
    // closed again.
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) {
      final colors = BelTheme.maybeOf(context) ?? captured;

      return BelTheme(
        colors: colors,
        child: Stack(
          children: [
            // Dimming towards the palette's own background rather than towards
            // black: on a light skin a black scrim is a bruise across the
            // middle of a pale interface. `IgnorePointer` because a
            // `ColoredBox` is opaque to hit testing, and the tap it would
            // swallow is the one the barrier beneath dismisses the panel with.
            Positioned.fill(
              child: IgnorePointer(
                child: ColoredBox(
                  color: colors.background.withValues(alpha: 0.72),
                ),
              ),
            ),
            Positioned.fill(child: Builder(builder: builder)),
          ],
        ),
      );
    },
  );
}

/// A panel surface: title bar, scrolling body, optional footer.
class PanelScaffold extends StatefulWidget {
  const PanelScaffold({
    required this.title,
    required this.child,
    this.onClose,
    this.footer,
    this.width = 620,
    super.key,
  });

  final String title;
  final Widget child;
  final VoidCallback? onClose;

  /// Actions along the bottom. Laid out end-aligned by the caller.
  final Widget? footer;

  /// The panel's maximum width. Panels are read left to right in short lines;
  /// letting one span a 32" display makes a label and its control land at
  /// opposite ends of the desk.
  final double width;

  @override
  State<PanelScaffold> createState() => _PanelScaffoldState();
}

class _PanelScaffoldState extends State<PanelScaffold> {
  /// Held rather than left to the primary controller, because the scrollbar
  /// below has to be pointed at this scrollable specifically — a panel that
  /// contains a second scrolling region would otherwise attach the bar to
  /// whichever one registered last.
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Space.xl),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: widget.width, maxHeight: 760),
          child: ClipRRect(
            borderRadius: BelRadius.allMd,
            // **A `Material` here is not decoration.** A panel is pushed as a
            // route, so it is built by the Navigator — *outside* the `Material`
            // the application wraps its canvas in. Every stock widget a panel
            // reaches for that draws an ink response, `PopupMenuButton` and
            // `TextField` among them, asserts "No Material widget found" and is
            // replaced by an error box. The error box then reports an intrinsic
            // width near 100 000 px, so the first thing anybody sees is a
            // RenderFlex overflow pointing at a `Row` that is perfectly fine.
            child: Material(
              color: colors.panel,
              child: DecoratedBox(
                // **The border carries the same radius as the clip above it.**
                // A square `Border.all` inside a `ClipRRect` is not a rounded
                // border — the clip removes the corner of the stroke along with
                // everything else outside the arc, so the hairline stops dead
                // at each tangent and the four corners are bare panel fill
                // fading into the barrier. It reads as a rendering fault, which
                // is what it is. Uniform borders may be combined with a radius;
                // only a *non-uniform* one asserts.
                decoration: BoxDecoration(
                  borderRadius: BelRadius.allMd,
                  border: Border.all(
                    color: colors.hairline,
                    width: BelStroke.hairline,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TitleBar(title: widget.title, onClose: widget.onClose),
                    Flexible(
                      // **A panel taller than 760 px scrolls, and until now
                      // said nothing about it.** The settings panel ends on a
                      // row that the viewport happens to cut in half, which
                      // reads as a layout fault rather than as an invitation
                      // to scroll — the last thing anybody saw was half a
                      // "Presets" label with its button sliced off. The bar
                      // hides itself when the content fits, so a short panel
                      // is unchanged.
                      child: RawScrollbar(
                        controller: _scroll,
                        thumbColor: colors.hairlineStrong,
                        thickness: BelStroke.emphasis * 2,
                        radius: BelRadius.xs,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.symmetric(
                            horizontal: Space.lg,
                            vertical: Space.md,
                          ),
                          child: widget.child,
                        ),
                      ),
                    ),
                    if (widget.footer != null) ...[
                      _Hairline(colors: colors),
                      Padding(
                        padding: const EdgeInsets.all(Space.smd),
                        child: widget.footer,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar({required this.title, this.onClose});

  final String title;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.lg,
            Space.smd,
            Space.sm,
            Space.smd,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: BelType.label.copyWith(
                    color: colors.textPrimary,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (onClose != null)
                _IconTarget(
                  tooltip: 'Close',
                  onPressed: onClose!,
                  child: Text(
                    '×',
                    style: BelType.reading(
                      18,
                    ).copyWith(color: colors.textMuted),
                  ),
                ),
            ],
          ),
        ),
        _Hairline(colors: colors),
      ],
    );
  }
}

class _Hairline extends StatelessWidget {
  const _Hairline({required this.colors});

  final BelColors colors;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: colors.hairline,
    child: const SizedBox(height: BelStroke.hairline, width: double.infinity),
  );
}

/// A labelled group of rows.
///
/// **Sections are ruled off from each other, and the rule is not decoration.**
/// A section heading is [BelType.label] at 10 px and its note is
/// [BelType.caption] at 11 px, so the heading is the *smallest* text in its own
/// section and four groups of settings read as one undifferentiated column of
/// grey. The panel already separates its title bar and its footer with a
/// hairline; separating its sections the same way is the system being applied
/// rather than a line being added.
class PanelSection extends StatelessWidget {
  const PanelSection({
    required this.title,
    required this.children,
    this.note,
    this.ruled = true,
    super.key,
  });

  final String title;

  /// One line under the heading, for the thing a user would otherwise have to
  /// learn by trying it.
  final String? note;
  final List<Widget> children;

  /// Whether to rule this section off from what precedes it.
  ///
  /// False for the first section in a panel, where a rule under the title bar
  /// is a doubled line.
  final bool ruled;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Asymmetric on purpose: a heading belongs to what follows it, so it
        // sits closer to its own rows than to the section it was ruled off
        // from.
        if (ruled) ...[
          const SizedBox(height: Space.lg),
          _Hairline(colors: colors),
          const SizedBox(height: Space.md),
        ],
        Text(
          title.toUpperCase(),
          style: BelType.label.copyWith(color: colors.textMuted),
        ),
        if (note != null) ...[
          const SizedBox(height: Space.xs),
          Text(note!, style: BelType.caption.copyWith(color: colors.textFaint)),
        ],
        const SizedBox(height: Space.smd),
        ...children,
      ],
    );
  }
}

/// A label on the left, a control on the right, and the explanation underneath.
///
/// **The note runs the full width of the panel rather than sharing the line
/// with the control.** Sharing it means every note wraps at whatever happens to
/// be left over beside its own control, so the delivery target's broke after
/// "all normalise to" and the row it belonged to could not be told from the one
/// below. Underneath, every note in the panel measures the same and the labels
/// and controls line up on one baseline grid.
///
/// **The gap above the note clears the control, not the label.** A row is as
/// tall as whatever sits on its right, so a caption set to hug the label ends
/// up hugging a bordered control instead — the delivery target's note ran two
/// pixels under the dropdown and its tail passed beneath it, which reads as a
/// line belonging to the menu rather than to the row. [Space.sm] leaves the
/// note half as far from its own row as from the next one, so proximity still
/// says which row it explains.
class PanelRow extends StatelessWidget {
  const PanelRow({
    required this.label,
    required this.child,
    this.note,
    super.key,
  });

  final String label;
  final String? note;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Space.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: BelType.body.copyWith(color: colors.textPrimary),
                ),
              ),
              const SizedBox(width: Space.md),
              child,
            ],
          ),
          if (note != null) ...[
            const SizedBox(height: Space.sm),
            Text(
              note!,
              style: BelType.caption.copyWith(color: colors.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

/// Explanatory prose inside a section, below the rows it explains.
///
/// The same caption-on-[BelColors.textFaint] that a row's note is, written once
/// so that the seven places a panel needs a paragraph cannot each arrive at
/// their own idea of how far it sits from what it follows.
class PanelNote extends StatelessWidget {
  const PanelNote(this.text, {this.tone, this.mark, super.key});

  final String text;

  /// Overrides the colour, for the notes that are warnings.
  final Color? tone;

  /// A [BelMark] in the margin, in the note's own tone.
  ///
  /// **For the notes that are problems, not for the ones that explain.** A
  /// panel is mostly caption-sized prose in one grey, and a toned note is one
  /// step of colour away from the paragraph above it — which is enough to see
  /// once you are looking at it and not enough to stop you scrolling past. The
  /// mark hangs in its own gutter so the sentence still starts on the same left
  /// edge as everything else in the section.
  final BelMark? mark;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final color = tone ?? colors.textFaint;
    final label = Text(text, style: BelType.caption.copyWith(color: color));

    return Padding(
      padding: const EdgeInsets.only(top: Space.smd),
      child: mark == null
          ? label
          : Row(
              // Centred on the block rather than hung at the top of it. Every
              // note that carries a mark is a short paragraph that wraps — two
              // lines in a panel, three on a phone-shaped display — and a mark
              // pinned to the first line of a wrapped sentence looks like it
              // belongs to that line instead of to the sentence. The mark
              // annotates the whole note, so it sits at the note's middle.
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                BelGlyph(mark!, color: color),
                const SizedBox(width: Space.sm),
                Expanded(child: label),
              ],
            ),
    );
  }
}

/// The row of buttons that ends a section.
class PanelActions extends StatelessWidget {
  const PanelActions({required this.children, super.key});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: Space.smd),
    child: Row(
      children: [
        for (final (index, action) in children.indexed) ...[
          if (index > 0) const SizedBox(width: Space.sm),
          action,
        ],
      ],
    ),
  );
}

/// A selectable row: the preset browser's list, the skin list.
class PanelListRow extends StatelessWidget {
  const PanelListRow({
    required this.title,
    this.note,
    this.selected = false,
    this.onTap,
    this.trailing,
    this.mark,
    this.opens = false,
    super.key,
  });

  final String title;
  final String? note;
  final bool selected;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// A [BelMark] down the left of the row, in the title's own colour.
  ///
  /// A `BelMark` rather than a widget slot: a row that could be handed any
  /// widget is a row that will eventually hold four different sizes of four
  /// different things. The mark is for a list whose rows are *kinds* rather
  /// than peers — send against receive, where the words are the only difference
  /// between two rows of identical shape.
  final BelMark? mark;

  /// Whether tapping this row opens something else, marked with a chevron.
  ///
  /// A list row normally selects in place, so the two in the remote panel that
  /// push a whole panel are doing something the rest of the list does not. The
  /// chevron says so before the row is pressed rather than after.
  final bool opens;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return BelFocusable(
      onActivate: onTap,
      button: false,
      selected: selected,
      builder: (context, hovered, focused) => Container(
        margin: const EdgeInsets.only(bottom: Space.xs),
        padding: const EdgeInsets.symmetric(
          horizontal: Space.smd,
          vertical: Space.sm,
        ),
        decoration: BoxDecoration(
          // **Selection is the fill; the border is the pointer and the
          // keyboard.** Carried by the border alone, selection was
          // `hairlineStrong` against `hairline` — one step of grey on a 1 px
          // line, and in the skin list you could not tell which of the two
          // skins you were looking at without reading the meters behind the
          // panel. Hover deliberately does *not* take the fill as well, or
          // pointing at an unselected row would put two raised rows on screen
          // and leave that same one step of grey to tell them apart. Focus
          // outranks hover and stays a hairline, so nothing here can nudge the
          // rows below it.
          color: selected ? colors.panelRaised : null,
          borderRadius: BelRadius.allSm,
          border: Border.all(
            color: focused
                ? colors.textPrimary
                : selected || hovered
                ? colors.hairlineStrong
                : colors.hairline,
            width: BelStroke.hairline,
          ),
        ),
        child: Row(
          children: [
            if (mark != null) ...[
              BelGlyph(
                mark!,
                color: selected || hovered || focused
                    ? colors.textPrimary
                    : colors.textMuted,
              ),
              const SizedBox(width: Space.smd),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: BelType.body.copyWith(
                      // Pointed at or arrowed to, a row brightens the way a
                      // segment does. Without it a list nothing is selected in
                      // — every host a search found — is a column of muted text
                      // that reads as disabled.
                      color: selected || hovered || focused
                          ? colors.textPrimary
                          : colors.textMuted,
                    ),
                  ),
                  if (note != null)
                    Text(
                      note!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: BelType.caption.copyWith(color: colors.textFaint),
                    ),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: Space.sm),
              trailing!,
            ],
            if (opens) ...[
              const SizedBox(width: Space.sm),
              BelGlyph(
                BelMark.chevron,
                color: hovered || focused ? colors.textMuted : colors.textFaint,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// One choice from a short, fixed set.
///
/// For anything with more than about five options, or options that arrive at
/// runtime, use a menu instead — a segmented control that wraps onto two lines
/// has stopped being one control.
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    required this.segments,
    required this.value,
    required this.onChanged,
    super.key,
  });

  final List<({T value, String label})> segments;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return SizedBox(
      height: BelControl.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BelRadius.allSm,
          border: Border.all(color: colors.hairline, width: BelStroke.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          // Segments fill the control rather than being centred inside it, so
          // the selected one's fill meets the border instead of floating in a
          // sliver of panel.
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final segment in segments)
              BelFocusable(
                onActivate: () => onChanged(segment.value),
                selected: segment.value == value,
                builder: (context, hovered, focused) => Container(
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(
                    horizontal: BelControl.padding,
                  ),
                  decoration: BoxDecoration(
                    // The fill means *selected* and nothing else. Hover
                    // brightens the label instead: a hovered segment filled
                    // the same way as the selected one would put two raised
                    // segments in a control where exactly one can be chosen.
                    color: segment.value == value ? colors.panelRaised : null,
                    borderRadius: BelRadius.allSm,
                    // Always drawn, transparent until focused, so that arrowing
                    // along the segments does not shuffle their widths.
                    border: Border.all(
                      color: focused ? colors.textPrimary : Colors.transparent,
                      width: BelStroke.hairline,
                    ),
                  ),
                  // Uppercase in [BelType.label], like [BelButton] and the
                  // tabs. A segment is a control's own word, not prose about
                  // one, and set in sentence case at caption weight it was the
                  // only text in a panel row that looked like something being
                  // said rather than something to press — a `Test tone` beside
                  // a `RESCAN` two rows down.
                  child: Text(
                    segment.label.toUpperCase(),
                    style: BelType.label.copyWith(
                      color: segment.value == value || hovered
                          ? colors.textPrimary
                          : colors.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A menu that reads as a control: the value it holds, and a caret.
///
/// **Not a `PopupMenuButton`.** That builds its own `InkWell`, and the Bel
/// theme has stripped Material of splash and highlight — so the two menus in
/// the settings panel were the only controls in the interface with no hover
/// state and no focus ring, and the only way to tell one was a menu at all was
/// that its text happened to name a device. Driving `showMenu` from a
/// [BelFocusable] puts all three back and costs about fifteen lines.
///
/// The value is [BelColors.textPrimary]: a menu whose current setting is
/// painted fainter than the button beside it reads as disabled.
class PanelMenu<T> extends StatelessWidget {
  const PanelMenu({
    required this.label,
    required this.selected,
    required this.options,
    required this.onSelected,
    this.semanticLabel,
    this.maxWidth = 220,
    super.key,
  });

  /// What the menu currently holds.
  final String label;
  final T? selected;
  final List<({T value, String label})> options;
  final ValueChanged<T> onSelected;

  /// What this menu chooses. The value is merged into the announcement, so this
  /// is the noun and not the reading — "Capture device", not the device's name.
  final String? semanticLabel;

  /// A device name is arbitrarily long and a panel row is not.
  final double maxWidth;

  Future<void> _open(BuildContext context) async {
    final colors = BelTheme.of(context);
    final button = context.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;

    // Anchored to the *bottom* edge, so the menu drops under the control
    // rather than over the value it is about to replace.
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          button.size.bottomLeft(Offset.zero),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );

    final chosen = await showMenu<T>(
      context: context,
      position: position,
      color: colors.panelRaised,
      // No shadow, and no Material 3 surface tint over the palette's own
      // panelRaised. Depth in this design is a background step and a hairline;
      // a menu that arrives with a soft drop shadow is the one floating card in
      // an interface of machined panels sitting flush.
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BelRadius.allSm,
        side: BorderSide(color: colors.hairline, width: BelStroke.hairline),
      ),
      items: [
        for (final option in options)
          PopupMenuItem<T>(
            value: option.value,
            height: BelControl.height,
            child: Row(
              children: [
                // A mark rather than a colour, because the palette reserves the
                // signal hue for "in spec" and selection inside a panel is
                // `hairlineStrong` — neither of which a line of text can wear.
                // Geometry rather than a glyph for the reason in [_Caret].
                SizedBox(
                  width: Space.md,
                  child: option.value == selected
                      ? Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            width: Space.xs,
                            height: Space.smd,
                            decoration: BoxDecoration(
                              color: colors.textPrimary,
                              borderRadius: BelRadius.allXs,
                            ),
                          ),
                        )
                      : null,
                ),
                Flexible(
                  child: Text(
                    option.label,
                    overflow: TextOverflow.ellipsis,
                    style: BelType.body.copyWith(
                      color: option.value == selected
                          ? colors.textPrimary
                          : colors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );

    if (chosen != null) onSelected(chosen);
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final enabled = options.isNotEmpty;

    return BelFocusable(
      onActivate: enabled ? () => _open(context) : null,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) => Container(
        height: BelControl.height,
        constraints: BoxConstraints(maxWidth: maxWidth),
        padding: const EdgeInsets.symmetric(horizontal: BelControl.padding),
        decoration: BoxDecoration(
          color: hovered && enabled ? colors.panelRaised : null,
          borderRadius: BelRadius.allSm,
          border: Border.all(
            color: focused
                ? colors.textPrimary
                : hovered && enabled
                ? colors.hairlineStrong
                : colors.hairline,
            width: BelStroke.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                style: BelType.body.copyWith(
                  color: enabled ? colors.textPrimary : colors.textFaint,
                ),
              ),
            ),
            const SizedBox(width: Space.sm),
            _Caret(color: enabled ? colors.textMuted : colors.textFaint),
          ],
        ),
      ),
    );
  }
}

/// The mark that says a control opens a menu.
///
/// **Painted rather than typeset.** `▾` (U+25BE) is in neither Inter nor most
/// of the fallback stack, so the first build of [PanelMenu] put a tofu box
/// where the affordance should be — on the only two menus in the interface, on
/// every platform. Eight pixels of geometry cannot go missing.
class _Caret extends StatelessWidget {
  const _Caret({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: Space.sm,
    height: Space.xs,
    child: CustomPaint(painter: _CaretPainter(color)),
  );
}

class _CaretPainter extends CustomPainter {
  const _CaretPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CaretPainter oldDelegate) => oldDelegate.color != color;
}

/// A button. Three weights and no more.
class BelButton extends StatelessWidget {
  const BelButton({
    required this.label,
    required this.onPressed,
    this.emphasis = ButtonEmphasis.normal,
    super.key,
  });

  final String label;

  /// Null disables the button. A disabled button that still looks live is worse
  /// than no button — and, since this became a [BelFocusable], a disabled
  /// button also drops out of keyboard traversal rather than being a tab stop
  /// that does nothing.
  final VoidCallback? onPressed;
  final ButtonEmphasis emphasis;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final enabled = onPressed != null;

    // `accent` here is the *emphasis* colour, and for a primary button it is
    // genuinely the signal hue — see its note in tokens.dart. A panel covers
    // the canvas, so there is no reading on screen for it to be confused with,
    // and an affirmative action that cannot be told from a secondary one costs
    // more than the hue serving a second context in a second place.
    final emphasisColor = switch (emphasis) {
      ButtonEmphasis.normal => colors.textMuted,
      ButtonEmphasis.primary => colors.accent,
      ButtonEmphasis.destructive => colors.over,
    };

    return BelFocusable(
      onActivate: onPressed,
      builder: (context, hovered, focused) {
        final border = switch (emphasis) {
          ButtonEmphasis.normal =>
            hovered ? colors.hairlineStrong : colors.hairline,
          _ => emphasisColor,
        };

        return Container(
          height: BelControl.height,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: BelControl.padding),
          decoration: BoxDecoration(
            color: hovered && enabled ? colors.panelRaised : null,
            borderRadius: BelRadius.allSm,
            border: Border.all(
              color: focused
                  ? colors.textPrimary
                  : enabled
                  ? border
                  : colors.hairline,
              width: BelStroke.hairline,
            ),
          ),
          child: Text(
            label.toUpperCase(),
            style: BelType.label.copyWith(
              color: enabled ? emphasisColor : colors.textFaint,
            ),
          ),
        );
      },
    );
  }
}

enum ButtonEmphasis { normal, primary, destructive }

/// A boolean.
///
/// Painted rather than a Material `Switch`, which arrives 60 px wide with a
/// ripple and a spring curve and looks like it came from a phone.
class BelToggle extends StatelessWidget {
  const BelToggle({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    super.key,
  });

  final bool value;
  final ValueChanged<bool> onChanged;

  /// What this switches. A toggle has no text of its own — its label lives in
  /// the [PanelRow] beside it — so without this it is announced as a switch
  /// for nothing in particular.
  final String? semanticLabel;

  static const double _width = 34;
  static const double _height = 18;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return BelFocusable(
      onActivate: () => onChanged(!value),
      toggled: value,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) => Container(
        width: _width,
        height: _height,
        decoration: BoxDecoration(
          color: value ? colors.accent : colors.meterTrack,
          borderRadius: const BorderRadius.all(Radius.circular(_height / 2)),
          border: Border.all(
            color: focused
                ? colors.textPrimary
                : value
                ? colors.accent
                : colors.hairlineStrong,
            width: BelStroke.hairline,
          ),
        ),
        child: Align(
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.all(Space.xxs),
            child: Container(
              width: _height - Space.sm,
              height: _height - Space.sm,
              decoration: BoxDecoration(
                color: value ? colors.background : colors.textFaint,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A single-line text input.
///
/// Numbers typed into one of these are monospaced with tabular figures like
/// every other number in the interface — a calibration's true-peak ceiling is a
/// measurement even while it is being edited.
class BelTextField extends StatelessWidget {
  const BelTextField({
    required this.controller,
    this.hintText,
    this.onSubmitted,
    this.onChanged,
    this.numeric = false,
    this.autofocus = false,
    this.width,
    super.key,
  });

  final TextEditingController controller;
  final String? hintText;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool numeric;
  final bool autofocus;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final style = numeric
        ? BelType.readingSmall.copyWith(color: colors.textPrimary)
        : BelType.body.copyWith(color: colors.textPrimary);

    return SizedBox(
      width: width,
      child: Container(
        height: BelControl.height,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: BelRadius.allSm,
          border: Border.all(color: colors.hairline, width: BelStroke.hairline),
        ),
        child: TextField(
          controller: controller,
          autofocus: autofocus,
          style: style,
          // The caret is not an affirmative action, so it takes no part in the
          // panel exception that lets a primary button keep the signal hue.
          cursorColor: colors.textPrimary,
          cursorWidth: BelStroke.hairline,
          textAlign: numeric ? TextAlign.right : TextAlign.start,
          keyboardType: numeric
              ? const TextInputType.numberWithOptions(
                  signed: true,
                  decimal: true,
                )
              : TextInputType.text,
          onSubmitted: onSubmitted,
          onChanged: onChanged,
          decoration: InputDecoration.collapsed(
            hintText: hintText,
            hintStyle: style.copyWith(color: colors.textFaint),
          ),
        ),
      ),
    );
  }
}

/// A target for an icon or glyph, sized so it can actually be hit.
class _IconTarget extends StatelessWidget {
  const _IconTarget({
    required this.child,
    required this.onPressed,
    required this.tooltip,
  });

  final Widget child;
  final VoidCallback onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Tooltip(
      message: tooltip,
      child: BelFocusable(
        onActivate: onPressed,
        semanticLabel: tooltip,
        builder: (context, hovered, focused) => DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BelRadius.allSm,
            border: Border.all(
              color: focused ? colors.textPrimary : Colors.transparent,
              width: BelStroke.hairline,
            ),
          ),
          child: SizedBox(
            width: Space.lg,
            height: Space.lg,
            child: Center(child: child),
          ),
        ),
      ),
    );
  }
}
