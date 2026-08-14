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
  }

  void _commitRename() {
    final index = _editing;
    if (index == null) return;
    // Ordering matters: clear the field first. Renaming rebuilds the strip, and
    // a build that still believes it is editing rebuilds the text field, which
    // takes focus again — and the tab cannot be left.
    setState(() => _editing = null);
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
              Flexible(
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
                            onRename: () => _startRename(i, tabs[i].name),
                            onMenu: (position) => _tabMenu(i, position),
                          ),
                    ],
                  ),
                ),
              ),
              _StripButton(label: '+', onPressed: controller.addTab),
              const Spacer(),
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
    required this.onRename,
    required this.onMenu,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return GestureDetector(
      onTap: onTap,
      onDoubleTap: onRename,
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
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: active ? colors.accent : Colors.transparent,
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
            cursorColor: colors.accent,
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
  });

  final String label;
  final VoidCallback onPressed;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return GestureDetector(
      onTap: enabled ? onPressed : null,
      behavior: HitTestBehavior.opaque,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: Container(
          height: TabStrip.height,
          padding: const EdgeInsets.symmetric(horizontal: Space.sm),
          alignment: Alignment.center,
          child: Text(
            label,
            style: BelType.label.copyWith(
              color: enabled ? colors.textMuted : colors.textFaint,
            ),
          ),
        ),
      ),
    );
  }
}
