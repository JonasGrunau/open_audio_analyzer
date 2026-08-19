// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'menus.dart';
import 'workspace.dart';

/// The tab strip, and the canvas-wide actions that belong next to it.
///
/// Add, undo and redo are here as buttons as well as keyboard shortcuts. Open
/// Audio Analyzer runs on tablets, where there is no Cmd+Z and no right mouse
/// button, so a canvas whose only affordances are a chord and a secondary click
/// is a canvas that cannot be edited on half its target platforms.
class TabStrip extends ConsumerStatefulWidget {
  const TabStrip({super.key});

  static const double height = 32;

  @override
  ConsumerState<TabStrip> createState() => _TabStripState();
}

class _TabStripState extends ConsumerState<TabStrip> {
  final TextEditingController _rename = TextEditingController();
  final FocusNode _renameFocus = FocusNode();
  int? _editing;

  @override
  void dispose() {
    _rename.dispose();
    _renameFocus.dispose();
    super.dispose();
  }

  void _startRename(int index, String current) {
    setState(() {
      _editing = index;
      _rename.text = current;
      _rename.selection = TextSelection(baseOffset: 0, extentOffset: current.length);
    });

    // **Asked for again on the next frame, and the field's own `autofocus` is
    // not enough.** Renaming runs from the context menu, while that menu's
    // route is still being popped, and a popping `ModalRoute` hands focus back
    // to whatever held it before it opened — the canvas — *after* the field has
    // autofocused. The result is a rename field sitting there ready, with the
    // caret in it, that swallows nothing you type. It was invisible for a phase
    // because a double click opened the same field with no route involved and
    // was never affected, so the two ways in behaved differently; the double
    // click is gone now and every rename takes this path.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _editing == index) _renameFocus.requestFocus();
    });
  }

  void _commitRename() {
    final index = _editing;
    if (index == null) return;
    // Ordering matters: clear the field first. Renaming rebuilds the strip, and
    // a build that still believes it is editing rebuilds the text field, which
    // takes focus again — and the tab cannot be left.
    setState(() => _editing = null);

    // **Focus has to be handed somewhere, and the somewhere matters.** Left on
    // a field that is about to be removed from the tree, it ends up nowhere at
    // all — and with no focused node there is nothing for a key event to travel
    // up from, so every shortcut in the application is dead until the user
    // clicks. `previouslyFocusedChild` gives it back to whatever held it before
    // the rename began, which is the canvas.
    _renameFocus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);

    ref.read(workspaceProvider.notifier).renameTab(index, _rename.text);
  }

  Future<void> _tabMenu(int index, Offset globalPosition) async {
    final controller = ref.read(workspaceProvider.notifier);
    final tabs = ref.read(workspaceProvider).preset.tabs;
    final colors = OaaTheme.of(context);

    final action = await showMenu<_TabAction>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        oaaMenuItem(context, _TabAction.rename, 'Rename'),
        oaaMenuItem(context, _TabAction.duplicate, 'Duplicate'),
        oaaMenuItem(
          context,
          _TabAction.delete,
          'Delete',
          // The last tab cannot be deleted, and saying so in the menu is
          // better than an item that silently does nothing.
          color: tabs.length > 1 ? colors.over : colors.textFaint,
        ),
      ],
    );

    if (action == null || !mounted) return;

    switch (action) {
      case _TabAction.rename:
        _startRename(index, tabs[index].name);
      case _TabAction.duplicate:
        controller.duplicateTab(index);
      case _TabAction.delete:
        controller.removeTab(index);
    }
  }

  Future<void> _addModule() async {
    final box = context.findRenderObject() as RenderBox?;
    final anchor = box == null ? Offset.zero : box.localToGlobal(Offset(box.size.width, box.size.height));

    final kind = await showModuleKindMenu(context, anchor);
    if (kind == null || !mounted) return;
    ref.read(workspaceProvider.notifier).addModule(kind);
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final workspace = ref.watch(workspaceProvider);
    final controller = ref.watch(workspaceProvider.notifier);
    final tabs = workspace.preset.tabs;

    return SizedBox(
      height: TabStrip.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(
            bottom: BorderSide(color: colors.hairline, width: OaaStroke.hairline),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: Space.md),
          child: Row(
            children: [
              // **`Expanded`, and no `Spacer` after it.** It was a `Flexible`
              // beside a `Spacer`, which is two flex children of equal weight:
              // the strip handed half of its free width to the gap and then
              // clipped the last tab off the end of a strip that was visibly
              // half empty. Three tabs in an 800 px window was enough to do it.
              // With the gap gone the tabs have every pixel the actions do not,
              // and scroll only when they genuinely do not fit.
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (var i = 0; i < tabs.length; i++)
                        if (_editing == i)
                          _RenameField(controller: _rename, focusNode: _renameFocus, onCommit: _commitRename)
                        else
                          _Tab(label: tabs[i].name, active: i == workspace.activeTab, onTap: () => controller.selectTab(i), onMenu: (position) => _tabMenu(i, position)),
                      // Inside the scroller, so that "add a tab" stays beside
                      // the last tab instead of being carried to the far end of
                      // the strip and sitting against the history arrows.
                      _StripAction(
                        tooltip: 'New tab',
                        onPressed: controller.addTab,
                        builder: (color) => _Plus(color: color),
                      ),
                    ],
                  ),
                ),
              ),
              // Word and mark, the shape `+ MODULE` uses: the word says which
              // of the two this is, and the mirrored arrow beside it says which
              // way it runs before the word has been read. The pair were marks
              // alone for a while and it cost more than it saved — an unlabelled
              // control in the one row that also holds the tabs is a thing you
              // have to hover to identify, every time, and undo is not a control
              // anybody wants to hover first.
              _StripAction(
                tooltip: 'Undo',
                enabled: controller.canUndo,
                onPressed: controller.undo,
                builder: (color) => _HistoryAction(label: 'UNDO', color: color),
              ),
              _StripAction(
                tooltip: 'Redo',
                enabled: controller.canRedo,
                onPressed: controller.redo,
                builder: (color) => _HistoryAction(label: 'REDO', color: color, forward: true),
              ),
              // The strip holds two kinds of action, and until this rule was
              // here they ran together as one row of four: `UNDO` and `REDO`
              // step through what has already been done, `+ MODULE` does
              // something new. Nothing else in the strip separates them —
              // they are the same size, the same colour and the same weight.
              const _StripRule(),
              // Between the two: larger than the word it is attached to, and
              // smaller than the lone plus beside the tabs. The tab plus has to
              // be found on its own, so it is sized to carry the whole action;
              // this one only has to be seen, because `MODULE` is doing the
              // saying — and a symbol set as large as that one would read as a
              // second control rather than as part of this one.
              _StripAction(
                tooltip: 'Add a module',
                onPressed: _addModule,
                builder: (color) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _Plus(color: color, size: _Plus.attached),
                    const SizedBox(width: Space.xs),
                    Text('MODULE', style: OaaType.label.copyWith(color: color)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TabAction { rename, duplicate, delete }

class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active, required this.onTap, required this.onMenu});

  final String label;
  final bool active;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    // **Long press, not double tap.** Renaming used to be a double click here,
    // which armed a `DoubleTapGestureRecognizer` over the tab — and that
    // recogniser holds the gesture arena from the first tap until
    // `kDoubleTapTimeout` expires. The arena is never swept while it is held,
    // so [onTap] could not win it and switching tabs took 300 ms every time.
    // A long press costs nothing: it resolves by rejecting when the pointer
    // lifts early, so the tap is swept at once.
    //
    // It also opens the menu rather than the field, which is what a tablet
    // was missing — there is no right mouse button there, so rename, duplicate
    // and delete were all unreachable on one.
    return GestureDetector(
      onTap: onTap,
      onLongPressStart: (details) => onMenu(details.globalPosition),
      onSecondaryTapUp: (details) => onMenu(details.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          height: TabStrip.height,
          padding: const EdgeInsets.symmetric(horizontal: Space.smd),
          alignment: Alignment.center,
          // A bottom rule rather than a filled chip. The active tab has to be
          // unmistakable without introducing a second surface colour into a
          // palette whose depth comes entirely from hairlines.
          //
          // Drawn in `textPrimary` and not the signal hue: this strip sits
          // directly above the meters, so an accent rule here is the same
          // colour as an in-spec reading a few pixels below it. The label
          // already carries the state as well — textPrimary when active,
          // textFaint when not — so the rule is confirming, not carrying.
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: active ? colors.textPrimary : Colors.transparent, width: OaaStroke.emphasis),
            ),
          ),
          child: Text(label.toUpperCase(), style: OaaType.label.copyWith(color: active ? colors.textPrimary : colors.textFaint)),
        ),
      ),
    );
  }
}

