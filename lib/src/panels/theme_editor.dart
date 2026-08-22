// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';

import '../data/providers.dart';

/// Opens the skin editor on [base], previewing it for as long as it is open.
///
/// The draft's lifetime is owned here rather than inside the widget, because it
/// is exactly the lifetime of the route: set before the push, cleared after the
/// pop, including when the pop came from the escape key or a back gesture that
/// the panel never heard about. A draft that outlived its editor would be a
/// skin nobody can get out of.
Future<void> showThemeEditor(
  BuildContext context,
  WidgetRef ref, {
  required Skin base,
}) async {
  final resolved = base.resolved();
  ref.read(skinDraftProvider.notifier).begin(resolved);
  try {
    await showOaaPanel<void>(
      context: context,
      builder: (context) => ThemeEditor(base: resolved),
    );
  } finally {
    ref.read(skinDraftProvider.notifier).end();
  }
}

/// The thirteen colours a skin is.
///
/// ---------------------------------------------------------------------------
/// It previews by *being* the skin
///
/// There is no preview pane holding a copy of the palette. Every change goes
/// straight into `skinDraftProvider`, which `skinProvider` answers with, so the
/// canvas behind this panel, the fourteen modules on it, this panel's own
/// hairlines and any tablet attached to the session all repaint together. That
/// is the whole reason the panel is 620 px over a canvas that is not: what you
/// are judging is the meters, and a swatch grid tells you nothing about whether
/// a track is visible behind a fill.
///
/// The one thing the canvas cannot be relied on to show is a role that happens
/// not to be on screen — nobody has an alert meter open at the moment they pick
/// the colour that means over — so [_Preview] carries a strip of the meter
/// roles in the context they are read in.
///
/// ---------------------------------------------------------------------------
/// It warns and never refuses
///
/// `Skin.fromJson` loads a file with a typo'd key rather than declining to
/// start, and an editor stricter than the parser is an editor that will not let
/// somebody save the palette they are looking at. So a role below the floor
/// `kSkinContrastRules` records gets its ratio marked and its reason printed,
/// the footer says how many there are, and Save is not disabled. See
/// `packages/oaa_core/lib/src/skin_contrast.dart` for where the floors come
/// from and which two shipped defects put them there.
class ThemeEditor extends ConsumerStatefulWidget {
  const ThemeEditor({required this.base, super.key});

  /// The skin as it was when the editor opened. Resolved — a sparse document is
  /// edited as the thirteen colours it will actually be drawn with, because
  /// changing one role of a file that names three is otherwise a change to a
  /// colour the author cannot see.
  final Skin base;

  @override
  ConsumerState<ThemeEditor> createState() => _ThemeEditorState();
}

class _ThemeEditorState extends ConsumerState<ThemeEditor> {
  late final _name = TextEditingController(text: widget.base.name)
    ..addListener(_onNameChanged);
  late final _note = TextEditingController(text: widget.base.note)
    ..addListener(_onNoteChanged);

  /// The document as it stands on disk: what the editor opened on, and then
  /// whatever Save last wrote — **including its id**, so that saving a copy
  /// moves this panel onto the copy instead of reopening it.
  ///
  /// **Not `widget.base`, and the difference is the panel's whole idea of
  /// unsaved.** Compared against the state at open, a skin stays dirty forever
  /// the moment it is saved once — so the footer says "unsaved changes" over a
  /// file that is on disk, and closing asks a question with no answer. Revert
  /// takes the same baseline for the same reason: after a save, "back to how it
  /// was" means the version that was saved.
  late Skin _committed = widget.base;

  /// Which role's picker is open. One at a time, so the panel stays a column of
  /// rows and the canvas it is previewing stays visible beside it.
  SkinColor? _open;

  String? _status;
  bool _confirmDelete = false;
  bool _confirmClose = false;

  @override
  void dispose() {
    _name
      ..removeListener(_onNameChanged)
      ..dispose();
    _note
      ..removeListener(_onNoteChanged)
      ..dispose();
    super.dispose();
  }

  // --- Reading and writing the draft ----------------------------------------

  Skin get _draft => ref.read(skinDraftProvider) ?? _committed;

