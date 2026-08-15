// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:bel_core/bel_core.dart';
import 'package:bel_ui/bel_ui.dart';
import 'package:flutter/material.dart';

import '../canvas/module_host.dart';
import '../clock/meter_clock.dart';
import 'display_client.dart';
import 'display_host.dart';
import 'mdns/mdns_service.dart';

/// The tablet's whole world: find a host, then draw what it is measuring.
///
/// The thing worth noticing here is how little of it there is. It finds a host,
/// opens a socket, and then hands a `MeterSource` and a `PresetSpec` to
/// [ModuleHost] — the *same* [ModuleHost] the desktop canvas uses, wrapping the
/// same twelve modules and the same painters. There is no tablet rendering
/// path. A remote display whose meters had been written a second time would
/// eventually disagree with the desktop about what the signal did, and at that
/// point neither screen could be trusted; the only way to be sure they agree is
/// for there to be one implementation.
///
/// What the display does *not* do is as deliberate. It cannot reset the host's
/// integrated loudness, change its device, or load a preset on it. Version 1 of
/// the protocol is one-directional, so a screen in the live room cannot become
/// a way for anyone on the venue Wi-Fi to interfere with the measurement
/// somebody is making.
class RemoteDisplayScreen extends StatefulWidget {
  const RemoteDisplayScreen({super.key});

  @override
  State<RemoteDisplayScreen> createState() => _RemoteDisplayScreenState();
}

class _RemoteDisplayScreenState extends State<RemoteDisplayScreen>
    with SingleTickerProviderStateMixin {
  final DisplayClient _client = DisplayClient();
  final MdnsBrowser _browser = MdnsBrowser();
  final TextEditingController _address = TextEditingController();

  late final MeterClock _clock;

  int _tab = 0;

  @override
  void initState() {
    super.initState();

    // The display has exactly one ticker, for the same reason the desktop does.
    // It reads the decoded snapshot rather than an engine, and neither the
    // clock nor the modules can tell the difference.
    _clock = MeterClock(engine: _client.snapshot, vsync: this);
    _browser.start();
  }

  @override
  void dispose() {
    _clock.dispose();
    _browser.dispose();
    _client.dispose();
    _address.dispose();
    super.dispose();
  }

  void _connect(String host, int port) {
    _client.connect(host, port);
    setState(() => _tab = 0);
  }

  @override
  Widget build(BuildContext context) {
    // The palette follows the host's skin, so the two screens look like one
    // instrument. Rebuilt only when the skin actually changes — a skin arrives
    // once per session, not once per frame.
    return ValueListenableBuilder<Skin?>(
      valueListenable: _client.skin,
      builder: (context, skin, _) {
        final colors = skin == null
            ? BelColors.precisionInstrument
            : belColorsFromSkin(skin);

        return BelTheme(
          colors: colors,
          child: Theme(
            data: belThemeData(colors),
            child: Scaffold(
              backgroundColor: colors.background,
              body: SafeArea(
                child: ValueListenableBuilder<RemoteLinkState>(
                  valueListenable: _client.state,
                  builder: (context, state, _) => state == RemoteLinkState.idle
                      ? _ConnectPanel(
                          browser: _browser,
                          address: _address,
                          onConnect: _connect,
                        )
                      : _LiveDisplay(
                          client: _client,
                          clock: _clock,
                          state: state,
                          tab: _tab,
                          onTab: (index) => setState(() => _tab = index),
                          onDisconnect: () => _client.disconnect(),
                        ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Pick a host, or type where one is.
///
/// The typed address is not a fallback for completeness. Multicast is the first
/// thing a guest network blocks and the first thing a corporate image turns
/// off, so a display that could only be reached by discovery would fail in
/// exactly the rooms — venues, rehearsal spaces, shared studios — it exists for.
class _ConnectPanel extends StatelessWidget {
  const _ConnectPanel({
    required this.browser,
    required this.address,
    required this.onConnect,
  });

  final MdnsBrowser browser;
  final TextEditingController address;
  final void Function(String host, int port) onConnect;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Padding(
      padding: const EdgeInsets.all(Space.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Remote display',
            style: BelType.body.copyWith(
              color: colors.textPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Space.xs),
          Text(
            'Showing another machine’s meters. This screen displays only — it '
            'cannot change what the host is measuring.',
            style: BelType.label.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: Space.lg),

          Expanded(
            child: ValueListenableBuilder<List<DiscoveredHost>>(
              valueListenable: browser.hosts,
              builder: (context, hosts, _) {
                if (hosts.isEmpty) {
                  return _Searching(browser: browser);
                }
                return ListView.separated(
                  itemCount: hosts.length,
                  separatorBuilder: (_, _) => const SizedBox(height: Space.xs),
                  itemBuilder: (context, index) => _HostRow(
                    host: hosts[index],
                    onTap: () =>
                        onConnect(hosts[index].address, hosts[index].port),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: Space.lg),
          _AddressField(controller: address, onConnect: onConnect),
        ],
      ),
    );
  }
}

class _Searching extends StatelessWidget {
  const _Searching({required this.browser});

  final MdnsBrowser browser;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return ValueListenableBuilder<bool>(
      valueListenable: browser.isBrowsing,
      builder: (context, browsing, _) => Center(
        child: Text(
          browsing
              ? 'Looking for hosts on this network…'
              // Stated rather than shown as an empty list, which reads as
              // "nothing is running" and sends somebody to check the wrong
              // machine.
              : 'This device cannot search the network for hosts.\n'
                    'Enter the host’s address below.',
          textAlign: TextAlign.center,
          style: BelType.label.copyWith(color: colors.textMuted),
        ),
      ),
    );
  }
}

class _HostRow extends StatelessWidget {
  const _HostRow({required this.host, required this.onTap});

  final DiscoveredHost host;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final format = host.format;

    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.md,
        ),
        decoration: BoxDecoration(
          color: colors.panel,
          borderRadius: BelRadius.allMd,
          border: Border.all(color: colors.hairline, width: BelStroke.hairline),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    host.displayName,
                    style: BelType.body.copyWith(color: colors.textPrimary),
                  ),
                  const SizedBox(height: Space.xxs),
                  Text(
                    '${host.address}:${host.port}'
                    '${format == null ? '' : '  ·  $format'}',
                    style: BelType.label.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: colors.textMuted),
          ],
        ),
      ),
    );
  }
}

class _AddressField extends StatelessWidget {
  const _AddressField({required this.controller, required this.onConnect});

  final TextEditingController controller;
  final void Function(String host, int port) onConnect;

  void _submit() {
    final text = controller.text.trim();
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
    onConnect(host, port);
  }

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            style: BelType.body.copyWith(color: colors.textPrimary),
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'Host address, for example 192.168.1.20',
              hintStyle: BelType.label.copyWith(color: colors.textMuted),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: Space.md,
                vertical: Space.md,
              ),
              border: OutlineInputBorder(
                borderRadius: BelRadius.allMd,
                borderSide: BorderSide(color: colors.hairline),
              ),
            ),
          ),
        ),
        const SizedBox(width: Space.sm),
        TextButton(onPressed: _submit, child: const Text('CONNECT')),
      ],
    );
  }
}

