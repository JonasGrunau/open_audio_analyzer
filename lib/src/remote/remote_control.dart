// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/bar_controls.dart';
import '../canvas/workspace.dart';
import '../data/providers.dart';
import 'display_screen.dart';
import 'host_picker.dart';
import 'mdns/mdns_service.dart';
import 'publish_settings.dart';
import 'remote_display_service.dart';

/// The application's one connection to [RemoteDisplayService]: what drives it,
/// and what can reach it.
///
/// **It is built unconditionally, and that is the whole point of it.** The two
/// things below were done inside the status-bar control, which the bar *drops*
/// below a width gate because it drops whole items rather than squeezing them.
/// The service itself was moved out to the engine's owner when that first bit —
/// narrowing the window used to tear down an active session — but the code that
/// feeds the service did not follow, so the second half of the same defect
/// survived: past the gate the socket went on streaming measurements while
/// layout, skin and delivery-target changes stopped arriving at the tablet, and
/// a changed name, port or rate stopped being adopted. Nothing anywhere said
/// so, and the tablet looked healthy the entire time. Anything that has to keep
/// happening while publishing is on belongs here, above the bar, and not in a
/// control the bar is allowed to drop.
///
/// It also carries the service down the tree, because the settings panel needs
/// it and a panel is a route. See [of].
class RemoteDisplayScope extends ConsumerWidget {
  const RemoteDisplayScope({
    required this.service,
    required this.child,
    super.key,
  });

  final RemoteDisplayService service;
  final Widget child;

  /// The service in scope, for a widget below one.
  ///
  /// **Read it at the call site, not inside a panel.** A route is built by the
  /// `Navigator`, which sits above `MaterialApp.home` — so an inherited widget
  /// installed under `home` is invisible to every panel, and looking for one
  /// from inside a route finds nothing. `showSettingsPanel` resolves this
  /// before it pushes and hands the result to the panel, the same shape
  /// `showOaaPanel` uses to carry the palette across that boundary.
  static RemoteDisplayService of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<_RemoteDisplayScope>();
    assert(scope != null, 'No RemoteDisplayScope in scope.');
    return scope!.service;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // The service holds no configuration of its own: name, port and rate live
    // in the settings, are persisted with everything else, and arrive here.
    // Whether to *publish* is deliberately not among them — there is no
    // "publish at launch", because opening a port with no password on it is
    // worth asking for every time.
    final settings = ref.watch(settingsProvider);
    service.configure(
      name: settings.remoteDisplayName,
      port: settings.remoteDisplayPort,
      fps: settings.remoteDisplayFps,
    );

    // Compare-and-send: each of these is checked against what was last put on
    // the wire, so a rebuild that changed nothing sends nothing. Calling it
    // here rather than from a listener keeps the "what displays see" answer in
    // one place, and it cannot cause a rebuild of its own.
    service.publish(
      layout: ref.watch(workspaceProvider).preset,
      skin: ref.watch(skinProvider),
      calibration: ref.watch(calibrationProvider),
    );

    return _RemoteDisplayScope(service: service, child: child);
  }
}

class _RemoteDisplayScope extends InheritedWidget {
  const _RemoteDisplayScope({required this.service, required super.child});

  final RemoteDisplayService service;

  @override
  bool updateShouldNotify(_RemoteDisplayScope old) =>
      !identical(service, old.service);
}

/// The status bar's publish switch.
///
/// **A view onto the service, and nothing more.** It owns no socket, adopts no
/// settings and starts nothing when it is built — see [RemoteDisplayScope] for
/// why none of that may live in a control the bar can drop.
///
/// The client count is in the tooltip rather than in the label. The bar has no
/// room for a number that is usually zero, and the fact it answers — "is
/// somebody watching" — is one step less urgent than the one the switch itself
/// carries, which is that an unauthenticated port is open at all. That one is
/// legible at a glance: `BarSwitch` lights when it is on. The count is written
/// out in full in Settings → Publish, whose heading note carries it.
class PublishSwitch extends StatelessWidget {
  const PublishSwitch({required this.service, super.key});

  final RemoteDisplayService service;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: service.isPublishing,
      builder: (context, publishing, _) => ValueListenableBuilder<int>(
        valueListenable: service.clients,
        builder: (context, clients, _) => BarSwitch(
          label: 'PUBLISH',
          value: publishing,
          semanticLabel: 'Publish these meters to this network',
          tooltip: switch ((publishing, clients)) {
            (false, _) =>
              'Send these meters to displays on this network. There is no '
                  'password on the connection.',
            (true, 0) => 'Publishing to this network. No displays attached.',
            (true, 1) => 'Publishing to this network. 1 display attached.',
            (true, final n) =>
              'Publishing to this network. $n displays attached.',
          },
          // `setEnabled` reports its own failures through `service.failure`,
          // which Settings → Publish draws. Nothing is thrown at the bar.
          onChanged: (value) => service.setEnabled(value),
        ),
      ),
    );
  }
}