  void _update(Skin next) {
    ref.read(skinDraftProvider.notifier).update(next);
    if (_status != null || _confirmClose) {
      setState(() {
        _status = null;
        _confirmClose = false;
      });
    }
  }

  void _onNameChanged() => _update(_draft.copyWith(name: _name.text));
  void _onNoteChanged() => _update(_draft.copyWith(note: _note.text));

  // --- Actions --------------------------------------------------------------

  void _revert() {
    final to = _committed;
    _update(to);
    // Assigning `.text` fires the listener, which writes the same value back
    // through `_update`. Harmless, and cheaper than suppressing it.
    _name.text = to.name;
    _note.text = to.note;
    setState(() {
      _open = null;
      _status = 'Reverted to the skin as it was opened.';
    });
  }

  Future<void> _save({required bool asNew}) async {
    final library = ref.read(skinLibraryProvider.notifier);
    final draft = _draft;

    // A built-in has no in-place save to fall back to, and the button that
    // would call for one is not drawn. Decided here as well: the library
    // refuses it too, and a rule with one owner is a rule.
    final copy = asNew || library.isBuiltIn(draft.id);
    final renamed = draft.name.trim() != _committed.name.trim();

    // Somebody who has already renamed it means that name. Only the ones still
    // carrying the original get "copy" appended, and only once however many
    // times they are copied.
    final name = renamed || draft.name.endsWith(' copy')
        ? draft.name
        : '${draft.name} copy';

    // The id comes from the *final* name, not the one on screen a moment ago.
    // Derived from `draft.name` instead, a copy of Precision Instrument asks
    // for `precision-instrument`, finds the built-in already holding it, and
    // lands on `precision-instrument-2` — a file whose name matches nothing a
    // user typed or saw.
    final skin = copy
        ? draft.copyWith(
            id: _uniqueId(name, fallback: draft.id),
            name: name,
          )
        : draft;

    final saved = await library.save(skin);
    if (!mounted) return;

    if (!saved) {
      setState(() {
        _status =
            ref.read(storageNoticeProvider) ?? 'Could not write the skin.';
      });
      return;
    }

    // Selecting it is what makes the save visible once the draft is dropped:
    // without this, saving a new skin would write a file and then snap the
    // application back to the one that was active before the editor opened.
    ref.read(settingsProvider.notifier).setSkinId(skin.id);

    // **The panel stays open and becomes the editor for what was just
    // written.** Copying used to pop and reopen, which is the obvious way to
    // move a panel that holds its base as `final` onto a new document, and is a
    // race: `showThemeEditor`'s `finally` clears the draft when the *old* route
    // finishes popping — a frame or two after the new one has set its own — so
    // the reopened editor briefly previewed a skin nobody had chosen.
    //
    // Everything that used to read `widget.base` reads [_committed] instead,
    // and moving it is the whole of what a copy does to this panel: Delete
    // appears, Save appears, the built-in note goes.
    ref.read(skinDraftProvider.notifier).update(skin);
    setState(() {
      _committed = skin;
      _status = 'Saved ${skin.name}.';
    });
    // Assigning `.text` fires each listener, which writes the same value back
    // through `_update`. Guarded only to keep the caret where it was for
    // somebody who did the renaming themselves.
    if (_name.text != skin.name) _name.text = skin.name;
    if (_note.text != skin.note) _note.text = skin.note;
  }

  Future<void> _delete() async {
    if (!_confirmDelete) {
      setState(() => _confirmDelete = true);
      return;
    }

    final removed = await ref
        .read(skinLibraryProvider.notifier)
        .remove(_committed.id);
    if (!mounted) return;

    if (!removed) {
      setState(() {
        _confirmDelete = false;
        _status = ref.read(storageNoticeProvider) ?? 'Could not delete it.';
      });
      return;
    }
    Navigator.of(context).pop();
  }

  void _close() {
    if (_dirty && !_confirmClose) {
      setState(() => _confirmClose = true);
      return;
    }
    Navigator.of(context).pop();
  }

  bool get _dirty => _draft != _committed;

