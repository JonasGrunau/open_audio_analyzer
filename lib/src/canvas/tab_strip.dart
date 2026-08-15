// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'menus.dart';
import 'workspace.dart';

/// The tab strip, and the canvas-wide actions that belong next to it.
///
/// Add, undo and redo are here as buttons as well as keyboard shortcuts. Bel
/// runs on tablets, where there is no Cmd+Z and no right mouse button, so a
/// canvas whose only affordances are a chord and a secondary click is a canvas
/// that cannot be edited on half its target platforms.
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
      _rename.selection = TextSelection(
        baseOffset: 0,
        extentOffset: current.length,
      );
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
    _renameFocus.unfocus(
      disposition: UnfocusDisposition.previouslyFocusedChild,
    );

    ref.read(workspaceProvider.notifier).renameTab(index, _rename.text);
  }

  Future<void> _tabMenu(int index, Offset globalPosition) async {
    final controller = ref.read(workspaceProvider.notifier);
    final tabs = ref.read(workspaceProvider).preset.tabs;
    final colors = BelTheme.of(context);

    final action = await showMenu<_TabAction>(
      context: context,
      color: colors.panelRaised,
      position: menuPositionAt(context, globalPosition),
      items: [
        belMenuItem(context, _TabAction.rename, 'Rename'),
        belMenuItem(context, _TabAction.duplicate, 'Duplicate'),
        belMenuItem(
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
    final anchor = box == null
        ? Offset.zero
        : box.localToGlobal(Offset(box.size.width, box.size.height));

    final kind = await showModuleKindMenu(context, anchor);
    if (kind == null || !mounted) return;
    ref.read(workspaceProvider.notifier).addModule(kind);
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final workspace = ref.watch(workspaceProvider);
    final controller = ref.watch(workspaceProvider.notifier);
    final tabs = workspace.preset.tabs;

    return SizedBox(
      height: TabStrip.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(
            bottom: BorderSide(
              color: colors.hairline,
              width: BelStroke.hairline,
            ),
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
                          _RenameField(
                            controller: _rename,
                            focusNode: _renameFocus,
                            onCommit: _commitRename,
                          )
                        else
                          _Tab(
                            label: tabs[i].name,
                            active: i == workspace.activeTab,
                            onTap: () => controller.selectTab(i),
                            onMenu: (position) => _tabMenu(i, position),
                          ),
                      // Inside the scroller, so that "add a tab" stays beside
                      // the last tab instead of being carried to the far end of
                      // the strip and sitting against UNDO.
                      _StripButton(
                        label: '+',
                        glyph: true,
                        onPressed: controller.addTab,
                      ),
                    ],
                  ),
                ),
              ),
              _StripButton(
                label: 'UNDO',
                enabled: controller.canUndo,
                onPressed: controller.undo,
              ),
              _StripButton(
                label: 'REDO',
                enabled: controller.canRedo,
                onPressed: controller.redo,
              ),
              const SizedBox(width: Space.sm),
              _StripButton(label: '+ MODULE', onPressed: _addModule),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TabAction { rename, duplicate, delete }

class _Tab extends StatelessWidget {
  const _Tab({
    required this.label,
    required this.active,
    required this.onTap,
    required this.onMenu,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

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
              bottom: BorderSide(
                color: active ? colors.textPrimary : Colors.transparent,
                width: BelStroke.emphasis,
              ),
            ),
          ),
          child: Text(
            label.toUpperCase(),
            style: BelType.label.copyWith(
              color: active ? colors.textPrimary : colors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}

class _RenameField extends StatelessWidget {
  const _RenameField({
    required this.controller,
    required this.focusNode,
    required this.onCommit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onCommit;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return SizedBox(
      width: 120,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        child: Center(
          child: TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            style: BelType.label.copyWith(color: colors.textPrimary),
            cursorColor: colors.textPrimary,
            cursorWidth: BelStroke.hairline,
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              contentPadding: EdgeInsets.zero,
            ),
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

class _StripButton extends StatelessWidget {
  const _StripButton({
    required this.label,
    required this.onPressed,
    this.enabled = true,
    this.glyph = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  /// Whether the label is a bare glyph rather than a word.
  ///
  /// `+` is drawn centred on the font's math axis, which sits roughly a
  /// thirteenth of an em below the middle of the cap band that `LOUDNESS` and
  /// `UNDO` occupy. Words need no correction because the line box is already
  /// centred on the band they fill; a lone symbol does, and without it the
  /// plus sagged towards the baseline of the tab beside it and read as a
  /// speck of dirt rather than a control.
  final bool glyph;

  /// Measured against the cap band of [BelType.label], and expressed as a
  /// fraction of the size so it survives a change to it.
  static const double _mathAxisDrop = 0.075;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final text = Text(
      label,
      style: BelType.label.copyWith(
        color: enabled ? colors.textMuted : colors.textFaint,
      ),
    );

    return GestureDetector(
      onTap: enabled ? onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Container(
          height: TabStrip.height,
          // **The active tab's rule is reserved here as well.** A `_Tab` draws
          // a bottom border of `BelStroke.emphasis` whether or not it is the
          // active one, and a border insets the child — so a tab's label is
          // centred in the strip *minus* the rule, while a button with no
          // border is centred in the whole of it. Every action in this row sat
          // a pixel below the tab labels because of that, and the `+` sits
          // directly beside the last tab where a pixel is impossible to miss.
          padding: const EdgeInsets.only(
            left: Space.sm,
            right: Space.sm,
            bottom: BelStroke.emphasis,
          ),
          alignment: Alignment.center,
          child: glyph
              ? Transform.translate(
                  offset: Offset(0, -BelType.label.fontSize! * _mathAxisDrop),
                  child: text,
                )
              : text,
        ),
      ),
    );
  }
}