/// The pairing code, one press from the switch that makes it mean anything.
///
/// **Disabled rather than absent while publishing is off.** The code is an
/// address, and an address nothing is listening at is a tablet that scans,
/// connects and times out — which reads as a broken feature rather than as a
/// switch that is not on. Greyed beside the switch it is gated on, it says
/// "turn that on first" without a sentence; removed, it would say nothing at
/// all, and somebody would go looking in the settings for a code they had seen
/// there yesterday.
///
/// It is also disabled with no addresses to name. A laptop with every interface
/// down can publish — the socket binds on loopback — and has nothing to put in
/// a square.
class PairingCodeButton extends StatefulWidget {
  const PairingCodeButton({required this.service, super.key});

  final RemoteDisplayService service;

  @override
  State<PairingCodeButton> createState() => _PairingCodeButtonState();
}

class _PairingCodeButtonState extends State<PairingCodeButton> {
  List<String> _addresses = const [];

  @override
  void initState() {
    super.initState();
    _lookUp();
    // **Re-read them when publishing starts**, rather than trusting the answer
    // taken at launch. A laptop is opened on no network and joins one; the
    // moment somebody switches publishing on is both the moment the list
    // matters and the most likely moment for it to have changed.
    widget.service.isPublishing.addListener(_onPublishing);
  }

  @override
  void dispose() {
    widget.service.isPublishing.removeListener(_onPublishing);
    super.dispose();
  }

  void _onPublishing() {
    if (widget.service.isPublishing.value) _lookUp();
  }

  void _lookUp() {
    localIPv4Addresses().then((addresses) {
      if (mounted) setState(() => _addresses = addresses);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.service.isPublishing,
      builder: (context, publishing, _) {
        final ready = publishing && _addresses.isNotEmpty;
        return BarButton(
          mark: OaaMark.qr,
          semanticLabel: 'Pairing code',
          tooltip: switch ((publishing, _addresses.isEmpty)) {
            (false, _) =>
              'Show a pairing code for a tablet to scan. Turn PUBLISH on '
                  'first — a code nothing is listening at cannot connect.',
            (true, true) =>
              'No network address to put in a code. This machine is '
                  'publishing on loopback only.',
            (true, false) => 'Show a pairing code for a tablet to scan.',
          },
          onPressed: ready
              ? () => showOaaPanel<void>(
                  context: context,
                  builder: (_) => PairingCodePanel(
                    service: widget.service,
                    addresses: _addresses,
                  ),
                )
              : null,
        );
      },
    );
  }
}

/// The status bar's way to become somebody else's display.
///
/// **It opens the host picker directly.** It used to sit behind a panel that
/// asked which end of the link this machine was — a question with two answers
/// that have nothing in common, and one the person pressing the button had
/// already answered. The two answers are two controls now: this and
/// [PublishSwitch], side by side, each doing its own half in one press.
class AttachButton extends StatelessWidget {
  const AttachButton({super.key});

  @override
  Widget build(BuildContext context) {
    return BarButton(
      label: 'ATTACH',
      tooltip:
          'Show another machine’s meters here. This screen becomes a display '
          'for it — it can watch, and it cannot change what that machine is '
          'measuring.',
      onPressed: () => _attach(context),
    );
  }

  /// Picks a host, then leaves the panel behind for the display itself.
  ///
  /// The picker comes off the stack before the screen goes on. A display is
  /// where a tablet stays, and a modal left open underneath it would put the
  /// canvas back the first time somebody pressed Escape at the meters.
  ///
  /// `showOaaPanel`, not `showDialog`. A route is built by the `Navigator`,
  /// which sits above `MaterialApp.home` and therefore above the application's
  /// `OaaTheme` — so a panel that reads the palette the obvious way throws
  /// "No OaaTheme in scope" the moment it opens, in release as well as debug.
  /// This path did, for the whole of Phase 6: the button was unclickable and
  /// nothing said so until somebody pressed it.
  Future<void> _attach(BuildContext context) {
    return showOaaPanel<void>(
      context: context,
      builder: (context) => HostPickerPanel(
        onClose: () => Navigator.of(context).pop(),
        onConnect: (host, port) {
          Navigator.of(context)
            ..pop()
            ..push(
              MaterialPageRoute<void>(
                builder: (_) => RemoteDisplayScreen(host: host, port: port),
              ),
            );
        },
      ),
    );
  }
}
