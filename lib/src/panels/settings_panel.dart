// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../clock/meter_clock.dart';
import '../data/providers.dart';
import '../storage/config_store.dart';
import 'calibration_editor.dart';
import 'preset_browser.dart';

/// Opens the settings panel.
Future<void> showSettingsPanel(BuildContext context) => showOaaPanel<void>(
  context: context,
  builder: (context) => const SettingsPanel(),
);

/// Everything Open Audio Analyzer remembers, in the order somebody sets it up.
///
/// Signal first, because a meter with nothing going into it is not measuring
/// anything; then the meters themselves; then how they look; then what is kept
/// between launches. Every control here writes through to disk immediately —
/// there is no OK button, because a settings panel with one is a settings panel
/// that can be abandoned in a state the interface already showed you.
class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({super.key});

  @override
  ConsumerState<SettingsPanel> createState() => _SettingsPanelState();
}

class _SettingsPanelState extends ConsumerState<SettingsPanel> {
  /// Enumerated once when the panel opens rather than per build.
  ///
  /// Devices come and go in a studio, so a list cached at launch would be
  /// wrong — but a list rebuilt on every setState would also re-enumerate the
  /// audio subsystem every time a toggle moved, which on Windows is not free.
  late List<OaaDevice> _devices = _enumerate();

  String? _status;

  List<OaaDevice> _enumerate() {
    try {
      return OaaEngine.devices();
    } on OaaEngineException {
      // No audio subsystem is a legitimate state — a headless CI box, a
      // machine whose audio service has died. The rest of the panel still
      // works.
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final settings = ref.watch(settingsProvider);
    final store = ref.watch(configStoreProvider);

    return PanelScaffold(
      title: 'Settings',
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          Expanded(
            child: Text(
              _status ?? '',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: OaaType.caption.copyWith(color: colors.textFaint),
            ),
          ),
          OaaButton(
            label: 'Done',
            emphasis: ButtonEmphasis.primary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _signal(settings),
          _meters(settings),
          _appearance(settings),
          _session(settings, store),
        ],
      ),
    );
  }

  // --- Signal ---------------------------------------------------------------

