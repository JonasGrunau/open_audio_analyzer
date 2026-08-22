// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';

import 'display_host.dart';
import 'mdns/host_discovery.dart';
import 'pair_link.dart';
import 'qr_scanner.dart';

/// Choosing a host to attach to: what discovery found, and the address you type
/// when discovery cannot work.
///
/// One panel, opened from two places, because both want exactly this and
/// neither may own a second copy of it — the receive half of the pairing panel
/// on a machine deciding what it wants to be, and the display screen itself
/// while it has no host. It is a [PanelScaffold] over `PanelSection`,
/// `PanelListRow` and `PanelRow` like every other panel in Open Audio Analyzer;
/// what it replaced was a full screen of `InkWell` over a hand-rolled
/// `Container`, a stock `TextField` with an `OutlineInputBorder` and a Material
/// `TextButton`, which is precisely what `AGENTS.md` in this directory says may
/// not happen here: the directory owns a socket, not a design system.
///
/// The typed address is not a fallback for completeness. Multicast is the first
/// thing a guest network blocks and the first thing a corporate image turns
/// off, so a display that could only be reached by discovery would fail in
/// exactly the rooms — venues, rehearsal spaces, shared studios — it exists for.
///
/// There are three ways in and they are offered in the order they cost the
/// person holding the tablet: tap a host discovery found, point the camera at
/// the code the desk is showing, or type the address. The middle one is the
/// answer to the room the third one exists for — a venue that blocks multicast
/// leaves somebody reading four numbers off a laptop across the stage and
/// typing them into a tablet, which is the point at which a feature stops
/// being used. It is offered only where there is a camera to offer; see
/// [canScanQrCodes], and note that the typed field below it never goes away.
class HostPickerPanel extends StatefulWidget {
  const HostPickerPanel({
    required this.onConnect,
    this.onClose,
    this.discovery,
    super.key,
  });

  /// Called with somewhere to attach to. The caller decides what that means:
  /// the pairing panel pushes the display screen, the display screen connects
  /// the client it already has.
  final void Function(String host, int port) onConnect;

  /// Null on a screen with nowhere to go back to — a tablet that opened Open
  /// Audio Analyzer with no capture device has no canvas behind this.
  final VoidCallback? onClose;

  /// The search to show. Null means the one this platform is allowed to do,
  /// which is what every caller passes; a test passes its own, because the
  /// alternative is a widget test that opens a multicast socket.
  final HostDiscovery? discovery;

  @override
  State<HostPickerPanel> createState() => _HostPickerPanelState();
}

class _HostPickerPanelState extends State<HostPickerPanel> {
  /// Owned here rather than passed in: the search holds a socket or a channel
  /// subscription and a timer, and all of them have to go when this leaves the
  /// tree. A picker that outlived its browser would show a list nothing was
  /// refreshing.
  late final HostDiscovery _browser = widget.discovery ?? createHostDiscovery();
  final TextEditingController _address = TextEditingController();

  /// Whether the address field has anything in it, which is the only thing the
  /// footer button needs to know. Held as state rather than read from the
  /// controller during build, because a `TextEditingController` notifies on
  /// every keystroke and rebuilding the whole panel on each one would rebuild
  /// the host list underneath it.
  bool _typed = false;

  /// Whether the last press of Connect was refused by the parser.
  ///
  /// **A button that does nothing is worse than one that says no.** `PairLink`
  /// is strict — a mistyped port is a refusal rather than a host name with a
  /// colon in it, because the alternative is a name lookup that fails several
  /// seconds later for a reason nobody can read — and strictness with no
  /// feedback is a Connect button that swallows the press. Cleared on the next
  /// keystroke, so it marks the attempt and not the field.
  bool _refused = false;

  @override
  void initState() {
    super.initState();
    _browser.start();
  }

  @override
  void dispose() {
    _browser.dispose();
    _address.dispose();
    super.dispose();
  }

  /// The typed address, through the same parser the camera's answer goes
  /// through. `PairLink` is where `host`, `host:port` and a bracketed IPv6 are
  /// understood, and it is one file rather than two so that the field and the
  /// scanner cannot come to differ about what a bare host name means.
  void _submit() {
    final link = PairLink.parse(_address.text);
    if (link == null) {
      setState(() => _refused = true);
      return;
    }
    widget.onConnect(link.host, link.port);
  }