/// The canvas, once a host is attached.
class _LiveDisplay extends StatelessWidget {
  const _LiveDisplay({
    required this.client,
    required this.clock,
    required this.state,
    required this.tab,
    required this.onTab,
    required this.onDisconnect,
  });

  final DisplayClient client;
  final MeterClock clock;
  final RemoteLinkState state;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<PresetSpec?>(
      valueListenable: client.layout,
      builder: (context, layout, _) => Column(
        children: [
          _LinkBar(
            client: client,
            state: state,
            layout: layout,
            tab: tab,
            onTab: onTab,
            onDisconnect: onDisconnect,
          ),
          Expanded(
            child: layout == null || layout.tabs.isEmpty
                ? const _NothingToDraw()
                : ValueListenableBuilder<Calibration>(
                    valueListenable: client.calibration,
                    builder: (context, calibration, _) => _RemoteCanvas(
                      tab: layout.tabs[tab.clamp(0, layout.tabs.length - 1)],
                      source: client.snapshot,
                      clock: clock,
                      calibration: calibration,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// The strip along the top: who this is, whether the picture is current, and
/// which tab is showing.
class _LinkBar extends StatelessWidget {
  const _LinkBar({
    required this.client,
    required this.state,
    required this.layout,
    required this.tab,
    required this.onTab,
    required this.onDisconnect,
  });

  final DisplayClient client;
  final RemoteLinkState state;
  final PresetSpec? layout;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final tabs = layout?.tabs ?? const <TabSpec>[];

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: Space.md,
        vertical: Space.sm,
      ),
      color: colors.panel,
      child: Row(
        children: [
          _StateDot(state: state),
          const SizedBox(width: Space.sm),
          ValueListenableBuilder<String?>(
            valueListenable: client.hostName,
            builder: (context, name, _) => Text(
              name ?? 'Connecting…',
              style: BelType.body.copyWith(color: colors.textPrimary),
            ),
          ),
          const SizedBox(width: Space.md),
          Expanded(
            child: _StateMessage(client: client, state: state),
          ),

          if (tabs.length > 1)
            for (var index = 0; index < tabs.length; index++)
              Padding(
                padding: const EdgeInsets.only(left: Space.xs),
                child: TextButton(
                  onPressed: () => onTab(index),
                  child: Text(
                    tabs[index].name.toUpperCase(),
                    style: BelType.label.copyWith(
                      color: index == tab ? colors.accent : colors.textMuted,
                    ),
                  ),
                ),
              ),

          const SizedBox(width: Space.sm),
          TextButton(onPressed: onDisconnect, child: const Text('DISCONNECT')),
        ],
      ),
    );
  }
}

/// One dot, in the colour of the link's honesty.
class _StateDot extends StatelessWidget {
  const _StateDot({required this.state});

  final RemoteLinkState state;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    final color = switch (state) {
      RemoteLinkState.live => colors.accent,
      RemoteLinkState.stale => colors.warn,
      RemoteLinkState.failed => colors.over,
      RemoteLinkState.connecting || RemoteLinkState.idle => colors.textMuted,
    };

    // Painted rather than decorated: a DecoratedBox absorbs pointer events over
    // its whole shape, and this one sits in a row of buttons.
    return CustomPaint(
      size: const Size(Space.xs, Space.xs),
      painter: _DotPainter(color),
    );
  }
}

class _DotPainter extends CustomPainter {
  _DotPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawCircle(
    size.center(Offset.zero),
    size.width / 2,
    Paint()..color = color,
  );

  @override
  bool shouldRepaint(_DotPainter oldDelegate) => oldDelegate.color != color;
}

class _StateMessage extends StatelessWidget {
  const _StateMessage({required this.client, required this.state});

  final DisplayClient client;
  final RemoteLinkState state;

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);

    return ValueListenableBuilder<String?>(
      valueListenable: client.failure,
      builder: (context, failure, _) {
        final (text, color) = switch (state) {
          // Named plainly. "Stale" on its own reads as jargon, and the whole
          // point is that somebody glancing at the screen understands that what
          // they are looking at is not current.
          RemoteLinkState.stale => (
            'No measurements for two seconds — this is not current',
            colors.warn,
          ),
          RemoteLinkState.failed => (
            failure ?? 'The link dropped. Retrying.',
            colors.over,
          ),
          RemoteLinkState.connecting => ('Connecting…', colors.textMuted),
          _ => ('', colors.textMuted),
        };

        if (text.isEmpty) return const SizedBox.shrink();
        return Text(
          text,
          overflow: TextOverflow.ellipsis,
          style: BelType.label.copyWith(color: color),
        );
      },
    );
  }
}

class _NothingToDraw extends StatelessWidget {
  const _NothingToDraw();

