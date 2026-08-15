// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';

import '../app/shortcuts.dart';

/// The shortcut sheet, drawn from the same table the bindings come from.
///
/// It is a list of what Bel *does* respond to, not a list somebody wrote about
/// it — see `lib/src/app/shortcuts.dart`. There is nothing to keep in step here
/// because there is nothing here to keep.
///
/// It exists at all because a shortcut nobody can find is a shortcut nobody
/// uses, and Bel has no menu bar to discover them from: the application draws
/// its own chrome, so the usual place a desktop user looks — File, Edit, the
/// greyed-out chord printed beside each item — is not there to look at.
Future<void> showShortcutsSheet(BuildContext context) => showBelPanel<void>(
  context: context,
  builder: (context) => const _ShortcutsSheet(),
);

class _ShortcutsSheet extends StatelessWidget {
  const _ShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    // The keyboard in front of the user, not the operating system underneath
    // them — both are bound either way; only the printing differs.
    final apple = useAppleKeyNames;

    // **600, and no footer.** Seventeen rows and four headings come to more
    // than the panel's 760 px, and a sheet whose last row is cut in half reads
    // as unfinished even though it scrolls. The width stops the two longest
    // descriptions wrapping onto a second line, and the title bar's × — plus
    // Esc, plus clicking the barrier — is three ways out already. A footer
    // whose only button repeats one of them is a row of chrome that pushed a
    // real row off the bottom.
    return PanelScaffold(
      title: 'Keyboard shortcuts',
      width: 600,
      onClose: Navigator.of(context).pop,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final group in ShortcutGroup.values)
            if (belShortcuts.any((s) => s.group == group))
              PanelSection(
                title: group.title,
                children: [
                  for (final shortcut in belShortcuts)
                    if (shortcut.group == group)
                      _Row(shortcut: shortcut, apple: apple),
                ],
              ),
          _Footnote(apple: apple),
        ],
      ),
    );
  }
}

/// Width of the keycap column. See the comment where it is used.
const double _keyColumn = 190;

class _Row extends StatelessWidget {
  const _Row({required this.shortcut, required this.apple});

  final BelShortcut shortcut;
  final bool apple;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Padding(
      // Tighter than a PanelRow. This is a reference table read by scanning
      // down it, not a list of controls to be aimed at, and seventeen rows at
      // settings-panel spacing do not fit on a laptop.
      padding: const EdgeInsets.symmetric(vertical: Space.xxs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              shortcut.description,
              style: BelType.body.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: Space.md),
          // **A fixed column, not a second flex child.** An `Expanded` beside a
          // `Flexible` splits the row in half whatever the two of them actually
          // need, so the descriptions were wrapping at half width while the
          // keycaps sat in three hundred pixels of nothing. Same shape as the
          // bug in the tab strip. 190 holds the widest pair there is —
          // `Ctrl+Shift+Tab` and `Ctrl+[` — and leaves the longest description
          // on one line.
          //
          // A `Wrap` rather than a `Row` because two caps is normal here, and
          // on a second line is better than an overflow.
          SizedBox(
            width: _keyColumn,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: Space.xs,
              runSpacing: Space.xs,
              children: [
                for (final cap in shortcut.keycaps(apple: apple))
                  _Keycap(label: cap),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A key, drawn the way it is printed on one.
class _Keycap extends StatelessWidget {
  const _Keycap({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.panelRaised,
        borderRadius: BelRadius.allXs,
        border: Border.all(color: colors.hairline, width: BelStroke.hairline),
      ),
      // Monospaced with tabular figures like every other glyph in Bel that
      // stands for something exact. `⌘` and `Ctrl` sitting at different weights
      // in the same column reads as two different kinds of thing.
      child: Text(
        label,
        style: BelType.caption.copyWith(color: colors.textMuted),
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote({required this.apple});

  final bool apple;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Text(
      apple
          ? 'Ctrl works everywhere ⌘ does. Shortcuts without ⌃ or ⌘ stand '
                'aside while you are typing in a field.'
          : 'Cmd works everywhere Ctrl does. Shortcuts without Ctrl or Cmd '
                'stand aside while you are typing in a field.',
      style: BelType.caption.copyWith(color: colors.textFaint),
    );
  }
}