  /// The camera, and then out of it by the same door a tapped host leaves by.
  ///
  /// The scanner pops itself and hands the address to [HostPickerPanel.onConnect]
  /// unchanged, so what happens next is the caller's business exactly as it is
  /// for a discovered host — the desktop pushes a display screen, the tablet
  /// connects the client it already has. A scanner that knew which of those it
  /// was in would be the second implementation of "choose a host".
  Future<void> _scan() async {
    await showOaaPanel<void>(
      context: context,
      builder: (context) => QrScannerPanel(
        onClose: () => Navigator.of(context).pop(),
        onConnect: (host, port) {
          Navigator.of(context).pop();
          widget.onConnect(host, port);
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return PanelScaffold(
      title: 'Show another machine',
      onClose: widget.onClose,
      // The affirmative action is in the footer and it is the typed address,
      // which is why it is disabled until something is typed: a row in the list
      // above connects on its own tap. The two are not competing readings of
      // one button — a discovered host is a live thing to attach to and the
      // connection is undone by one press of Disconnect, so making somebody
      // select it and then confirm buys nothing, while an address somebody is
      // still typing must not connect on every keystroke.
      footer: Row(
        children: [
          const Spacer(),
          OaaButton(
            label: 'Connect',
            emphasis: ButtonEmphasis.primary,
            onPressed: _typed ? _submit : null,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // **The state of the search is the heading's note, not a row.** Both
          // builders wrap the section rather than sitting inside it, because
          // all three things this section can say belong in the same place:
          // "tap one of these" once there are hosts, "still looking" while
          // there are none, and — the one that is not the same kind of
          // sentence — "this device cannot look at all", which is a warning and
          // stays a `PanelNote` in `warn`.
          //
          // Saying "Tap a host to show its meters here" above "looking for
          // hosts on this network" is an instruction to do something that
          // cannot be done, and a single line floating under a heading with
          // nothing else in the section reads as a row that failed to draw.
          ListenableBuilder(
            listenable: Listenable.merge([
              _browser.hosts,
              _browser.isBrowsing,
              _browser.failure,
            ]),
            builder: (context, _) {
              final hosts = _browser.hosts.value;
              final browsing = _browser.isBrowsing.value;
              final failure = _browser.failure.value;

              return PanelSection(
                title: 'On this network',
                note: hosts.isNotEmpty
                    ? 'Tap a host to show its meters here.'
                    // A search that is running *and* has something in its way
                    // does not get to say it is looking: on Android a browse
                    // whose multicast lock was refused sends its query, hears
                    // nothing, and would otherwise present exactly the same
                    // face as a search that is about to succeed.
                    : browsing && failure == null
                    ? 'Looking for hosts on this network…'
                    : null,
                ruled: false,
                children: [
                  for (final host in hosts)
                    PanelListRow(
                      title: host.displayName,
                      note: _describe(host),
                      // A found host is a machine that is publishing, which is
                      // the same fact the sending half of the pairing panel
                      // wears — one mark, one meaning, in both directions of
                      // the link. Nothing in this list is ever `selected`, so
                      // the row brightens under the pointer instead.
                      mark: OaaMark.broadcast,
                      opens: true,
                      onTap: () => widget.onConnect(host.address, host.port),
                    ),
                  // Stated rather than shown as an empty list, which reads as
                  // "nothing is running" and sends somebody to check the wrong
                  // machine — and stated in the words of whatever actually
                  // stopped it where those are known, because "cannot search"
                  // and "macOS is not letting Open Audio Analyzer search" send
                  // that person to two different places.
                  //
                  // Shown while a search is still running too, when there is a
                  // reason to show: Android's multicast lock can be refused on
                  // a socket that binds and joins perfectly, and a browse in
                  // that state is running and deaf.
                  if (hosts.isEmpty && (failure != null || !browsing))
                    PanelNote(
                      failure ??
                          'This device cannot search the network for hosts. '
                              'Enter an address below.',
                      tone: colors.warn,
                      mark: OaaMark.warning,
                    ),
                ],
              );
            },
          ),

          // Above the typed address rather than below it, because it is the
          // easier of the two and a panel is read top to bottom. Absent
          // entirely on a machine with no camera implementation — see
          // `canScanQrCodes` — which is a whole section going rather than a
          // disabled row, since a row that can never be pressed is a promise
          // the product does not keep.
          if (canScanQrCodes)
            PanelSection(
              title: 'By camera',
              children: [
                PanelListRow(
                  title: 'Scan a QR code',
                  mark: OaaMark.scan,
                  opens: true,
                  note:
                      'The machine you want to watch shows one under '
                      'Settings → Publish, or from the code button beside '
                      'PUBLISH in its status bar.',
                  onTap: _scan,
                ),
              ],
            ),

          PanelSection(
            title: 'By address',
            note:
                'A network that blocks multicast hides every host on it. The '
                'address to type is the one the sending machine shows in its '
                'own remote panel.',
            children: [
              PanelRow(
                label: 'Host',
                child: OaaTextField(
                  controller: _address,
                  width: 220,
                  hintText: '192.168.1.20',
                  onChanged: (text) {
                    final typed = text.trim().isNotEmpty;
                    if (typed != _typed || _refused) {
                      setState(() {
                        _typed = typed;
                        _refused = false;
                      });
                    }
                  },
                  onSubmitted: (_) => _submit(),
                ),
              ),
              if (_refused)
                PanelNote(
                  'That is not an address. A name or an IP, and a port after a '
                  'colon if this machine does not use ${DisplayHost.defaultPort}.',
                  tone: colors.warn,
                  mark: OaaMark.warning,
                ),
              const PanelNote(
                'This screen displays only. It cannot reset, retarget or '
                'reconfigure the machine it is watching.',
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _describe(DiscoveredHost host) {
    final format = host.format;
    return '${host.address}:${host.port}'
        '${format == null ? '' : '  ·  $format'}';
  }
}