class _RenameField extends StatelessWidget {
  const _RenameField({required this.controller, required this.focusNode, required this.onCommit});

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    return SizedBox(
      width: 120,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        child: Center(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            style: OaaType.label.copyWith(color: colors.textPrimary),
            cursorColor: colors.textPrimary,
            cursorWidth: OaaStroke.hairline,
            decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.zero),
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => onCommit(),
            // Committing on tap-outside as well as on Enter. A field that can
            // only be dismissed with a key is a trap on a tablet.
            onTapOutside: (_) => onCommit(),
          ),
        ),
      ),
    );
  }
}

/// The hairline that separates the history actions from `+ MODULE`.
///
/// Short of the strip's own edges at both ends, because a rule that ran the full
/// height would meet the canvas hairline below it and the window chrome above,
/// and three lines meeting at a corner read as a table cell rather than as a
/// division inside a row.
///
/// **The active tab's rule is reserved here too**, for the reason `_StripAction`
/// gives: everything in this row is centred in the strip *minus* that rule, and
/// a divider centred in the whole of it sits a pixel high against the words it
/// divides.
class _StripRule extends StatelessWidget {
  const _StripRule();

  /// The gap above and below.
  static const double _inset = Space.sm;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    // The strip's height on the outside and the insets within it, rather than a
    // height plus padding: the row gives its children a *loose* 32 px, so a
    // padded 32 px rule is a 42 px child and a striped overflow warning.
    return SizedBox(
      height: TabStrip.height,
      child: Padding(
        padding: const EdgeInsets.only(left: Space.xs, right: Space.xs, top: _inset, bottom: _inset + OaaStroke.emphasis),
        child: ColoredBox(
          color: colors.hairline,
          child: const SizedBox(width: OaaStroke.hairline, height: double.infinity),
        ),
      ),
    );
  }
}

