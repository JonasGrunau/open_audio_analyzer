// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';

import '../app/shortcuts.dart';

/// The shortcut sheet, drawn from the same table the bindings come from.
///
/// It is a list of what Open Audio Analyzer *does* respond to, not a list
/// somebody wrote about it — see `lib/src/app/shortcuts.dart`. There is nothing
/// to keep in step here because there is nothing here to keep.
///
/// It exists at all because a shortcut nobody can find is a shortcut nobody
/// uses, and Open Audio Analyzer has no menu bar to discover them from: the
/// application draws its own chrome, so the usual place a desktop user looks —
/// File, Edit, the greyed-out chord printed beside each item — is not there to
/// look at.
Future<void> showShortcutsSheet(BuildContext context) => showOaaPanel<void>(
  context: context,
  builder: (context) => const _ShortcutsSheet(),
);

/// **Wider than any other panel, and two columns rather than one.**
///
/// Seventeen rows and four headings in a single 600 px column came to more than
/// the panel's 760 px of height, so the sheet scrolled — and what it cut off was
/// the footnote explaining that Ctrl and Cmd are interchangeable, mid-sentence,
/// which is the one line on the sheet that is not derivable from the rows above
/// it. Everything else about it was cramped for the same reason: rows two pixels
/// apart to buy height that was never going to be enough, and a keycap column
/// pinned three hundred pixels away from the description it belonged to.
///
/// Two columns spend width, which this panel has and the others do not. A
/// reference table is read by scanning, and a scan that has to be interrupted to
/// find the scrollbar is a scan that starts again. The whole sheet is now on
/// screen at once at the smallest window the application allows — 960 px wide,
/// which leaves 896 for a panel — with room for the rows to breathe.
const double _sheetWidth = 880;

/// Widest column first: the long descriptions and the long chords are in
/// different halves of the table, and 3:2 is the ratio that fits both without
/// wrapping either.
const int _leftFlex = 3;
const int _rightFlex = 2;

class _ShortcutsSheet extends StatelessWidget {
  const _ShortcutsSheet();

  @override
  Widget build(BuildContext context) {
    // The keyboard in front of the user, not the operating system underneath
    // them — both are bound either way; only the printing differs.
    final apple = useAppleKeyNames;
    final (left, right) = _columns();

    // **No footer.** The title bar's × — plus Esc, plus clicking the barrier —
    // is three ways out already, and a footer whose only button repeats one of
    // them is a row of chrome that earns nothing.
    return PanelScaffold(
      title: 'Keyboard shortcuts',
      width: _sheetWidth,
      onClose: Navigator.of(context).pop,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // **Two columns only when the panel got the width it asked for.**
          // `width:` is a maximum, not a promise: a window narrower than
          // 944 px — under the supported minimum, which a tablet is — squeezes
          // the panel, and a squeezed pair of columns is not a narrower table
          // but a broken one, because the keycaps do not shrink. They would run
          // past the right edge of their own column, which a `Row` reports as
          // an overflow in debug and silently clips in release. Stacked, the
          // sheet is what it used to be: one column that scrolls. The
          // comparison is against the width the scaffold's own padding leaves.
          final stacked =
              right.isEmpty ||
              constraints.maxWidth < _sheetWidth - Space.lg * 2;

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stacked)
                _GroupColumn(groups: [...left, ...right], apple: apple)
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: _leftFlex,
                      child: _GroupColumn(groups: left, apple: apple),
                    ),
                    const SizedBox(width: Space.xl),
                    Expanded(
                      flex: _rightFlex,
                      child: _GroupColumn(groups: right, apple: apple),
                    ),
                  ],
                ),
              const SizedBox(height: Space.lg),
              _Footnote(apple: apple),
            ],
          );
        },
      ),
    );
  }
}

