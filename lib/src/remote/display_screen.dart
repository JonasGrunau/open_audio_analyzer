// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:oaa_ui/oaa_ui.dart';
import 'package:flutter/material.dart';

import '../app/transport_readout.dart';
import '../canvas/module_host.dart';
import '../clock/meter_clock.dart';
import 'display_client.dart';
import 'host_picker.dart';

/// The tablet's whole world: attach to a host, then draw what it is measuring.
///
/// The thing worth noticing here is how little of it there is. It opens a
/// socket and hands a `MeterSource` and a `PresetSpec` to [ModuleHost] — the
/// *same* [ModuleHost] the desktop canvas uses, wrapping the same thirteen
/// modules and the same painters. There is no tablet rendering path. A remote
/// display whose meters had been written a second time would eventually
/// disagree with the desktop about what the signal did, and at that point
/// neither screen could be trusted; the only way to be sure they agree is for
/// there to be one implementation.
///
/// What the display does *not* do is as deliberate. It cannot reset the host's
/// integrated loudness, change its device, or load a preset on it. Version 1 of
/// the protocol is one-directional, so a screen in the live room cannot become
/// a way for anyone on the venue Wi-Fi to interfere with the measurement
/// somebody is making.
class RemoteDisplayScreen extends StatefulWidget {
  const RemoteDisplayScreen({this.host, this.port, super.key});

  /// Where to attach on arrival, when something upstream already asked.
  ///
  /// Null is the state a tablet is in when it opens Open Audio Analyzer with no
  /// host in mind, and it is not an error — the screen shows [HostPickerPanel]
  /// until it has somewhere to point. Nothing else about the screen differs
  /// between the two.
  final String? host;
  final int? port;

  @override
  State<RemoteDisplayScreen> createState() => _RemoteDisplayScreenState();
}