  @override
  Widget build(BuildContext context) {
    final colors = BelTheme.of(context);
    return Center(
      child: Text(
        'The host has not sent a layout yet.',
        style: BelType.label.copyWith(color: colors.textMuted),
      ),
    );
  }
}

/// The same modules, in the same grid, driven by a socket.
///
/// [GridGeometry] is the desktop's own arithmetic, imported rather than
/// reimplemented — which is what makes the layout screen-independent for free.
/// The grid is 24 columns wide on a 32-inch monitor and on a 11-inch tablet, so
/// a preset written at the desk arrives on the tablet looking like itself
/// rather than like a scaled photograph of itself.
class _RemoteCanvas extends StatelessWidget {
  const _RemoteCanvas({
    required this.tab,
    required this.source,
    required this.clock,
    required this.calibration,
  });

  final TabSpec tab;
  final MeterSource source;
  final MeterClock clock;
  final Calibration calibration;

  @override
  Widget build(BuildContext context) {
    if (tab.modules.isEmpty) {
      return const _NothingToDraw();
    }

    return Padding(
      padding: const EdgeInsets.all(Space.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final geometry = GridGeometry(size: constraints.biggest);

          return Stack(
            children: [
              for (final module in tab.modules)
                Positioned.fromRect(
                  rect: geometry.rectFor(module.rect),
                  // Keyed by id for the same reason the desktop canvas keys
                  // them: it preserves each module's State, and with it the
                  // paragraphs its painter has laid out.
                  key: ValueKey<String>(module.id),
                  child: ModuleHost(
                    spec: module,
                    engine: source,
                    clock: clock,
                    calibration: calibration,
                    selected: false,
                    // A display has no menu. There is nothing on it a viewer is
                    // allowed to change, and a menu that opened onto disabled
                    // items would be worse than none.
                    onMenu: () {},
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
