// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_engine/oaa_engine.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/preset_file.dart';
import '../app/shortcuts.dart';
import '../clock/meter_clock.dart';
import '../data/providers.dart';
import '../plugin/plugin_link.dart';
import '../plugin/plugin_scope.dart';
import '../remote/publish_settings.dart';
import '../remote/remote_control.dart';
import '../remote/remote_display_service.dart';
import '../storage/config_store.dart';
import 'calibration_editor.dart';
import 'theme_editor.dart';

/// Opens the settings panel.
///
/// **Both scopes are resolved here, before the route is pushed.** A panel is
/// built by the `Navigator`, which sits above `MaterialApp.home`, so a
/// `RemoteDisplayScope` or a `PluginLinkScope` installed under `home` is
/// invisible from inside one — the same boundary that made every panel unable
/// to follow a skin change for eight phases. Reading them at the call site is
/// what `showOaaPanel` does with the palette, and it keeps this function's
/// signature the one three callers already use.
Future<void> showSettingsPanel(BuildContext context) => showOaaPanel<void>(
  context: context,
  builder: (_) => SettingsPanel(
    remote: RemoteDisplayScope.of(context),
    plugins: PluginLinkScope.of(context),
  ),
);

/// Everything Open Audio Analyzer remembers, in the order somebody sets it up.
///
/// Signal first, because a meter with nothing going into it is not measuring
/// anything; then the meters themselves; then where those meters go; then how
/// they look; then what is kept between launches. Every control here writes
/// through to disk immediately — there is no OK button, because a settings
/// panel with one is a settings panel that can be abandoned in a state the
/// interface already showed you. The one exception is the remote display's name
/// and port, which are committed together by an Apply button; `PublishSection`
/// says why.
class SettingsPanel extends ConsumerStatefulWidget {
  const SettingsPanel({required this.remote, required this.plugins, super.key});

  /// Publishing, for the section that configures it.
  ///
  /// Required rather than nullable: a null service would let a mis-wired build
  /// drop the whole Publish section with nothing anywhere saying it had, which
  /// is the class of silence this application is written against.
  final RemoteDisplayService remote;