  /// An id nothing else has, derived from the name where there is one.
  ///
  /// A skin renamed to "Midnight" becomes `midnight.json` rather than
  /// `precision-instrument-copy.json`. The id is what the file is called and
  /// what a preset stores, so it is worth being the name somebody chose.
  String _uniqueId(String name, {required String fallback}) {
    // Every id in the library, which is what makes a built-in's id taken as
    // well as a user skin's — the library would refuse it, and refusing a save
    // somebody pressed because of a name they did not choose is not an answer.
    final taken = {for (final skin in ref.read(skinLibraryProvider)) skin.id};
    final stem = slugify(name).isEmpty ? '$fallback-copy' : slugify(name);

    var id = stem;
    for (var suffix = 2; taken.contains(id) && suffix < 1000; suffix++) {
      id = '$stem-$suffix';
    }
    return id;
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final draft = ref.watch(skinDraftProvider) ?? _committed;
    final library = ref.watch(skinLibraryProvider.notifier);

    // Keyed by role so a row can find its own verdict without walking the list
    // thirteen times. `meterFill` carries two rules and keeps the worse of
    // them: a fill that is legible against the panel and invisible against its
    // own track is still a broken meter.
    final verdicts = <SkinColor, SkinContrastReport>{};
    for (final report in checkSkinContrast(draft)) {
      final existing = verdicts[report.rule.role];
      if (existing == null ||
          (existing.passes && !report.passes) ||
          (existing.passes == report.passes &&
              report.ratio / report.rule.floor <
                  existing.ratio / existing.rule.floor)) {
        verdicts[report.rule.role] = report;
      }
    }
    final failures = verdicts.values.where((v) => !v.passes).length;

    return PanelScaffold(
      title: 'Skin',
      onClose: _close,
      footer: _footer(colors, library, failures),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Preview(skin: draft),
          const SizedBox(height: Space.md),
          PanelSection(
            title: 'Identity',
            ruled: false,
            children: [
              // Said before anything is dragged rather than after Save is
              // pressed. The two shipped skins are what the roles are proved
              // semantic against — see `SkinLibraryController` — and finding
              // that out from a refusal is finding it out too late.
              if (library.isBuiltIn(draft.id))
                PanelNote(
                  'Precision Instrument and Daylight ship with Open Audio '
                  'Analyzer and cannot be changed or deleted. Everything here '
                  'still previews live — Save as new keeps it, and leaves the '
                  'original to compare against.',
                  mark: OaaMark.warning,
                  tone: colors.textMuted,
                ),
              PanelRow(
                label: 'Name',
                child: OaaTextField(controller: _name, width: _nameWidth),
              ),
              // Prose, and it does not fit beside its own label — the same
              // reason the delivery-target editor gives its note the full
              // width, and the same shape.
              Padding(
                padding: const EdgeInsets.symmetric(vertical: Space.xs),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Note',
                      style: OaaType.body.copyWith(color: colors.textPrimary),
                    ),
                    Text(
                      'Shown under the name in the skin list.',
                      style: OaaType.caption.copyWith(color: colors.textFaint),
                    ),
                    const SizedBox(height: Space.xs),
                    OaaTextField(controller: _note, width: double.infinity),
                  ],
                ),
              ),
              PanelRow(
                label: 'Light palette',
                note:
                    'Dark ink on a light ground. Not guessed from the '
                    'background: it is what the window chrome and the few '
                    'stock menus ask for their own brightness, and a light '
                    'skin under a dark title bar reads as a rendering fault.',
                child: OaaToggle(
                  value: draft.isLight,
                  onChanged: (value) => _update(draft.copyWith(isLight: value)),
                ),
              ),
            ],
          ),
          for (final group in _groups)
            PanelSection(
              title: group.title,
              note: group.note,
              children: [
                for (final role in group.roles)
                  ..._roleRows(colors, draft, role, verdicts[role]),
              ],
            ),
        ],
      ),
    );
  }

  List<Widget> _roleRows(
    OaaColors colors,
    Skin draft,
    SkinColor role,
    SkinContrastReport? verdict,
  ) {
    final expanded = _open == role;
    final failing = verdict != null && !verdict.passes;
    final value = Color(draft.resolve(role));

    return [
      PanelRow(
        label: _roleNames[role]!,
        // Quiet when the colour is fine, and explanatory exactly when it is
        // not. Thirteen permanent paragraphs would be a panel nobody scrolls.
        note: failing
            ? '${verdict.rule.why} Currently '
                  '${verdict.ratio.toStringAsFixed(2)}:1 against '
                  '${_roleNames[verdict.rule.against]!.toLowerCase()}, below '
                  'the ${verdict.rule.floor.toStringAsFixed(2)}:1 this role '
                  'is held to.'
            : expanded
            ? _purpose[role]
            : null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // A column rather than a shrink-wrap. `1.06:1` and `15.03:1` are
            // two characters apart, and thirteen wells that each start where
            // the number beside them happened to end is a form that looks
            // like it was assembled rather than drawn. `background` has no
            // rule of its own and holds the column open anyway.
            SizedBox(
              width: _ratioColumn,
              child: verdict == null
                  ? null
                  : Align(
                      alignment: Alignment.centerRight,
                      child: _Ratio(report: verdict),
                    ),
            ),
            const SizedBox(width: Space.smd),
            OaaColorWell(
              value: value,
              expanded: expanded,
              semanticLabel: _roleNames[role]!,
              onTap: () => setState(() => _open = expanded ? null : role),
            ),
          ],
        ),
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(bottom: Space.smd),
          child: Container(
            padding: const EdgeInsets.all(Space.smd),
            decoration: BoxDecoration(
              color: colors.panelRaised,
              borderRadius: OaaRadius.allSm,
              border: Border.all(
                color: colors.hairline,
                width: OaaStroke.hairline,
              ),
            ),
            child: OaaColorPicker(
              value: value,
              semanticLabel: _roleNames[role]!,
              onChanged: (next) =>
                  _update(draft.withColor(role, skinArgb(next))),
              onChangeEnd: (next) =>
                  _update(draft.withColor(role, skinArgb(next))),
            ),
          ),
        ),
    ];
  }

  Widget _footer(
    OaaColors colors,
    SkinLibraryController library,
    int failures,
  ) {
    final builtIn = library.isBuiltIn(_committed.id);
    final status =
        _status ??
        (_confirmClose
            ? 'Unsaved changes. Press × again to discard them.'
            : failures > 0
            ? '$failures ${failures == 1 ? 'role is' : 'roles are'} below '
                  'the contrast floor. Saving is still allowed.'
            : _dirty
            ? builtIn
                  ? 'Unsaved changes. This skin is fixed — save it as a new one.'
                  : 'Unsaved changes.'
            : null);

    return Row(
      children: [
        if (library.hasFile(_committed.id))
          Padding(
            padding: const EdgeInsets.only(right: Space.sm),
            child: OaaButton(
              label: _confirmDelete ? 'Delete?' : 'Delete',
              emphasis: ButtonEmphasis.destructive,
              onPressed: _delete,
            ),
          ),
        Expanded(
          child: status == null
              ? const SizedBox.shrink()
              : Text(
                  status,
                  style: OaaType.caption.copyWith(
                    color: failures > 0 && _status == null && !_confirmClose
                        ? colors.warn
                        : colors.textMuted,
                  ),
                ),
        ),
        const SizedBox(width: Space.sm),
        if (_dirty) ...[
          OaaButton(label: 'Revert', onPressed: _revert),
          const SizedBox(width: Space.sm),
        ],
        // On a built-in there is one way out and it is a copy, so the copy is
        // the affirmative button rather than the alternative to one.
        OaaButton(
          label: 'Save as new',
          emphasis: builtIn ? ButtonEmphasis.primary : ButtonEmphasis.normal,
          onPressed: () => _save(asNew: true),
        ),
        if (!builtIn) ...[
          const SizedBox(width: Space.sm),
          OaaButton(
            label: 'Save',
            emphasis: ButtonEmphasis.primary,
            onPressed: () => _save(asNew: false),
          ),
        ],
      ],
    );
  }

  static const double _nameWidth = Space.xxxl * 4;

  /// Wide enough for `15.03:1` with the warning mark in front of it — and
  /// then wide enough again for the *test binding's* font, whose advance is a
  /// full em where Google Sans Code's is 0.6. `flutter test` loads no fonts
  /// unless a test asks for them, so a column sized to the shipped face
  /// overflows by a pixel and a half in every widget test that renders this
  /// panel, and the exception reads as a defect in the panel.
  ///
  /// It costs nothing to be generous here: the label to its left is
  /// `Expanded` and the number inside it is right-aligned against the well, so
  /// the extra width is taken out of a gap and nothing moves.
  static const double _ratioColumn = Space.xxxl * 2;
}