/// The shell every action in this row is built from: one height, one padding,
/// one hit target, one place where "disabled" is decided.
class _StripAction extends StatelessWidget {
  const _StripAction({required this.builder, required this.onPressed, required this.tooltip, this.enabled = true});

  /// Handed the colour the contents should take.
  ///
  /// A builder rather than a `child` so that the enabled state is resolved to a
  /// colour once, here. Passing [enabled] to the shell *and* to whatever it
  /// contains is two copies of one fact, and a greyed-out arrow above a live
  /// hit target is a control that lies about itself.
  final Widget Function(Color color) builder;

  final VoidCallback onPressed;
  final bool enabled;

  /// Required, not optional.
  ///
  /// One of the four actions in this row is a mark and nothing else, and a mark
  /// that cannot be hovered has no name at all. It is also the semantic label:
  /// `Tooltip` contributes a hint, not a name, so a screen reader on the lone
  /// plus would otherwise announce a button with nothing in it, and the three
  /// that do carry a word need the tooltip to say *which* thing it adds or
  /// steps through — see `excludeSemantics` below.
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        // The word inside `+ MODULE`, `UNDO` or `REDO` would otherwise be
        // announced beside the label that already names the action.
        excludeSemantics: true,
        child: GestureDetector(
          onTap: enabled ? onPressed : null,
          behavior: HitTestBehavior.opaque,
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
            child: Container(
              height: TabStrip.height,
              // **The active tab's rule is reserved here as well.** A `_Tab`
              // draws a bottom border of `OaaStroke.emphasis` whether or not it
              // is the active one, and a border insets the child — so a tab's
              // label is centred in the strip *minus* the rule, while a button
              // with no border is centred in the whole of it. Every action in
              // this row sat a pixel below the tab labels because of that, and
              // the `+` sits directly beside the last tab where a pixel is
              // impossible to miss.
              padding: const EdgeInsets.only(left: Space.sm, right: Space.sm, bottom: OaaStroke.emphasis),
              alignment: Alignment.center,
              child: builder(enabled ? colors.textMuted : colors.textFaint),
            ),
          ),
        ),
      ),
    );
  }
}

/// The `+` that opens something new.
///
/// Larger than the words beside it, at one of two sizes. A word is found by its
/// shape, which is why [OaaType.label] is sized for one; a symbol has no shape
/// to be found by, so how far above the words it is set depends on how much of
/// the action it is carrying — see [lone] and [attached]. It stays in
/// `textMuted` at either size, so it is louder in size and no louder in tone
/// than the row it sits in.
class _Plus extends StatelessWidget {
  const _Plus({required this.color, this.size = lone});

  final Color color;
  final double size;

  /// Standing on its own, with no word: the whole of "add a tab".
  static const double lone = 15;

