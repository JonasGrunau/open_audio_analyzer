// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/bar_controls.dart';
import '../canvas/workspace.dart';
import '../data/providers.dart';
import 'display_screen.dart';
import 'host_picker.dart';
import 'mdns/mdns_service.dart';
import 'remote_display_service.dart';

/// The status-bar entry for the remote display, and the panels behind it.
///
/// This is the whole of Phase 6's footprint in the desktop app: one widget in
/// one row. It owns the [RemoteDisplayService] rather than putting it in a
/// provider, because the service is not configuration — it holds a socket, an
/// mDNS responder and a publish timer, all of which have to be torn down with
/// the element that created them, and none of which any other widget reads.
class RemoteDisplayControl extends ConsumerStatefulWidget {
  const RemoteDisplayControl({
    required this.source,
    required this.abiVersion,
    super.key,
  });

  final MeterSource source;
  final int abiVersion;

  @override
  ConsumerState<RemoteDisplayControl> createState() =>
      _RemoteDisplayControlState();
}

class _RemoteDisplayControlState extends ConsumerState<RemoteDisplayControl> {
  late final RemoteDisplayService _service = RemoteDisplayService(
    source: widget.source,
    abiVersion: widget.abiVersion,
  );

  @override
  void dispose() {
    _service.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The service holds no configuration of its own: name, port and rate live
    // in the settings, are persisted with everything else, and arrive here.
    // Whether to *publish* is deliberately not among them — see the panel.
    final settings = ref.watch(settingsProvider);
    _service.configure(
      name: settings.remoteDisplayName,
      port: settings.remoteDisplayPort,
      fps: settings.remoteDisplayFps,
    );

    // Compare-and-send: each of these is checked against what was last put on
    // the wire, so a rebuild that changed nothing sends nothing. Calling it
    // here rather than from a listener keeps the "what displays see" answer in
    // one place, and it cannot cause a rebuild of its own.
    _service.publish(
      layout: ref.watch(workspaceProvider).preset,
      skin: ref.watch(skinProvider),
      calibration: ref.watch(calibrationProvider),
    );

    // A `BarButton` like the four beside it, not a `TextButton`. A stock
    // Material button in this row has no border where its neighbours have one,
    // Material's own minimum size rather than the bar's, an ink ripple nothing
    // else in Bel draws, and no keyboard focus ring — five differences that
    // read as one: the button that does not belong here.
    return ValueListenableBuilder<bool>(
      valueListenable: _service.isPublishing,
      builder: (context, publishing, _) => ValueListenableBuilder<int>(
        valueListenable: _service.clients,
        builder: (context, clients, _) => BarButton(
          // "Listening" and "being watched" are different facts, and both have
          // to be legible from the bar: publishing on an unauthenticated socket
          // is something the user has to be able to see without opening
          // anything. Brightness carries the first and the count carries the
          // second — see `BarButton.lit` for why neither is a hue.
          label: publishing
              ? (clients == 0 ? 'REMOTE · ON' : 'REMOTE · $clients')
              : 'REMOTE',
          lit: publishing,
          tooltip: switch ((publishing, clients)) {
            (false, _) =>
              'Send these meters to another screen, or show another '
                  'machine’s here.',
            (true, 0) => 'Publishing to this network. No displays attached.',
            (true, 1) => 'Publishing to this network. 1 display attached.',
            (true, final n) =>
              'Publishing to this network. $n displays attached.',
          },
          onPressed: () => _open(context),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    // `showBelPanel`, not `showDialog`. A route is built by the `Navigator`,
    // which sits above `MaterialApp.home` and therefore above the application's
    // `BelTheme` — so a panel that reads the palette the obvious way throws
    // "No BelTheme in scope" the moment it opens, in release as well as debug.
    // This one did, for the whole of Phase 6: the button was unclickable and
    // nothing said so until somebody pressed it.
    showBelPanel<void>(
      context: context,
      builder: (context) => _PairingPanel(service: _service),
    );
  }
}

/// Which end of the link this machine is.
///
/// **The question is asked before either answer is configured, because the two
/// answers have nothing in common.** Sending is a socket, a name and a rate on
/// *this* machine; receiving is a search for somebody else's. They were one
/// dialog with the receiving half behind a footer button marked "Use as
/// display" — which put a whole second mode in the row where a panel says "the
/// ways out of here are", so the tablet half of the feature was reachable only
/// by pressing the button that looked most like Cancel.
///
/// The second panel is *pushed* rather than this one swapping its own body.
/// `showBelPanel` is a `showGeneralDialog` route with a zero-length transition,
/// so pushing costs nothing on screen, Escape and the system back gesture
/// return here for free, and each panel stays a plain widget with its own
/// title. A panel that mutated its own body would have to hand-roll the back
/// stack the Navigator is already keeping.
class _PairingPanel extends StatelessWidget {
  const _PairingPanel({required this.service});

  final RemoteDisplayService service;

  @override
  Widget build(BuildContext context) {
    return PanelScaffold(
      title: 'Remote',
      onClose: () => Navigator.of(context).pop(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelSection(
            title: 'Send or receive',
            ruled: false,
            note:
                'Bel can send these meters to another screen, or become a '
                'screen for a Bel running somewhere else.',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: service.isPublishing,
                builder: (context, publishing, _) =>
                    ValueListenableBuilder<int>(
                      valueListenable: service.clients,
                      builder: (context, clients, _) => PanelListRow(
                        title: 'Send these meters',
                        // The two rows are the same shape and say opposite
                        // things, so the mark is the first thing that tells
                        // them apart — and it is brightness rather than hue,
                        // like the bar button, because the signal colour means
                        // "in spec" and nothing else.
                        mark: BelMark.broadcast,
                        opens: true,
                        // The row carries the live state, so "am I already
                        // publishing" is answered on the first screen rather
                        // than one panel deeper.
                        note: switch ((publishing, clients)) {
                          (false, _) =>
                            'Publish this machine’s measurements to tablets '
                                'and laptops on this network.',
                          (true, 0) => 'Publishing. No displays attached.',
                          (true, 1) => 'Publishing. 1 display attached.',
                          (true, final n) =>
                            'Publishing. $n displays attached.',
                        },
                        selected: publishing,
                        onTap: () => showBelPanel<void>(
                          context: context,
                          builder: (context) => _SendPanel(service: service),
                        ),
                      ),
                    ),
              ),
              // The two rows are opposite directions rather than two entries in
              // a list, and at the list's own [Space.xs] they read as one
              // block of text to choose a line from. A gap the width of the
              // mark column separates the choices without opening a section.
              const SizedBox(height: Space.sm),
              PanelListRow(
                title: 'Show another machine',
                mark: BelMark.display,
                opens: true,
                note:
                    'Turn this screen into a display for a Bel running '
                    'elsewhere. It shows only — it cannot change what that '
                    'machine is measuring.',
                onTap: () => _receive(context),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Picks a host, then leaves the panels behind for the display itself.
  ///
  /// Both panels come off the stack before the screen goes on. A display is
  /// where a tablet stays, and a modal left open underneath it would put the
  /// canvas back the first time somebody pressed Escape at the meters.
  Future<void> _receive(BuildContext context) async {
    final navigator = Navigator.of(context);

    await showBelPanel<void>(
      context: context,
      builder: (context) => HostPickerPanel(
        onClose: () => Navigator.of(context).pop(),
        onConnect: (host, port) {
          navigator
            ..pop()
            ..pop();
          navigator.push(
            MaterialPageRoute<void>(
              builder: (_) => RemoteDisplayScreen(host: host, port: port),
            ),
          );
        },
      ),
    );
  }
}

/// The sending half: the socket, what it is called, and how often it speaks.
class _SendPanel extends ConsumerStatefulWidget {
  const _SendPanel({required this.service});

  final RemoteDisplayService service;

  @override
  ConsumerState<_SendPanel> createState() => _SendPanelState();
}

class _SendPanelState extends ConsumerState<_SendPanel> {
  late final TextEditingController _port = TextEditingController(
    text: '${widget.service.port}',
  );
  late final TextEditingController _name = TextEditingController(
    text: widget.service.hostName,
  );

  List<String> _addresses = const [];

  @override
  void initState() {
    super.initState();
    localIPv4Addresses().then((addresses) {
      if (mounted) setState(() => _addresses = addresses);
    });
  }

  @override
  void dispose() {
    _port.dispose();
    _name.dispose();
    super.dispose();
  }

  /// Writes the fields to the settings, which is what reaches the service.
  ///
  /// Nothing here validates: `setRemoteDisplay` ignores a value it cannot use
  /// rather than storing it, so a mistyped port leaves the previous one in
  /// place instead of quietly binding somewhere nobody is looking.
  void _apply() {
    ref
        .read(settingsProvider.notifier)
        .setRemoteDisplay(
          name: _name.text,
          port: int.tryParse(_port.text.trim()),
        );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final service = widget.service;

    // Read from the settings rather than from the service: the settings are
    // what a tap writes, and the service adopts them a rebuild later. Showing
    // the service's copy would leave the selected rate looking unchanged for a
    // frame after somebody chose it.
    final settings = ref.watch(settingsProvider);

    return PanelScaffold(
      title: 'Send these meters',
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          const Spacer(),
          BelButton(
            label: 'Done',
            emphasis: ButtonEmphasis.primary,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelSection(
            title: 'Publishing',
            ruled: false,
            note:
                'Sends these meters to displays on this network. A display can '
                'only watch — it cannot reset, retarget or reconfigure this '
                'machine.',
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: service.isPublishing,
                builder: (context, publishing, _) =>
                    ValueListenableBuilder<int>(
                      valueListenable: service.clients,
                      builder: (context, clients, _) => PanelRow(
                        label: 'Publish to this network',
                        note: switch ((publishing, clients)) {
                          (false, _) => 'Off.',
                          (true, 0) => 'Publishing. No displays attached.',
                          (true, 1) => 'Publishing. 1 display attached.',
                          (true, final n) =>
                            'Publishing. $n displays attached.',
                        },
                        child: BelToggle(
                          value: publishing,
                          semanticLabel: 'Publish to this network',
                          onChanged: (value) async {
                            await service.setEnabled(value);
                            if (context.mounted) setState(() {});
                          },
                        ),
                      ),
                    ),
              ),
              PanelRow(
                label: 'Update rate',
                note: 'Measurements per second sent to each display.',
                child: SegmentedControl<int>(
                  value: settings.remoteDisplayFps,
                  segments: [
                    for (final fps in kRemoteFpsOptions)
                      (value: fps, label: '$fps'),
                  ],
                  onChanged: (fps) {
                    ref
                        .read(settingsProvider.notifier)
                        .setRemoteDisplay(fps: fps);
                    setState(() {});
                  },
                ),
              ),
              PanelNote(
                'There is no password on the connection. Anyone on this '
                'network who can find it can watch these meters, so leave it '
                'off on a network you do not trust.',
                tone: colors.warn,
                mark: BelMark.warning,
              ),
              ValueListenableBuilder<String?>(
                valueListenable: service.failure,
                builder: (context, failure, _) => failure == null
                    ? const SizedBox.shrink()
                    // Named out loud, because the common cause is a refused
                    // local-network permission, and the symptom without this
                    // line is a host nobody can find for no stated reason.
                    : PanelNote(
                        'Could not publish: $failure',
                        tone: colors.over,
                        mark: BelMark.warning,
                      ),
              ),
            ],
          ),

          PanelSection(
            title: 'Where to find this machine',
            note:
                'The name displays list this machine under, and the port it '
                'listens on.',
            children: [
              // One line, because this is one edit. The name and the port are
              // the same fact — where a display should look — and Apply commits
              // both at once, so three stacked rows made a two-field form look
              // like three separate settings and put the button that finishes
              // it a row away from either field. There is room: the panel is
              // 620 px wide and the three controls take under 400 of it.
              //
              // Unlike the settings panel, the fields do not write through as
              // they are typed: a port is not a valid port until it is
              // finished, and binding to each prefix of one as it is entered
              // would move the socket three times on the way to 5560.
              PanelRow(
                label: 'Name and port',
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    BelTextField(
                      controller: _name,
                      width: 200,
                      onSubmitted: (_) => _apply(),
                    ),
                    const SizedBox(width: Space.sm),
                    BelTextField(
                      controller: _port,
                      width: 88,
                      numeric: true,
                      onSubmitted: (_) => _apply(),
                    ),
                    const SizedBox(width: Space.sm),
                    BelButton(label: 'Apply', onPressed: _apply),
                  ],
                ),
              ),
              // Shown whether or not discovery is working. A tablet on a
              // network that blocks multicast needs somewhere to look, and
              // being told after it has already failed is too late.
              if (_addresses.isNotEmpty)
                PanelNote(
                  'If a display cannot find this machine, type '
                  '${_addresses.first}:${settings.remoteDisplayPort} into it.',
                ),
            ],
          ),
        ],
      ),
    );
  }
}