class _RemoteDisplayScreenState extends State<RemoteDisplayScreen>
    with SingleTickerProviderStateMixin {
  final DisplayClient _client = DisplayClient();

  late final MeterClock _clock;

  int _tab = 0;

  @override
  void initState() {
    super.initState();

    // The display has exactly one ticker, for the same reason the desktop does.
    // It reads the decoded snapshot rather than an engine, and neither the
    // clock nor the modules can tell the difference.
    _clock = MeterClock(engine: _client.snapshot, vsync: this);

    final host = widget.host;
    final port = widget.port;
    if (host != null && port != null) _client.connect(host, port);
  }

  @override
  void dispose() {
    _clock.dispose();
    _client.dispose();
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
            ? OaaColors.precisionInstrument
            : oaaColorsFromSkin(skin);

        return OaaTheme(
          colors: colors,
          child: Theme(
            data: oaaThemeData(colors),
            child: Scaffold(
              backgroundColor: colors.background,
              body: SafeArea(
                child: ValueListenableBuilder<RemoteLinkState>(
                  valueListenable: _client.state,
                  builder: (context, state, _) => state == RemoteLinkState.idle
                      // The same panel the desktop opens to choose a host, on a
                      // screen with nothing behind it. `PanelScaffold` is a
                      // centred, bordered surface rather than a route, so it
                      // sits here unchanged and the two ways into a display
                      // cannot drift apart. Detaching from a host lands back
                      // here, which is what makes the link bar's Disconnect a
                      // way to move to another machine rather than a dead end.
                      ? HostPickerPanel(
                          onConnect: _connect,
                          onClose: Navigator.of(context).canPop()
                              ? () => Navigator.of(context).pop()
                              : null,
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
            clock: clock,
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
///
/// Built like the desktop's own status bar — panel fill under a hairline, and
/// `oaa_ui` controls on it. The tabs and the way out were stock `TextButton`s,
/// which in a theme that has stripped Material of its splash and highlight are
/// text with no border, no hover and no focus ring: three controls that could
/// not be told from the labels beside them.
class _LinkBar extends StatelessWidget {
  const _LinkBar({
    required this.client,
    required this.clock,
    required this.state,
    required this.layout,
    required this.tab,
    required this.onTab,
    required this.onDisconnect,
  });

  final DisplayClient client;

  /// The one clock, borrowed for the transport readout. A tablet has no ticker
  /// of its own to spare either.
  final MeterClock clock;

  final RemoteLinkState state;
  final PresetSpec? layout;
  final int tab;
  final ValueChanged<int> onTab;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final tabs = layout?.tabs ?? const <TabSpec>[];

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(
          bottom: BorderSide(color: colors.hairline, width: OaaStroke.hairline),
        ),
      ),
      child: Padding(
        // **`Space.sm` above and below a `OaaControl.height` control, not
        // `Space.xs`.** This bar is not the desktop's 40 px status bar and does
        // not have its problem: there is no source, no clock, no calibration and
        // no frame rate to fit, just a name, the tabs and the way out. At 4 px
        // the segmented control and the button stood a hair off the hairline
        // under them and the whole strip read as clamped shut. 8 px gives the
        // controls room on a bar that has it to give.
        padding: const EdgeInsets.symmetric(
          horizontal: Space.md,
          vertical: Space.sm,
        ),
        // **Reading order, left to right: who, what, and the way out.** The tabs
        // belong beside the name they belong to — a tablet is held, and its far
        // corner is the most awkward place on the screen to put the control the
        // viewer touches most. What stays on the right is the one control nobody
        // wants to hit by accident.
        child: Row(
          children: [
            _StateDot(state: state),
            const SizedBox(width: Space.sm),
            ValueListenableBuilder<String?>(
              valueListenable: client.hostName,
              builder: (context, name, _) => Text(
                name ?? 'Connecting…',
                style: OaaType.body.copyWith(color: colors.textPrimary),
              ),
            ),

            // **The playhead of the DAW at the other end, and the full width of
            // it.** The desktop's bar can afford a timecode and nothing else;
            // this one has room for the tempo and the meter as well, and it is
            // the screen somebody is *reading* — a tablet on a stand across the
            // room, next to the person who needs to say where the session is.
            //
            // Not wrapped in a `ValueListenableBuilder`: while a DAW rolls,
            // this changes at the publish rate, and rebuilding the bar thirty
            // times a second to move a clock is what the painted readout exists
            // to avoid. It draws nothing at all when the host has no transport,
            // so a display mirroring a desktop that is metering a sound card
            // does not gain a row of dashes.
            const SizedBox(width: Space.md),
            TransportReadout(
              transportOf: () => client.transport.value,
              repaint: clock,
              width: TransportReadout.fullWidth,
            ),

            if (tabs.length > 1) ...[
              const SizedBox(width: Space.md),
              SegmentedControl<int>(
                value: tab.clamp(0, tabs.length - 1),
                segments: [
                  for (final (index, spec) in tabs.indexed)
                    (value: index, label: spec.name),
                ],
                onChanged: onTab,
              ),
            ],

            // The message is what gives way when the bar is short of room: it is
            // empty whenever the link is healthy, and when it is not, an
            // ellipsis on a warning still leaves the dot beside the name saying
            // the same thing in colour.
            const SizedBox(width: Space.md),
            Expanded(
              child: _StateMessage(client: client, state: state),
            ),
            const SizedBox(width: Space.sm),

            OaaButton(label: 'Disconnect', onPressed: onDisconnect),
          ],
        ),
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
    final colors = OaaTheme.of(context);
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
    final colors = OaaTheme.of(context);

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
          style: OaaType.label.copyWith(color: color),
        );
      },
    );
  }
}

class _NothingToDraw extends StatelessWidget {
  const _NothingToDraw();

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    return Center(
      child: Text(
        'The host has not sent a layout yet.',
        style: OaaType.label.copyWith(color: colors.textMuted),
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
                    // items would be worse than none — so the title bar draws
                    // no button, rather than a button that swallows the tap.
                    onMenu: null,
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