/// The contrast ratio beside a role.
///
/// Drawn in `textMuted` whether it passes or not, with only the mark taking
/// `warn`. The number is the fact and the colour is the judgement; printing a
/// perfectly good 15:1 in a colour that means "look here" is how a panel
/// teaches somebody to stop reading it.
class _Ratio extends StatelessWidget {
  const _Ratio({required this.report});

  final SkinContrastReport report;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!report.passes) ...[
          OaaGlyph(OaaMark.warning, color: colors.warn, size: _mark),
          const SizedBox(width: Space.xs),
        ],
        Text(
          '${report.ratio.toStringAsFixed(2)}:1',
          style: OaaType.readingSmall.copyWith(color: colors.textMuted),
        ),
      ],
    );
  }

  static const double _mark = Space.smd;
}

/// The meter roles in the context they are read in.
///
/// Everything else about this editor previews itself — the panel is drawn in
/// the skin being edited, and the canvas behind it is too. The three that do
/// not are the ones that need a *meter* to be visible at all: a track behind a
/// fill, and the three verdict hues. Nobody has an alert meter open at the
/// moment they choose the colour that means over.
class _Preview extends StatelessWidget {
  const _Preview({required this.skin});

  final Skin skin;

  @override
  Widget build(BuildContext context) {
    Color of(SkinColor role) => Color(skin.resolve(role));

    // Inert chrome. A `BoxDecoration` says yes to every hit inside its shape
    // and a `RenderParagraph` does too — see the rule in `CLAUDE.md` — and
    // none of this is a control.
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(Space.smd),
        decoration: BoxDecoration(
          color: of(SkinColor.panel),
          borderRadius: OaaRadius.allSm,
          border: Border.all(
            color: of(SkinColor.hairline),
            width: OaaStroke.hairline,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '−14.2',
                  style: OaaType.reading(
                    _reading,
                  ).copyWith(color: of(SkinColor.textPrimary)),
                ),
                const SizedBox(width: Space.xs),
                Padding(
                  padding: const EdgeInsets.only(bottom: Space.xxs),
                  child: Text(
                    'LUFS',
                    style: OaaType.unit.copyWith(
                      color: of(SkinColor.textMuted),
                    ),
                  ),
                ),
                const SizedBox(width: Space.md),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: Space.xs),
                    child: CustomPaint(
                      size: const Size(double.infinity, _bar),
                      painter: _PreviewBarPainter(
                        track: of(SkinColor.meterTrack),
                        fill: of(SkinColor.meterFill),
                        target: of(SkinColor.hairlineStrong),
                        tick: of(SkinColor.textFaint),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: Space.sm),
            Row(
              children: [
                Text(
                  'INTEGRATED',
                  style: OaaType.label.copyWith(color: of(SkinColor.textFaint)),
                ),
                const Spacer(),
                _Chip(label: 'In spec', color: of(SkinColor.accent)),
                const SizedBox(width: Space.xs),
                _Chip(label: 'Near', color: of(SkinColor.warn)),
                const SizedBox(width: Space.xs),
                _Chip(label: 'Over', color: of(SkinColor.over)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const double _reading = Space.lg + Space.xs;
  static const double _bar = Space.smd;
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(
      horizontal: Space.sm,
      vertical: Space.xxs,
    ),
    decoration: BoxDecoration(
      borderRadius: OaaRadius.allXs,
      border: Border.all(color: color, width: OaaStroke.hairline),
    ),
    child: Text(
      label.toUpperCase(),
      style: OaaType.label.copyWith(color: color),
    ),
  );
}

/// A bar with a track behind it and a target on it — the arrangement that makes
/// `meterTrack` legible or not.
class _PreviewBarPainter extends CustomPainter {
  const _PreviewBarPainter({
    required this.track,
    required this.fill,
    required this.target,
    required this.tick,
  });

  final Color track;
  final Color fill;
  final Color target;
  final Color tick;

  static const double _fraction = 0.62;
  static const double _targetAt = 0.78;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas
      ..drawRect(rect, Paint()..color = track)
      ..drawRect(
        Rect.fromLTWH(0, 0, size.width * _fraction, size.height),
        Paint()..color = fill,
      );

    final x = size.width * _targetAt;
    canvas.drawLine(
      Offset(x, 0),
      Offset(x, size.height),
      Paint()
        ..color = target
        ..strokeWidth = OaaStroke.emphasis,
    );

    // A graticule under the bar, which is the other thing `textFaint` is for.
    final marks = Paint()
      ..color = tick
      ..strokeWidth = OaaStroke.hairline;
    for (var i = 1; i < 8; i++) {
      final gx = size.width * i / 8;
      canvas.drawLine(
        Offset(gx, size.height - OaaStroke.mark),
        Offset(gx, size.height),
        marks,
      );
    }
  }

  @override
  bool shouldRepaint(_PreviewBarPainter old) =>
      old.track != track ||
      old.fill != fill ||
      old.target != target ||
      old.tick != tick;
}

/// The roles, in the order somebody works through them: the surfaces first,
/// because everything else is judged against them.
typedef _Group = ({String title, String note, List<SkinColor> roles});

const List<_Group> _groups = [
  (
    title: 'Surfaces',
    note:
        'Depth here is background steps and hairlines, never shadows — so the '
        'steps have to be there to be seen.',
    roles: [
      SkinColor.background,
      SkinColor.panel,
      SkinColor.panelRaised,
      SkinColor.hairline,
      SkinColor.hairlineStrong,
    ],
  ),
  (
    title: 'Text',
    note: 'Measured against the panel behind them.',
    roles: [SkinColor.textPrimary, SkinColor.textMuted, SkinColor.textFaint],
  ),
  (
    title: 'Signal',
    note:
        'The three verdicts. On the measurement surface each of these means '
        'one thing and nothing else borrows it.',
    roles: [SkinColor.accent, SkinColor.warn, SkinColor.over],
  ),
  (
    title: 'Meters',
    note:
        'How much room is left is half of what a meter says, so the track has '
        'to be visible — and it has to stay below the fill, or it is a second '
        'bar.',
    roles: [SkinColor.meterTrack, SkinColor.meterFill],
  ),
];

const Map<SkinColor, String> _roleNames = {
  SkinColor.background: 'Background',
  SkinColor.panel: 'Panel',
  SkinColor.panelRaised: 'Panel raised',
  SkinColor.hairline: 'Hairline',
  SkinColor.hairlineStrong: 'Hairline strong',
  SkinColor.textPrimary: 'Text primary',
  SkinColor.textMuted: 'Text muted',
  SkinColor.textFaint: 'Text faint',
  SkinColor.accent: 'Accent',
  SkinColor.warn: 'Warn',
  SkinColor.over: 'Over',
  SkinColor.meterTrack: 'Meter track',
  SkinColor.meterFill: 'Meter fill',
};

/// One line per role, in the words of `packages/oaa_ui/lib/src/tokens.dart`,
/// which is where these are argued at length. Shown while a role's picker is
/// open — a colour is easier to choose when you know what it is for than when
/// you know what it is called.
const Map<SkinColor, String> _purpose = {
  SkinColor.background:
      'The canvas behind everything, and the row a menu already holds. Keep it '
      'the darkest of the three surfaces.',
  SkinColor.panel: 'A module or panel surface.',
  SkinColor.panelRaised:
      'A surface on top of a panel: menus, selected rows, a chosen segment.',
  SkinColor.hairline: 'The only border colour.',
  SkinColor.hairlineStrong:
      'A border that has to be seen: selection, hover, the active module.',
  SkinColor.textPrimary: 'Readings, and anything the eye should land on first.',
  SkinColor.textMuted:
      'Labels, units, and the em dash that means a quantity was not measured.',
  SkinColor.textFaint: 'Scale ticks and disabled state. Meant to recede.',
  SkinColor.accent:
      'In spec, and reserved for it — nothing on the canvas borrows this hue.',
  SkinColor.warn: 'Approaching a limit.',
  SkinColor.over: 'Over a limit.',
  SkinColor.meterTrack: 'The unfilled part of a bar or arc.',
  SkinColor.meterFill:
      'The filled part, where it carries no pass or fail meaning of its own.',
};