  /// Punctuating a word that is doing the saying. Visible without competing —
  /// as large as this one gets and it stops reading as part of `+ MODULE` and
  /// starts reading as a second control beside it.
  static const double attached = 13;

  /// Pixels to push the plus down, so that its ink lands where the row's words
  /// are rather than where its line box is.
  ///
  /// **Measured off an 8× rendering, one number per size, not derived.** The
  /// model that ought to serve both — cap band here, math axis there, each a
  /// fraction of its own font size — is out by two thirds of a pixel on
  /// [attached], because the two pluses do not sit in the same kind of box:
  /// [lone] is centred alone in the row, and [attached] is centred by a `Row`
  /// against a line box two thirds its height. Two numbers that were measured
  /// beat one formula that is nearly right, and "nearly right" here is exactly
  /// the amount that reads as wrong without reading as broken.
  ///
  /// The two targets are not the same, either. [attached] lands on the cap band
  /// of `MODULE`, 4 px away, where the eye compares the two directly and
  /// anything else is a misalignment. [lone] is set a further pixel below the
  /// band by eye: with no word close enough to compare it against, on the band
  /// it reads as floating.
  ///
  /// Re-measure both if either size changes. Render the strip, threshold it,
  /// and compare ink bounding boxes — see `lib/src/canvas/AGENTS.md`.
  double get _drop => size == lone ? 0.68 : -0.93;

  @override
  Widget build(BuildContext context) => Transform.translate(
    offset: Offset(0, _drop),
    child: Text(
      '+',
      style: OaaType.label.copyWith(
        fontSize: size,
        // The label style tracks its words out by 0.8; on a single glyph that
        // is trailing air the centring has to fight.
        letterSpacing: 0,
        color: color,
      ),
    ),
  );
}

/// `UNDO` or `REDO`, with the u-turn that says which way it runs.
///
/// The mark is `OaaMark.undo` and `OaaMark.redo` — drawn by `oaa_ui`, like every
/// other mark in the application, rather than set from a font. **Neither bundled
/// face has the glyph**: `↶` U+21B6 and `↷` U+21B7 are absent from Inter *and*
/// from Google Sans Code, as are `⟲` U+27F2 and `⟳` U+27F3, and the mono face
/// has no `↺` U+21BA either — the one-character answer is a tofu box whose
/// shape depends on which fallback the host happens to offer.
///
/// An icon font would have been genuinely platform-independent: `Icons.undo` and
/// `CupertinoIcons.arrow_uturn_left` are both TTFs Flutter rasterises itself
/// rather than lookups into the host's symbol set, so neither is an Apple
/// feature the way SF Symbols is, and the Material one is already paid for by
/// `uses-material-design: true`. Both are the wrong mark for this row all the
/// same — filled shapes drawn on a 24 dp grid, carrying several times the
/// optical weight of the hairlines the rest of the interface is made from — and
/// a second way of drawing marks is worse than either.
class _HistoryAction extends StatelessWidget {
  const _HistoryAction({required this.label, required this.color, this.forward = false});

  final String label;
  final Color color;
  final bool forward;

  /// The mark's box.
  ///
  /// Larger than [_Plus.attached] and drawing less ink than it: `OaaGlyph`
  /// squares its box and the u-turn is a wide mark, so it fills the width and
  /// takes about two thirds of the height. At `Space.md`, the box every mark
  /// beside *body* text uses, it stood a third taller than the cap band of the
  /// word next to it — right beside 13 px prose, too loud beside a 10 px label.
  static const double _size = 14;

  /// Pixels to push the mark down, so that its ink is centred on the cap band
  /// of the word rather than on the line box the `Row` centres it against.
  ///
  /// **Measured off an 8× rendering, not derived** — the same rule as
  /// [_Plus._drop], and re-measure it if [_size] or [OaaType.label] moves. The
  /// target is the one the attached plus already meets: the mark's ink centre
  /// on the cap band's centre, which at 8× is the two bounding boxes sharing a
  /// midpoint to the device pixel. The mark needs less correction than a glyph
  /// does, because `OaaGlyph` already centres its ink in its own bounds — all
  /// that is left is the word's own offset from the middle of its line box.
  static const double _drop = 0.31;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Transform.translate(
        offset: const Offset(0, _drop),
        child: OaaGlyph(forward ? OaaMark.redo : OaaMark.undo, color: color, size: _size),
      ),
      const SizedBox(width: Space.xs),
      Text(label, style: OaaType.label.copyWith(color: color)),
    ],
  );
}