  Widget _signal(AppSettings settings) {
    final controller = ref.read(settingsProvider.notifier);

    final selectedDevice = _devices
        .where((device) => device.id == settings.deviceId)
        .firstOrNull;

    return PanelSection(
      title: 'Signal',
      note: 'What Open Audio Analyzer is listening to. Changing it restarts the measurement.',
      ruled: false,
      children: [
        PanelRow(
          label: 'Source',
          child: SegmentedControl<AudioSourceKind>(
            value: settings.sourceKind,
            onChanged: controller.setSource,
            segments: const [
              (value: AudioSourceKind.testTone, label: 'Test tone'),
              (value: AudioSourceKind.silence, label: 'Silence'),
              (value: AudioSourceKind.device, label: 'Device'),
            ],
          ),
        ),
        PanelRow(
          label: 'Capture device',
          note: settings.deviceName != null && selectedDevice == null
              ? 'Last used: ${settings.deviceName}. Not connected right now.'
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OaaButton(
                label: 'Rescan',
                onPressed: () => setState(() => _devices = _enumerate()),
              ),
              const SizedBox(width: Space.sm),
              PanelMenu<String>(
                semanticLabel: 'Capture device',
                label:
                    selectedDevice?.name ??
                    (_devices.isEmpty ? 'None found' : 'Choose…'),
                selected: settings.deviceId,
                options: [
                  for (final device in _devices)
                    (
                      value: device.id,
                      label: device.isDefault
                          ? '${device.name}  (default)'
                          : device.name,
                    ),
                ],
                onSelected: (id) {
                  final device = _devices.firstWhere((d) => d.id == id);
                  controller.setSource(
                    AudioSourceKind.device,
                    deviceId: device.id,
                    deviceName: device.name,
                  );
                },
              ),
            ],
          ),
        ),
        const PanelNote(
          'Input devices only. To measure what this machine is playing, '
          'select a loopback device — BlackHole on macOS, VB-Cable on '
          'Windows, a PulseAudio monitor on Linux. Open Audio Analyzer ships no system-audio '
          'driver of its own; the README says why.',
        ),
      ],
    );
  }

  // --- Meters ---------------------------------------------------------------

  Widget _meters(AppSettings settings) {
    final calibration = ref.watch(calibrationProvider);
    final library = ref.watch(calibrationLibraryProvider);
    final controller = ref.read(settingsProvider.notifier);

    return PanelSection(
      title: 'Meters',
      children: [
        PanelRow(
          label: 'Refresh rate',
          // When the system asks for reduced motion the clock caps itself at
          // 30, so a picker still reading "60 fps" would be showing a rate
          // nothing is running at. Say which it is instead.
          note: MediaQuery.maybeDisableAnimationsOf(context) ?? false
              ? 'Capped at ${MeterClock.reducedMotionFps} fps while the system '
                    'asks for reduced motion. The meters still show every '
                    'reading; they redraw less often.'
              : '30 halves GPU load for a session left open all day.',
          child: SegmentedControl<int>(
            value: settings.targetFps,
            onChanged: controller.setTargetFps,
            segments: [
              for (final fps in kTargetFpsOptions)
                (value: fps, label: '$fps fps'),
            ],
          ),
        ),
        PanelRow(
          label: 'Delivery target',
          note: calibration.note.isEmpty ? null : calibration.note,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PanelMenu<String>(
                semanticLabel: 'Delivery target',
                label: calibration.name,
                selected: calibration.id,
                options: [
                  for (final option in library)
                    (value: option.id, label: option.name),
                ],
                onSelected: controller.setCalibrationId,
              ),
              const SizedBox(width: Space.sm),
              OaaButton(
                label: 'Edit',
                onPressed: () =>
                    showCalibrationEditor(context, base: calibration),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // --- Appearance -----------------------------------------------------------

  Widget _appearance(AppSettings settings) {
    final skins = ref.watch(skinLibraryProvider);
    final active = ref.watch(skinProvider);

    return PanelSection(
      title: 'Appearance',
      note:
          'Skins are JSON files with thirteen named colours. A skin may set as '
          'few as one of them and inherit the rest.',
      children: [
        for (final skin in skins)
          PanelListRow(
            title: skin.name,
            note: skin.note.isEmpty ? null : skin.note,
            selected: skin.id == active.id,
            onTap: () => ref.read(settingsProvider.notifier).setSkinId(skin.id),
            trailing: _Swatches(skin: skin),
          ),
        PanelActions(
          children: [
            OaaButton(label: 'Reload from disk', onPressed: _reloadSkins),
            OaaButton(
              label: 'Duplicate for editing',
              onPressed: _duplicateSkin,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _reloadSkins() async {
    await ref.read(skinLibraryProvider.notifier).reload();
    if (!mounted) return;
    setState(() => _status = 'Skins reloaded.');
  }

  /// Writes the active skin out as a complete, editable document.
  ///
  /// A skin file may be sparse, but a *starting point* must not be: somebody
  /// opening their first skin wants to see all thirteen roles with the values
  /// they are currently looking at, so that changing one is obviously safe.
  Future<void> _duplicateSkin() async {
    final active = ref.read(skinProvider).resolved();
    final taken = {for (final skin in ref.read(skinLibraryProvider)) skin.id};

    var id = '${active.id}-copy';
    for (var suffix = 2; taken.contains(id) && suffix < 1000; suffix++) {
      id = '${active.id}-copy-$suffix';
    }

    final copy = Skin(
      id: id,
      name: '${active.name} copy',
      colors: active.colors,
      isLight: active.isLight,
      note: 'Edit this file and press Reload from disk.',
    );

    final saved = await ref.read(skinLibraryProvider.notifier).save(copy);
    if (!mounted) return;

    setState(() {
      _status = saved
          ? 'Wrote $id.json to the skins folder.'
          : ref.read(storageNoticeProvider) ?? 'Could not write the skin.';
    });
    if (saved) ref.read(settingsProvider.notifier).setSkinId(id);
  }

  // --- Session --------------------------------------------------------------

  Widget _session(AppSettings settings, ConfigStore store) {
    final colors = OaaTheme.of(context);

    return PanelSection(
      title: 'Session',
      children: [
        PanelRow(
          label: 'Restore the last layout at launch',
          note:
              'Off means Open Audio Analyzer opens on its default arrangement every time, '
              'whatever you left on the canvas.',
          child: OaaToggle(
            semanticLabel: 'Restore the last layout at launch',
            value: settings.restoreSession,
            onChanged: ref.read(settingsProvider.notifier).setRestoreSession,
          ),
        ),
        PanelRow(
          label: 'Presets',
          note: 'Save the current arrangement, or open one you saved before.',
          child: OaaButton(
            label: 'Browse',
            onPressed: () => showPresetBrowser(context),
          ),
        ),
        if (!store.isAvailable)
          PanelNote(
            'Nothing is being saved this session. ${store.lastError ?? ''}',
            tone: colors.warn,
          )
        else ...[
          const PanelNote(
            'Settings, presets, skins and delivery targets are kept here as '
            'plain JSON — edit them, copy them between machines, or keep them '
            'in version control.',
          ),
          // **Selectable, and monospaced, because the path is not guessable.**
          // On macOS the app is sandboxed, so this is a container directory
          // named after the bundle identifier rather than the
          // ~/Library/Application Support/Open Audio Analyzer anybody would
          // think to look in. Printing an unselectable path a user cannot
          // navigate to is the same as not printing it.
          Padding(
            padding: const EdgeInsets.only(top: Space.xs),
            child: SelectableText(
              store.root!.path,
              style: OaaType.readingSmall.copyWith(color: colors.textMuted),
            ),
          ),
        ],
      ],
    );
  }
}

/// The colours a skin row shows, so the list is scannable without applying each
/// one in turn.
class _Swatches extends StatelessWidget {
  const _Swatches({required this.skin});

  final Skin skin;

  static const List<SkinColor> _shown = [
    SkinColor.background,
    SkinColor.panel,
    SkinColor.textPrimary,
    SkinColor.accent,
    SkinColor.over,
  ];

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final role in _shown)
          Container(
            width: Space.smd,
            height: Space.md,
            margin: const EdgeInsets.only(left: Space.xxs),
            decoration: BoxDecoration(
              color: Color(skin.resolve(role)),
              borderRadius: OaaRadius.allXs,
              border: Border.all(
                color: colors.hairline,
                width: OaaStroke.hairline,
              ),
            ),
          ),
      ],
    );
  }
}
