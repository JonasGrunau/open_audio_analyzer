// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';

/// Opens the delivery-target editor.
///
/// [base] is the target to start from — the active one, usually. Null starts
/// from the streaming default, which is the one most people are aiming at.
Future<void> showCalibrationEditor(BuildContext context, {Calibration? base}) =>
    showOaaPanel<void>(
      context: context,
      builder: (context) => CalibrationEditor(base: base),
    );

/// A form over the eight numbers that decide whether a master passes.
///
/// Every field is a number somebody publishes, so every field is editable and
/// nothing here is computed. The point of the panel is that a delivery spec
/// nobody anticipated — a label's house standard, a game platform's submission
/// requirement — is twenty seconds of typing rather than a feature request.
///
/// Two of the eight may be left empty. The dynamics floors are the limits no
/// platform publishes, so an empty field means "this target sets none" rather
/// than a mistake — see [Calibration.odrIntegratedFloor].
class CalibrationEditor extends ConsumerStatefulWidget {
  const CalibrationEditor({this.base, super.key});

  final Calibration? base;

  @override
  ConsumerState<CalibrationEditor> createState() => _CalibrationEditorState();
}

class _CalibrationEditorState extends ConsumerState<CalibrationEditor> {
  late final Calibration _base = widget.base ?? BuiltInCalibrations.fallback;

  late final _name = TextEditingController(text: _base.name);
  late final _note = TextEditingController(text: _base.note);
  late final _target = _field(_base.lufsTarget);
  late final _tolerance = _field(_base.lufsTolerance);
  late final _truePeak = _field(_base.truePeakMax);
  late final _range = _field(_base.loudnessRangeMax);
  late final _odrIntegratedFloor = _optionalField(_base.odrIntegratedFloor);
  late final _odrShortFloor = _optionalField(_base.odrShortFloor);
  late final _vu = _field(_base.vuReference);

  String? _error;

  TextEditingController _field(double value) =>
      TextEditingController(text: _format(value));

  TextEditingController _optionalField(double? value) =>
      TextEditingController(text: value == null ? '' : _format(value));

