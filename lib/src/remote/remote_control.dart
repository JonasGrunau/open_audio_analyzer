// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../canvas/workspace.dart';
import '../data/providers.dart';
import 'display_screen.dart';
import 'mdns/mdns_service.dart';
import 'remote_display_service.dart';

/// The status-bar entry for the remote display, and the panel behind it.
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
    final colors = BelTheme.of(context);

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

    return ValueListenableBuilder<bool>(
      valueListenable: _service.isPublishing,
      builder: (context, publishing, _) => ValueListenableBuilder<int>(
        valueListenable: _service.clients,
        builder: (context, clients, _) => TextButton(
          onPressed: () => _open(context),
          child: Text(
            publishing
                ? (clients == 0 ? 'REMOTE · ON' : 'REMOTE · $clients')
                : 'REMOTE',
            style: BelType.label.copyWith(
              // Lit only when something is actually attached. "Listening" and
              // "being watched" are different facts and the second is the one
              // worth a colour.
              color: clients > 0
                  ? colors.accent
                  : (publishing ? colors.textPrimary : colors.textMuted),
            ),
          ),
        ),
      ),
    );
  }

  void _open(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => _RemotePanel(service: _service),
    );
  }
}

class _RemotePanel extends ConsumerStatefulWidget {
  const _RemotePanel({required this.service});

  final RemoteDisplayService service;

  @override
  ConsumerState<_RemotePanel> createState() => _RemotePanelState();
}

class _RemotePanelState extends ConsumerState<_RemotePanel> {
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

    return AlertDialog(
      backgroundColor: colors.panel,
      title: Text(
        'Remote display',
        style: BelType.body.copyWith(
          color: colors.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Publishes these meters to tablets on this network. Displays can '
              'only watch — they cannot reset, retarget or reconfigure this '
              'machine. There is no password on the connection, so leave it '
              'off on a network you do not trust.',
              style: BelType.label.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: Space.md),

            ValueListenableBuilder<bool>(
              valueListenable: service.isPublishing,
              builder: (context, publishing, _) => Row(
                children: [
                  Switch(
                    value: publishing,
                    onChanged: (value) async {
                      await service.setEnabled(value);
                      if (context.mounted) setState(() {});
                    },
                  ),
                  const SizedBox(width: Space.sm),
                  Text(
                    publishing ? 'Publishing' : 'Off',
                    style: BelType.body.copyWith(color: colors.textPrimary),
                  ),
                  const Spacer(),
                  ValueListenableBuilder<int>(
                    valueListenable: service.clients,
                    builder: (context, clients, _) => Text(
                      clients == 1 ? '1 display' : '$clients displays',
                      style: BelType.label.copyWith(color: colors.textMuted),
                    ),
                  ),
                ],
              ),
            ),

            ValueListenableBuilder<String?>(
              valueListenable: service.failure,
              builder: (context, failure, _) => failure == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: const EdgeInsets.only(top: Space.sm),
                      child: Text(
                        // Named out loud, because the common cause is a refused
                        // local-network permission, and the symptom without
                        // this line is a host nobody can find for no stated
                        // reason.
                        'Could not publish: $failure',
                        style: BelType.label.copyWith(color: colors.over),
                      ),
                    ),
            ),

            const SizedBox(height: Space.md),
            Row(
              children: [
                Expanded(
                  child: _Field(
                    label: 'Name',
                    controller: _name,
                    onSubmitted: _apply,
                  ),
                ),
                const SizedBox(width: Space.sm),
                SizedBox(
                  width: 96,
                  child: _Field(
                    label: 'Port',
                    controller: _port,
                    onSubmitted: _apply,
                  ),
                ),
                const SizedBox(width: Space.sm),
                TextButton(onPressed: _apply, child: const Text('APPLY')),
              ],
            ),

            const SizedBox(height: Space.md),
            Text(
              'Update rate',
              style: BelType.label.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: Space.xs),
            Row(
              children: [
                for (final fps in kRemoteFpsOptions)
                  Padding(
                    padding: const EdgeInsets.only(right: Space.xs),
                    child: TextButton(
                      onPressed: () {
                        ref
                            .read(settingsProvider.notifier)
                            .setRemoteDisplay(fps: fps);
                        setState(() {});
                      },
                      child: Text(
                        '$fps',
                        style: BelType.label.copyWith(
                          color: settings.remoteDisplayFps == fps
                              ? colors.accent
                              : colors.textMuted,
                        ),
                      ),
                    ),
                  ),
                const Spacer(),
                Text(
                  'measurements per second',
                  style: BelType.label.copyWith(color: colors.textMuted),
                ),
              ],
            ),

            if (_addresses.isNotEmpty) ...[
              const SizedBox(height: Space.md),
              Text(
                // Shown whether or not discovery is working. A tablet on a
                // network that blocks multicast needs somewhere to look, and
                // being told after it has already failed is too late.
                'If a tablet cannot find this machine, enter '
                '${_addresses.first}:${settings.remoteDisplayPort}',
                style: BelType.label.copyWith(color: colors.textMuted),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RemoteDisplayScreen(),
              ),
            );
          },
          child: const Text('USE AS DISPLAY'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('CLOSE'),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final VoidCallback onSubmitted;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return TextField(
      controller: controller,
      style: BelType.body.copyWith(color: colors.textPrimary),
      onSubmitted: (_) => onSubmitted(),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: BelType.label.copyWith(color: colors.textMuted),
        isDense: true,
        border: OutlineInputBorder(
          borderRadius: BelRadius.allMd,
          borderSide: BorderSide(color: colors.hairline),
        ),
      ),
    );
  }
}
