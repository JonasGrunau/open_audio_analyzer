// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/providers.dart';
import 'mdns/mdns_service.dart';
import 'pair_link.dart';
import 'remote_display_service.dart';

/// Everything about publishing except the switch itself.
///
/// **A section of the settings panel that lives in `lib/src/remote/`**, for the
/// reason `PublishSwitch` does: it owns two text controllers, a lookup of this
/// machine's addresses and three `ValueListenableBuilder`s over a service that
/// holds a socket and an mDNS responder. `settings_panel.dart` composes it and
/// otherwise knows nothing about any of that — the same split as the status
/// bar, which is assembled in `oaa_app.dart` out of a control defined here.
///
/// **The switch is deliberately not in it.** Publishing is turned on and off
/// from the menu bar, where it is visible without opening anything, and a
/// second toggle here would be a second place for one state to be read from —
/// which is how two controls come to disagree. The section's own note says
/// where the switch is, and carries the live state so that "am I being watched"
/// is answerable from the panel as well.
class PublishSection extends ConsumerStatefulWidget {
  const PublishSection({required this.service, super.key});

  final RemoteDisplayService service;

  @override
  ConsumerState<PublishSection> createState() => _PublishSectionState();
}

class _PublishSectionState extends ConsumerState<PublishSection> {
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
  /// place instead of quietly binding somewhere nobody is looking. That is also
  /// why it is safe to call on every focus change — a field somebody tabbed
  /// through without touching writes back what it already held.
  void _apply() {
    ref
        .read(settingsProvider.notifier)
        .setRemoteDisplay(
          name: _name.text,
          port: int.tryParse(_port.text.trim()),
        );
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final service = widget.service;

    // Read from the settings rather than from the service: the settings are
    // what a tap writes, and the service adopts them a rebuild later. Showing
    // the service's copy would leave the selected rate looking unchanged for a
    // frame after somebody chose it.
    final settings = ref.watch(settingsProvider);

    return ValueListenableBuilder<bool>(
      valueListenable: service.isPublishing,
      builder: (context, publishing, _) => ValueListenableBuilder<int>(
        valueListenable: service.clients,
        builder: (context, clients, _) => PanelSection(
          title: 'Publish',
          // **The live state goes in the heading's note.** The switch is in the
          // menu bar, so a section that said only "sends these meters to
          // displays" would be a page of configuration for something the panel
          // never says is running — and the attached-display count is not in
          // the bar either, which leaves this the one place it is written down.
          note: switch ((publishing, clients)) {
            (false, _) => 'Off. The switch is PUBLISH, in the menu bar.',
            (true, 0) => 'Publishing. No displays attached.',
            (true, 1) => 'Publishing. 1 display attached.',
            (true, final n) => 'Publishing. $n displays attached.',
          },
          children: [
            // **Both notices come first, above the standing advice rather than
            // below it.** They were last in the section they came from, which
            // put a live fault directly beneath the password warning in the
            // same amber and with the same mark — so the one thing on the panel
            // that needed acting on read as a second paragraph of boilerplate.
            // A caution that is always true and a fault that is true right now
            // cannot look alike, and here they only have position to tell them
            // apart.
            ValueListenableBuilder<String?>(
              valueListenable: service.failure,
              builder: (context, failure, _) => failure == null
                  ? const SizedBox.shrink()
                  // Named out loud, because the common cause is a refused
                  // local-network permission, and the symptom without this line
                  // is a host nobody can find for no stated reason.
                  : PanelNote(
                      'Could not publish: $failure',
                      tone: colors.over,
                      mark: OaaMark.warning,
                    ),
            ),
            // The other half of the same question, and the half that is
            // actually reached: publishing succeeded and the announcement did
            // not. `warn` rather than `over` because nothing here failed — the
            // port is open and a display given the address works. What is gone
            // is only the finding.
            ValueListenableBuilder<String?>(
              valueListenable: service.advertisementFailure,
              builder: (context, advertisement, _) => advertisement == null
                  ? const SizedBox.shrink()
                  : PanelNote(
                      advertisement,
                      tone: colors.warn,
                      mark: OaaMark.warning,
                    ),
            ),

            // One line, because this is one edit. The name and the port are the
            // same fact — where a display should look — and they are committed
            // together, so two stacked rows made a two-field form look like two
            // separate settings.
            //
            // **Committed when the edit is finished, not on the keystroke and
            // not from a button.** The settings panel has no OK button
            // anywhere, on purpose: one lets a panel be abandoned in a state
            // the interface has already shown you. But these two cannot write
            // through on every keystroke either — a port is not a valid port
            // until it is finished, and binding to each prefix of one on the
            // way to 5560 would move the socket three times. Enter and losing
            // focus are the two ways an edit ends, and both commit; there is
            // nothing left for a button to do.
            PanelRow(
              label: 'Name and port',
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Focus(
                    onFocusChange: (focused) {
                      if (!focused) _apply();
                    },
                    child: OaaTextField(
                      controller: _name,
                      width: 200,
                      onSubmitted: (_) => _apply(),
                    ),
                  ),
                  const SizedBox(width: Space.sm),
                  Focus(
                    onFocusChange: (focused) {
                      if (!focused) _apply();
                    },
                    child: OaaTextField(
                      controller: _port,
                      width: 88,
                      numeric: true,
                      onSubmitted: (_) => _apply(),
                    ),
                  ),
                ],
              ),
            ),
            // Shown whether or not discovery is working. A tablet on a network
            // that blocks multicast needs somewhere to look, and being told
            // after it has already failed is too late.
            if (_addresses.isNotEmpty)
              PanelNote(
                'If a display cannot find this machine, type '
                '${_addresses.first}:${settings.remoteDisplayPort} into it.',
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

            // **The same fact as the address note above, in a form a camera can
            // read.** Typing an address is what that note asks for and it is
            // the step the feature loses people at: four numbers and a port,
            // read off a laptop on the other side of a room, into a tablet held
            // in one hand. The code carries exactly what the note says to type
            // and nothing else — it is not a second way to configure anything,
            // and a display that scans one can still do nothing but watch.
            //
            // A row rather than a button, because it pushes a panel: `opens`
            // and a chevron say so before it is pressed.
            PanelListRow(
              title: 'Show a QR code',
              mark: OaaMark.qr,
              opens: true,
              note: _addresses.isEmpty
                  ? 'No network address to publish yet.'
                  : 'A tablet with a camera reads this instead of being typed '
                        'an address.',
              // Null rather than a panel with an empty square in it. There is
              // nothing to encode until this machine has an address, which is
              // the state a laptop is in with every interface down.
              onTap: _addresses.isEmpty
                  ? null
                  : () => showOaaPanel<void>(
                      context: context,
                      builder: (context) => PairingCodePanel(
                        service: service,
                        addresses: _addresses,
                      ),
                    ),
            ),

            PanelNote(
              'There is no password on the connection. Anyone on this network '
              'who can find it can watch these meters, so leave it off on a '
              'network you do not trust. That is also why publishing is never '
              'remembered: it starts off at every launch, whatever it was set '
              'to last time.',
              tone: colors.warn,
              mark: OaaMark.warning,
            ),
          ],
        ),
      ),
    );
  }
}