  @override
  void dispose() {
    for (final controller in [
      _name,
      _note,
      _target,
      _tolerance,
      _truePeak,
      _range,
      _odrIntegratedFloor,
      _odrShortFloor,
      _vu,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final library = ref.watch(calibrationLibraryProvider.notifier);
    final isBuiltIn = library.isBuiltIn(_base.id);

    return PanelScaffold(
      title: 'Delivery target',
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          if (!isBuiltIn && widget.base != null)
            OaaButton(
              label: 'Delete',
              emphasis: ButtonEmphasis.destructive,
              onPressed: _delete,
            ),
          const Spacer(),
          OaaButton(
            label: 'Save as new',
            onPressed: () => _save(keepId: false),
          ),
          const SizedBox(width: Space.sm),
          OaaButton(
            label: isBuiltIn ? 'Replace built-in' : 'Save',
            emphasis: ButtonEmphasis.primary,
            onPressed: () => _save(keepId: true),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null) ...[
            Padding(
              padding: const EdgeInsets.only(bottom: Space.smd),
              child: Text(
                _error!,
                style: OaaType.caption.copyWith(color: colors.over),
              ),
            ),
          ],
          PanelSection(
            title: 'Identity',
            ruled: false,
            children: [
              PanelRow(
                label: 'Name',
                child: OaaTextField(controller: _name, width: 260),
              ),
              // The note is prose, and it does not fit beside its own label.
              // In a 260 px field the built-in target's own note truncated at
              // "Spotify, Apple Music, YouTube, Ama" — mid-word, no ellipsis —
              // so the one field that explains where a target's numbers came
              // from was the one field you could not read. Every other control
              // here holds a number, which is why nothing else needs this.
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
                      'Where the numbers come from.',
                      style: OaaType.caption.copyWith(color: colors.textFaint),
                    ),
                    const SizedBox(height: Space.xs),
                    OaaTextField(controller: _note, width: double.infinity),
                  ],
                ),
              ),
            ],
          ),
          PanelSection(
            title: 'Loudness',
            note:
                'The integrated target and how far from it still counts as '
                'hitting it.',
            children: [
              PanelRow(label: 'Target', child: _number(_target, 'LUFS')),
              PanelRow(label: 'Tolerance', child: _number(_tolerance, 'LU')),
              PanelRow(
                label: 'Loudness range ceiling',
                note: 'Above this, the programme is flagged as too dynamic.',
                child: _number(_range, 'LU'),
              ),
            ],
          ),
          PanelSection(
            title: 'Peak',
            note:
                'A ceiling of −1 dBTP is the convention where a platform states '
                'none: lossy transcoding downstream routinely adds a few tenths '
                'of a dB, and a master at 0 dBTP will clip after it.',
            children: [
              PanelRow(
                label: 'True peak ceiling',
                child: _number(_truePeak, 'dBTP'),
              ),
            ],
          ),
          PanelSection(
            title: 'Dynamics',
            note:
                'True peak over loudness, which falls as a limiter is pushed. '
                'No platform publishes a floor, so an empty field sets none.',
            children: [
              PanelRow(
                label: 'ODR-I floor',
                note:
                    'The highest true peak over the integrated loudness. '
                    'Below this, the programme is flagged as too compressed.',
                child: _number(_odrIntegratedFloor, 'LU'),
              ),
              PanelRow(
                label: 'ODR-S floor',
                note:
                    'Checked against the most squeezed three seconds, which '
                    'one quiet intro cannot rescue.',
                child: _number(_odrShortFloor, 'LU'),
              ),
            ],
          ),
          PanelSection(
            title: 'Analogue',
            children: [
              PanelRow(
                label: 'VU reference',
                note:
                    'The level that reads as 0 VU. Only the VU meter uses it.',
                child: _number(_vu, 'dBFS'),
              ),
            ],
          ),
          if (isBuiltIn)
            Text(
              'This is a target Open Audio Analyzer ships with. "Replace built-in" writes a file '
              'that shadows it everywhere, including in presets that already '
              'name it; deleting that file brings the original back.',
              style: OaaType.caption.copyWith(color: colors.textFaint),
            ),
        ],
      ),
    );
  }

  Widget _number(TextEditingController controller, String unit) {
    final colors = OaaTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        OaaTextField(controller: controller, numeric: true, width: 84),
        const SizedBox(width: Space.sm),
        SizedBox(
          width: 40,
          child: Text(
            unit,
            style: OaaType.unit.copyWith(color: colors.textFaint),
          ),
        ),
      ],
    );
  }

  Future<void> _save({required bool keepId}) async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'A target needs a name.');
      return;
    }

    final values = <String, double?>{
      'target': _parse(_target.text, min: -60, max: 0),
      'tolerance': _parse(_tolerance.text, min: 0, max: 12),
      'true peak ceiling': _parse(_truePeak.text, min: -30, max: 0),
      'loudness range ceiling': _parse(_range.text, min: 0, max: 60),
      'VU reference': _parse(_vu.text, min: -40, max: 0),
    };

    for (final entry in values.entries) {
      if (entry.value == null) {
        setState(
          () => _error =
              'The ${entry.key} is not a number in the range this field '
              'accepts.',
        );
        return;
      }
    }

    // The two fields that may be empty. Empty is "no floor"; anything else
    // has to be a number, the same as the rest.
    final integratedFloor = _parseFloor(_odrIntegratedFloor, 'ODR-I floor');
    if (!integratedFloor.ok) return;
    final shortFloor = _parseFloor(_odrShortFloor, 'ODR-S floor');
    if (!shortFloor.ok) return;

    final id = keepId ? _base.id : _uniqueId(name);
    final calibration = Calibration(
      id: id,
      name: name,
      lufsTarget: values['target']!,
      lufsTolerance: values['tolerance']!,
      truePeakMax: values['true peak ceiling']!,
      loudnessRangeMax: values['loudness range ceiling']!,
      odrIntegratedFloor: integratedFloor.value,
      odrShortFloor: shortFloor.value,
      vuReference: values['VU reference']!,
      note: _note.text.trim(),
    );

    final saved = await ref
        .read(calibrationLibraryProvider.notifier)
        .save(calibration);

    if (!mounted) return;
    if (!saved) {
      setState(
        () => _error =
            ref.read(storageNoticeProvider) ?? 'The target could not be saved.',
      );
      return;
    }

    // Selecting it is the obvious next thing and saves a trip to the menu.
    ref.read(settingsProvider.notifier).setCalibrationId(id);
    Navigator.of(context).pop();
  }

  /// An optional floor: null for an empty field, the number otherwise, and
  /// `ok: false` with [_error] set when the text is neither.
  ({bool ok, double? value}) _parseFloor(
    TextEditingController field,
    String name,
  ) {
    final text = field.text.trim();
    if (text.isEmpty) return (ok: true, value: null);
    final value = _parse(text, min: 0, max: 40);
    if (value == null) {
      setState(
        () => _error =
            'The $name is not a number in the range this field accepts. '
            'Leave it empty for no floor.',
      );
      return (ok: false, value: null);
    }
    return (ok: true, value: value);
  }

  Future<void> _delete() async {
    final removed = await ref
        .read(calibrationLibraryProvider.notifier)
        .remove(_base.id);

    if (!mounted) return;
    if (!removed) {
      setState(
        () => _error =
            ref.read(storageNoticeProvider) ??
            'The target could not be deleted.',
      );
      return;
    }
    Navigator.of(context).pop();
  }

  String _uniqueId(String name) {
    final library = ref.read(calibrationLibraryProvider);
    final taken = {for (final calibration in library) calibration.id};
    // The same slug rule the filename uses, so that a target's id and its file
    // do not need a mapping table to find each other.
    final base = slugify(name);

    if (!taken.contains(base)) return base;
    for (var suffix = 2; suffix < 1000; suffix++) {
      if (!taken.contains('$base-$suffix')) return '$base-$suffix';
    }
    return '$base-${taken.length}';
  }
}

String _format(double value) {
  // Trailing ".0" on a whole number is noise in a field somebody is about to
  // type over.
  final rounded = double.parse(value.toStringAsFixed(2));
  return rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toString();
}

/// Parses a typed number, or null if it is not one or is outside [min]–[max].
///
/// Accepts the typographic minus and the comma decimal separator. Both arrive
/// constantly: the interface itself renders "−14 LUFS" with U+2212, so anybody
/// who copies a target out of Open Audio Analyzer and pastes it back in is
/// pasting a character
/// `double.parse` rejects, and half of Europe types "−0,5".
double? _parse(String text, {required double min, required double max}) {
  final normalised = text
      .trim()
      .replaceAll('−', '-')
      .replaceAll('–', '-')
      .replaceAll(',', '.');

  final value = double.tryParse(normalised);
  if (value == null || !value.isFinite) return null;
  if (value < min || value > max) return null;
  return value;
}