  /// The plugin link, for the source it offers. Required for the same reason.
  final PluginLink plugins;

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
          PublishSection(service: widget.remote),
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
      note:
          'What Open Audio Analyzer is listening to. Changing it restarts the measurement.',
      ruled: false,
      children: [
        PanelRow(
          label: 'Source',
          child: SegmentedControl<AudioSourceKind>(
            value: settings.sourceKind,
            onChanged: controller.setSource,
            // **Worth measuring before a fifth is added.** A segmented control
            // that outgrows its row does not wrap: the `Expanded` label beside
            // it is what gives way, and `Source` is one word that cannot. These
            // four come to 328 px in a 572 px row — the panel is capped at 620
            // and the smallest window the application supports is 960, so that
            // row is the same width everywhere — against the 45 px the label
            // needs. `test/scaling_test.dart` holds the margin.
            segments: const [
              (value: AudioSourceKind.testTone, label: 'Test tone'),
              (value: AudioSourceKind.silence, label: 'Silence'),
              (value: AudioSourceKind.device, label: 'Device'),
              (value: AudioSourceKind.plugin, label: 'DAW plugin'),
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
        // **Live, because this is the one row whose contents are somebody
        // else's to change.** Every other control in this panel reports a
        // setting, and a setting only moves when this panel moves it. A DAW
        // plugin arrives and leaves on the DAW's schedule — very possibly
        // *because* this row said nothing was connected — and a list built when
        // the panel opened would still be saying so. `PluginLink` notifies on
        // membership and on nothing else; a session's measurements never come
        // through here, which is the rule that keeps meter data out of the
        // widget tree.
        ListenableBuilder(
          listenable: widget.plugins,
          builder: (context, _) {
            final sessions = widget.plugins.sessions;
            final active = widget.plugins.active;

            return PanelRow(
              label: 'DAW plugin',
              note: sessions.isEmpty
                  ? 'Nothing connected. Insert Open Audio Analyzer in your DAW '
                        'and it dials this machine on port $kPluginLinkPort by '
                        'itself, retrying until it answers — so it does not '
                        'matter which of the two you start first.'
                  : null,
              child: PanelMenu<int>(
                semanticLabel: 'DAW plugin',
                // The session that *would* be metered, whether or not it is the
                // chosen source — the same thing the capture-device menu above
                // shows while the test tone is playing.
                label: active == null
                    ? 'None connected'
                    : widget.plugins.labelFor(active),
                selected: settings.sourceKind == AudioSourceKind.plugin
                    ? active?.id
                    : null,
                options: [
                  for (final session in sessions)
                    (
                      value: session.id,
                      label: widget.plugins.labelFor(session),
                    ),
                ],
                onSelected: (id) {
                  // Two halves of one selection, in two places on purpose:
                  // *which* session is metered belongs to the link, because a
                  // session does not outlive its connection and there is
                  // nothing to persist; *that* a plugin is the source belongs
                  // to the settings, because it is what the next launch
                  // reopens.
                  final session = sessions.where((s) => s.id == id).firstOrNull;
                  if (session == null) return;
                  widget.plugins.active = session;
                  controller.setSource(AudioSourceKind.plugin);
                },
              ),
            );
          },
        ),
        // **Was written before the tap existed and then contradicted it.** The
        // note said "input devices only" and named BlackHole, sitting directly
        // under a picker that had been offering System Output since 0.8.0 — so
        // the one document a user reads at the moment of choosing told them the
        // feature was not there. Say what each platform actually does.
        const PanelNote(
          'System Output measures what this machine is playing, on macOS 14.2 '
          'and later, with no driver — macOS asks permission the first time and '
          'the meters read silence if it is declined. On Windows and Linux, '
          'pick a loopback device: VB-Cable, or a PulseAudio monitor.',
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
              const SizedBox(width: Space.sm),
              OaaButton(
                label: 'Reset',
                emphasis: ButtonEmphasis.destructive,
                onPressed: _resetCalibrations,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// Deletes every delivery target the user has written, once they have said so
  /// in as many words.
  ///
  /// **This one asks in a dialog rather than by taking a second press**, which
  /// is the exception to the rule in `lib/src/panels/AGENTS.md` and the reason
  /// [showOaaConfirm] exists. The in-place confirmation is right where the
  /// consequence fits on the button — one skin, one preset, the thing the row
  /// is about. Here one press removes every file in `calibrations/`, including
  /// corrections to the built-ins that somebody may have written by hand
  /// months ago, and none of that is visible from the row.
  Future<void> _resetCalibrations() async {
    final confirmed = await showOaaConfirm(
      context: context,
      title: 'Reset delivery targets',
      message:
          'This deletes every delivery target you have saved and puts the '
          'built-in seven back. Targets you wrote by hand, and corrections you '
          'made to a built-in, are removed from the configuration directory. '
          'It cannot be undone.',
      confirmLabel: 'Reset',
    );
    if (!confirmed || !mounted) return;

    final removed = await ref
        .read(calibrationLibraryProvider.notifier)
        .resetToBuiltIns();
    if (!mounted) return;

    setState(() {
      _status = switch (removed) {
        // The store already said why, and it said it about a specific file.
        null =>
          ref.read(storageNoticeProvider) ?? 'Could not remove every target.',
        0 => 'Nothing to reset — the built-in targets were the whole list.',
        1 => 'Delivery targets reset. One saved target removed.',
        _ => 'Delivery targets reset. $removed saved targets removed.',
      };
    });
  }

  // --- Appearance -----------------------------------------------------------

  Widget _appearance(AppSettings settings) {
    final skins = ref.watch(skinLibraryProvider);
    final active = ref.watch(skinProvider);

    return PanelSection(
      title: 'Appearance',
      note:
          'A skin is thirteen named colours. Edit one here and the canvas '
          'follows while you drag; it is also a JSON file you can write by '
          'hand, and one that sets as few as one colour inherits the rest.',
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
            OaaButton(label: 'New skin', onPressed: _newSkin),
            // No accent. `PanelActions` is not the footer, and the footer is
            // the only place a primary button is allowed — see
            // `packages/oaa_ui/AGENTS.md` § Panels. On the measurement surface
            // the signal hue means "in spec", and a section's action is not a
            // verdict.
            OaaButton(label: 'Edit skin', onPressed: () => _editSkin(active)),
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

  Future<void> _editSkin(Skin skin) =>
      showThemeEditor(context, ref, base: skin);

  /// Opens the editor on a copy of the active skin.
  ///
  /// **Nothing is written yet.** The copy exists only as the editor's draft
  /// until Save, so somebody who opens this to see what a skin editor looks
  /// like and closes it again has not left a file behind. What they get in the
  /// meantime is a complete document — a skin file may be sparse, but a
  /// *starting point* must not be: all thirteen roles at the values currently
  /// on screen, so that changing one is obviously safe.
  Future<void> _newSkin() async {
    final active = ref.read(skinProvider).resolved();
    final taken = {for (final skin in ref.read(skinLibraryProvider)) skin.id};

    var id = '${active.id}-copy';
    for (var suffix = 2; taken.contains(id) && suffix < 1000; suffix++) {
      id = '${active.id}-copy-$suffix';
    }

    await showThemeEditor(
      context,
      ref,
      base: Skin(
        id: id,
        name: '${active.name} copy',
        colors: active.colors,
        isLight: active.isLight,
      ),
    );
  }

  // --- Session --------------------------------------------------------------

  /// The chords for Open and Save, as printed for the keyboard in front of the
  /// user. Read off `oaaShortcuts`, never typed here.
  String get _openChord =>
      fileCommandChord(FileCommand.open)?.label(apple: useAppleKeyNames) ?? '';

  String get _saveChord =>
      fileCommandChord(FileCommand.save)?.label(apple: useAppleKeyNames) ?? '';

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
        // **No button, because presets are not a panel any more.** They are
        // documents: opened and saved through the platform's own file dialogs
        // from the File menu, which is in the macOS menu bar and is the FILE
        // button in the menu bar everywhere else. What is worth saying here is
        // where that is and what it is called, and the chords come off the one
        // table that owns them so this cannot drift from the sheet.
        PanelNote(
          'Presets are files. Open one, or save the arrangement you have, from '
          'the File menu — $_openChord and $_saveChord.',
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
          // It is the first place anybody goes looking for a preset to mail
          // somebody, and it is a different directory on each of six platforms —
          // one of which is an iPad container named after nothing a person would
          // type. Printing a path a user cannot select is the same as not
          // printing it.
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