/// The address, as a square somebody can point a camera at.
///
/// **Its own panel rather than a square in the Publish section**, for the
/// reason the whole feature exists: a code read across a room has to be big,
/// and one sized to fit between a port field and a password warning is one
/// nobody can scan without walking over to the desk — at which point they could
/// have read the address off it.
class PairingCodePanel extends ConsumerStatefulWidget {
  const PairingCodePanel({
    required this.service,
    required this.addresses,
    super.key,
  });

  final RemoteDisplayService service;

  /// Every non-loopback IPv4 address this machine has.
  final List<String> addresses;

  @override
  ConsumerState<PairingCodePanel> createState() => _PairingCodePanelState();
}

class _PairingCodePanelState extends ConsumerState<PairingCodePanel> {
  /// Which interface the code names.
  ///
  /// **Offered as a choice rather than guessed at, whenever there is more than
  /// one.** A laptop on Wi-Fi with a Thunderbolt dock has two addresses and a
  /// machine with a VPN up has three, and which of them the tablet can reach is
  /// not knowable from this side — `mdns_service.dart` says the same thing
  /// where it announces all of them. A code that silently picked the wrong one
  /// fails as a tablet that scans, connects, and times out, which reads as a
  /// broken feature rather than as the wrong network.
  late String _address = widget.addresses.first;

