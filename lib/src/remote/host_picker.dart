// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';

import 'display_host.dart';
import 'mdns/host_discovery.dart';

/// Choosing a host to attach to: what discovery found, and the address you type
/// when discovery cannot work.
///
/// One panel, opened from two places, because both want exactly this and
/// neither may own a second copy of it — the receive half of the pairing panel
/// on a machine deciding what it wants to be, and the display screen itself
/// while it has no host. It is a [PanelScaffold] over `PanelSection`,
/// `PanelListRow` and `PanelRow` like every other panel in Bel; what it
/// replaced was a full screen of `InkWell` over a hand-rolled `Container`, a
/// stock `TextField` with an `OutlineInputBorder` and a Material `TextButton`,
/// which is precisely what `AGENTS.md` in this directory says may not happen
/// here: the directory owns a socket, not a design system.
///
/// The typed address is not a fallback for completeness. Multicast is the first
/// thing a guest network blocks and the first thing a corporate image turns
/// off, so a display that could only be reached by discovery would fail in
/// exactly the rooms — venues, rehearsal spaces, shared studios — it exists for.
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

  /// Null on a screen with nowhere to go back to — a tablet that opened Bel
  /// with no capture device has no canvas behind this.
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

  void _submit() {
    final text = _address.text.trim();
    if (text.isEmpty) return;

    // `host`, `host:port` or a bare IPv6 in brackets. The port defaults rather
    // than being demanded: almost nobody has changed it, and asking for it
    // turns a working default into a thing to get wrong.
    var host = text;
    var port = DisplayHost.defaultPort;
    final colon = text.lastIndexOf(':');
    if (colon > 0 && !text.endsWith(']')) {
      final parsed = int.tryParse(text.substring(colon + 1));
      if (parsed != null && parsed > 0 && parsed <= 65535) {
        host = text.substring(0, colon);
        port = parsed;
      }
    }
    widget.onConnect(host, port);
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

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
          BelButton(
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
                    : browsing
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
                      mark: BelMark.broadcast,
                      opens: true,
                      onTap: () => widget.onConnect(host.address, host.port),
                    ),
                  // Stated rather than shown as an empty list, which reads as
                  // "nothing is running" and sends somebody to check the wrong
                  // machine — and stated in the words of whatever actually
                  // stopped it where those are known, because "cannot search"
                  // and "macOS is not letting Bel search" send that person to
                  // two different places. Android is the case with no sentence
                  // to give: it needs a `WifiManager.MulticastLock` that Dart
                  // cannot take, and the socket opens perfectly without one.
                  if (hosts.isEmpty && !browsing)
                    PanelNote(
                      failure ??
                          'This device cannot search the network for hosts. '
                              'Enter an address below.',
                      tone: colors.warn,
                      mark: BelMark.warning,
                    ),
                ],
              );
            },
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
                child: BelTextField(
                  controller: _address,
                  width: 220,
                  hintText: '192.168.1.20',
                  onChanged: (text) {
                    final typed = text.trim().isNotEmpty;
                    if (typed != _typed) setState(() => _typed = typed);
                  },
                  onSubmitted: (_) => _submit(),
                ),
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