/// The groups that have rows, split into two columns of nearly equal height.
///
/// Counted in row-equivalents rather than in sections, because a heading costs
/// about a row and a section that is not first in its column costs its rule as
/// well. Derived rather than written down: naming which group goes where would
/// be a second place a shortcut has to be registered, and the point of
/// `oaaShortcuts` is that there is one.
(List<ShortcutGroup>, List<ShortcutGroup>) _columns() {
  final groups = [
    for (final group in ShortcutGroup.values)
      if (oaaShortcuts.any((s) => s.group == group)) group,
  ];

  int height(Iterable<ShortcutGroup> column) {
    var total = 0;
    for (final (index, group) in column.indexed) {
      // The rows, the heading, and the rule above every section but the first.
      total += oaaShortcuts.where((s) => s.group == group).length + 1;
      if (index > 0) total++;
    }
    return total;
  }

  var best = groups.length;
  int? closest;
  for (var split = 1; split < groups.length; split++) {
    final gap = (height(groups.take(split)) - height(groups.skip(split))).abs();
    if (closest == null || gap < closest) {
      closest = gap;
      best = split;
    }
  }

  return (groups.take(best).toList(), groups.skip(best).toList());
}

class _GroupColumn extends StatelessWidget {
  const _GroupColumn({required this.groups, required this.apple});

  final List<ShortcutGroup> groups;
  final bool apple;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (final (index, group) in groups.indexed)
        PanelSection(
          title: group.title,
          // Every column starts a fresh one: a rule at the top of the right
          // column would be a line hanging under the title bar with nothing
          // above it to rule off.
          ruled: index > 0,
          children: [
            for (final shortcut in oaaShortcuts)
              if (shortcut.group == group)
                _Row(shortcut: shortcut, apple: apple),
          ],
        ),
    ],
  );
}

class _Row extends StatelessWidget {
  const _Row({required this.shortcut, required this.apple});

  final OaaShortcut shortcut;
  final bool apple;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Padding(
      // Tighter than a `PanelRow`, and no longer as tight as it can be made.
      // This is a reference table read by scanning down it rather than a list
      // of controls to be aimed at — but a scan needs the rows to be separable,
      // and at `Space.xxs` seventeen of them were a single grey block.
      padding: const EdgeInsets.symmetric(vertical: Space.xs),
      child: Row(
        // A keycap is a couple of pixels taller than the line of text beside
        // it, so aligning their tops leaves the two strings visibly off each
        // other.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Text(
              shortcut.description,
              style: OaaType.body.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: Space.md),
          // **The keycaps take their natural width; the description takes what
          // is left.** A `Row` lays its inflexible children out first, so this
          // needs no column width of its own — which matters here because the
          // two columns hold chords of quite different lengths and one number
          // could not have suited both. What it must *not* be is a second flex
          // child: an `Expanded` beside a `Flexible` splits the row in half
          // whatever the two of them need, which is how the descriptions came
          // to wrap at half width while the keycaps sat in three hundred pixels
          // of nothing. Same shape as the bug in the tab strip.
          for (final (index, cap)
              in shortcut.keycaps(apple: apple).indexed) ...[
            if (index > 0) const SizedBox(width: Space.xs),
            _Keycap(label: cap),
          ],
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
    final colors = OaaTheme.of(context);

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.sm,
        vertical: Space.xxs,
      ),
      decoration: BoxDecoration(
        color: colors.panelRaised,
        borderRadius: OaaRadius.allXs,
        border: Border.all(color: colors.hairline, width: OaaStroke.hairline),
      ),
      // One style for every cap, whatever is printed on it. `⌘` and `Ctrl`
      // sitting at different sizes or weights in the same column reads as two
      // different kinds of thing, and they are not — they are both the key
      // under your finger.
      child: Text(
        label,
        style: OaaType.caption.copyWith(color: colors.textMuted),
      ),
    );
  }
}

class _Footnote extends StatelessWidget {
  const _Footnote({required this.apple});

  final bool apple;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Text(
      apple
          ? 'Ctrl works everywhere ⌘ does. Shortcuts without ⌃ or ⌘ stand '
                'aside while you are typing in a field.'
          : 'Cmd works everywhere Ctrl does. Shortcuts without Ctrl or Cmd '
                'stand aside while you are typing in a field.',
      style: OaaType.caption.copyWith(color: colors.textFaint),
    );
  }
}