  /// Rebuilt only when the text changes.
  ///
  /// Encoding is a few hundred microseconds and this is a panel, not the frame
  /// path — but it is called from `build`, which also runs on a repaint, a
  /// resize and a skin change, and there is no reason for any of those to
  /// recompute eight mask candidates.
  String? _encoded;
  QrCode? _code;

  QrCode? _codeFor(String text) {
    if (text != _encoded) {
      _encoded = text;
      _code = QrCode.encode(text);
    }
    return _code;
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final port = ref.watch(settingsProvider).remoteDisplayPort;
    final link = PairLink.format(_address, port);
    final code = _codeFor(link);

    return PanelScaffold(
      title: 'Pairing code',
      onClose: () => Navigator.of(context).pop(),
      footer: Row(
        children: [
          const Spacer(),
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
          PanelSection(
            title: 'Point a tablet at this',
            ruled: false,
            // **Named per device, because the two do not have the same route
            // to it.** A tablet has no menu bar: it opens on the connect
            // screen and the scanner is a row on it. A desktop watching another
            // desktop gets there through ATTACH.
            note:
                'On a tablet: Scan a QR code, on the screen it opens with. On '
                'another desktop: ATTACH in the menu bar.',
            children: [
              Center(
                child: code == null
                    // Unreachable with an address in it, and stated rather than
                    // left as a hole in the layout: a panel titled "Pairing
                    // code" with nothing under the heading is a rendering bug
                    // as far as anybody looking at it is concerned.
                    ? PanelNote(
                        'This address is too long to put in a code. Type '
                        '$_address:$port into the display instead.',
                        tone: colors.warn,
                        mark: OaaMark.warning,
                      )
                    : OaaQrCode(code: code, size: 260),
              ),
              const SizedBox(height: Space.md),

              // Under the code, in the face every number in this application
              // is set in. It is what the code says, and it is here because a
              // camera is not always the answer — a tablet with no camera
              // permission, or somebody who would rather type.
              Center(
                child: SelectableText(
                  link,
                  style: OaaType.reading(
                    15,
                  ).copyWith(color: colors.textPrimary),
                ),
              ),

              if (widget.addresses.length > 1) ...[
                const SizedBox(height: Space.md),
                PanelRow(
                  label: 'Address',
                  note:
                      'This machine has more than one. The code names the one '
                      'chosen here, and only a display on that network can '
                      'reach it.',
                  child: PanelMenu<String>(
                    // `label` is what the control *reads*, and `semanticLabel`
                    // is what it chooses — a menu whose face says "Address"
                    // beside a code that says 192.168.1.20 is two answers to
                    // one question.
                    label: _address,
                    semanticLabel: 'Address',
                    selected: _address,
                    options: [
                      for (final address in widget.addresses)
                        (value: address, label: address),
                    ],
                    onSelected: (address) => setState(() => _address = address),
                  ),
                ),
              ],

              // The code is an address, not a switch. Somebody who scans one
              // while the socket is closed gets a connection refused and no
              // idea why, so the panel that hands the address out is where the
              // question has to be answered.
              ValueListenableBuilder<bool>(
                valueListenable: widget.service.isPublishing,
                builder: (context, publishing, _) => publishing
                    ? const SizedBox.shrink()
                    : PanelNote(
                        'Publishing is off, so nothing is listening at this '
                        'address yet. Turn on PUBLISH in the menu bar.',
                        tone: colors.warn,
                        mark: OaaMark.warning,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
