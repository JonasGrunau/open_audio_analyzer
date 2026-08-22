// SPDX-License-Identifier: GPL-3.0-or-later

/// A colour, chosen rather than typed.
///
/// The two controls behind the theme editor, and the only two in this package
/// that were not in `packages/oaa_ui/AGENTS.md`'s closed control table before
/// they were written. That table says anything reached for outside it is a
/// decision to make here first; this file is that decision, and the reason is
/// that a skin is thirteen colours and there is no arrangement of a button, a
/// menu, a toggle and a text field that lets somebody *find* one.
///
/// A text field alone was the alternative and it very nearly won — the skin
/// format is hex, `Skin.parseColor` already accepts every spelling of it, and
/// zero new controls is a real argument in a design system whose whole premise
/// is that a closed set cannot drift. What decided it is that typing hex is a
/// way of *recording* a colour you have already chosen, and nobody chooses one
/// that way. The field is still here, underneath, and it is still the thing
/// that commits: the square and the strip move it, and it is what a keyboard
/// or a paste reaches.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:oaa_core/oaa_core.dart';

import 'drag_devices.dart';
import 'focusable.dart';
import 'panel.dart';
import 'skin_palette.dart';
import 'slider.dart';
import 'theme.dart';
import 'tokens.dart';

/// Black and white, and the only two literal colours in this file.
///
/// The crosshair and the hue marker are drawn over *every* colour there is —
/// that is what a picker shows — so they cannot take a value from the palette
/// the way everything else in this package does: a skin whose `textPrimary`
/// happens to be near the hue under the pointer would lose its own marker. A
/// white mark ringed in black is legible on all of them, and it is legible for
/// the same reason a QR code is dark-on-light: it is a property of what the
/// thing has to survive rather than a choice somebody made. See `qr.dart`,
/// which is the other widget here that does not follow the skin.
const Color _markInk = Color(0xFFFFFFFF);
const Color _markShadow = Color(0xFF000000);

/// A colour as a control: the swatch, its hex, and a press that opens a picker.
///
/// A boxed control of [OaaControl.height], because it stands in a `PanelRow`
/// beside buttons and fields and the one thing every control in such a row has
/// to agree on is its height — see the control metrics in
/// `packages/oaa_ui/AGENTS.md`. That also makes the hit target the whole box
/// rather than a 24 px swatch, which is what a stylus needs.
class OaaColorWell extends StatelessWidget {
  const OaaColorWell({
    required this.value,
    required this.onTap,
    required this.semanticLabel,
    this.expanded = false,
    super.key,
  });

  /// What is in the well.
  final Color value;

  /// Opens or closes the picker. Null disables the control outright.
  final VoidCallback? onTap;

  /// What this colour is *for* — the role, not the colour. "Accent", not
  /// "teal": the hex is already in the announcement, and a screen reader
  /// reading a colour name it inferred would be inventing one.
  final String semanticLabel;

  /// Whether this well's picker is the one currently open. Drawn with the
  /// selection border, because that is what it is — one of a set, chosen.
  final bool expanded;

  /// The swatch inside the box.
  static const double _swatch = Space.md;

  /// One square of the checkerboard behind a translucent swatch.
  static const double _check = Space.xs;

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final hex = Skin.formatHex(skinArgb(value));

    return OaaFocusable(
      onActivate: onTap,
      semanticLabel: semanticLabel,
      selected: expanded,
      builder: (context, hovered, focused) => Container(
        height: OaaControl.height,
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        decoration: BoxDecoration(
          color: colors.background,
          borderRadius: OaaRadius.allSm,
          border: Border.all(
            // Focus is a hairline in `textPrimary`, selection is
            // `hairlineStrong` at emphasis weight, and the two are told apart
            // by weight as well as colour — see `OaaFocusable`.
            color: focused
                ? colors.textPrimary
                : expanded
                ? colors.hairlineStrong
                : hovered
                ? colors.hairlineStrong
                : colors.hairline,
            width: expanded ? OaaStroke.emphasis : OaaStroke.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: _swatch,
              height: _swatch,
              child: CustomPaint(
                painter: _SwatchPainter(
                  color: value,
                  border: colors.hairline,
                  checkerLight: colors.panelRaised,
                  checkerDark: colors.hairline,
                  square: _check,
                ),
              ),
            ),
            const SizedBox(width: Space.sm),
            Text(
              hex,
              // A hex value is a number the way a true-peak ceiling is: it is
              // read digit by digit and compared against another one.
              style: OaaType.readingSmall.copyWith(color: colors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}

/// The surface a colour is chosen on: a saturation/value square, a hue strip,
/// and the hex and alpha the two of them write.
///
/// ---------------------------------------------------------------------------
/// Why this holds HSV rather than deriving it
///
/// Hue and saturation are not recoverable from a `Color` at the edges of the
/// space. Black has no hue and no saturation; any grey has no hue. So a picker
/// that converted `widget.value` to HSV on every build would lose the hue the
/// moment somebody dragged the value to the bottom of the square, and the
/// pointer would be unable to come back up through the colour it went down
/// through. The state is HSV, the output is a `Color`, and [didUpdateWidget]
/// re-derives only when the incoming value is one this picker did not produce
/// — a Revert, or a hex somebody pasted.
class OaaColorPicker extends StatefulWidget {
  const OaaColorPicker({
    required this.value,
    required this.onChanged,
    required this.semanticLabel,
    this.onChangeEnd,
    super.key,
  });

  final Color value;

  /// Fires continuously while the square or the strip is dragged, so the
  /// application behind the panel previews it.
  final ValueChanged<Color> onChanged;

  /// Fires once at the end of a gesture, and on every discrete edit — a key, a
  /// committed hex. **This is the one a caller persists**, for the reason
  /// `OaaSlider` gives at length: a value written per pointer event is sixty
  /// writes and sixty frames on a socket for one drag.
  final ValueChanged<Color>? onChangeEnd;

  /// The role being coloured, for the screen reader.
  final String semanticLabel;

  /// The plane, and the strip beside it.
  ///
  /// The plane is **sized rather than stretched**. Handed an `Expanded` it came
  /// out 540 px by 128 in a 620 px panel — a letterbox in which the whole
  /// bottom half of the value axis is four pixels tall, so the difference
  /// between a dark grey and black is a gesture nobody can aim. Three to two is
  /// close enough to the square every other picker uses that the muscle memory
  /// transfers, and it leaves the room beside it for the fields, which is where
  /// they read better anyway.
  static const double _planeWidth = Space.xxxl * 3;
  static const double _planeHeight = Space.xxxl * 2;
  static const double _stripWidth = Space.lg;

  /// One arrow press, as a fraction of the axis. A hundred presses across the
  /// square is why [OaaFocusable.plane] gives shift a ten-times step.
  static const double _step = 0.01;

  @override
  State<OaaColorPicker> createState() => _OaaColorPickerState();
}

class _OaaColorPickerState extends State<OaaColorPicker> {
  late HSVColor _hsv = HSVColor.fromColor(widget.value);

  /// The last colour this picker emitted, so [didUpdateWidget] can tell a
  /// change it caused from one that came from somewhere else.
  Color? _emitted;

  /// Measured where the pointer is handled, not through a `LayoutBuilder` —
  /// which re-runs in the *next* layout pass, so a drag would be sized by the
  /// previous frame. `OaaSlider` documents the same trap at length.
  final GlobalKey _plane = GlobalKey();
  final GlobalKey _strip = GlobalKey();

  /// Owned so that a press can focus the surface it landed on. See
  /// [OaaFocusable.focusNode] — a value somebody has just clicked is a value
  /// they are about to nudge.
  final FocusNode _planeFocus = FocusNode(debugLabel: 'oaa colour plane');
  final FocusNode _stripFocus = FocusNode(debugLabel: 'oaa colour hue');

  late final TextEditingController _hex = TextEditingController(
    text: Skin.formatHex(skinArgb(widget.value)),
  );
  late final FocusNode _hexFocus = FocusNode()..addListener(_onHexFocus);

  @override
  void didUpdateWidget(OaaColorPicker old) {
    super.didUpdateWidget(old);
    if (widget.value == _emitted || widget.value == old.value) return;
    _hsv = HSVColor.fromColor(widget.value);
    _syncHexText();
  }

  @override
  void dispose() {
    _hexFocus
      ..removeListener(_onHexFocus)
      ..dispose();
    _hex.dispose();
    _planeFocus.dispose();
    _stripFocus.dispose();
    super.dispose();
  }

  // --- Emitting -------------------------------------------------------------

  void _emit(HSVColor next, {required bool end}) {
    final color = next.toColor();
    setState(() {
      _hsv = next;
      _emitted = color;
    });
    _syncHexText();
    widget.onChanged(color);
    if (end) widget.onChangeEnd?.call(color);
  }

  void _syncHexText() {
    final text = Skin.formatHex(skinArgb(_hsv.toColor()));
    if (_hex.text == text) return;
    // Assigning `.text` moves the caret to the end, which is right here and
    // would not be if this fired per keystroke — it does not: the field is the
    // only thing that writes while it is being typed into, and it never reads
    // itself back. See [_commitHex].
    _hex.text = text;
  }

  // --- The square -----------------------------------------------------------

  void _planeAt(Offset local, {required bool end}) {
    final size = _plane.currentContext?.size;
    if (size == null || size.width <= 0 || size.height <= 0) return;
    _emit(
      _hsv
          .withSaturation((local.dx / size.width).clamp(0.0, 1.0))
          .withValue((1 - local.dy / size.height).clamp(0.0, 1.0)),
      end: end,
    );
  }

  /// Screen coordinates in, colour space out: `y` grows downwards and value
  /// grows upwards, so exactly one of the two axes is inverted here.
  void _nudgePlane(Offset delta) => _emit(
    _hsv
        .withSaturation(
          (_hsv.saturation + delta.dx * OaaColorPicker._step).clamp(0.0, 1.0),
        )
        .withValue(
          (_hsv.value - delta.dy * OaaColorPicker._step).clamp(0.0, 1.0),
        ),
    // A keystroke is a discrete edit with no gesture around it to be the end
    // of, so every press commits.
    end: true,
  );

  // --- The strip ------------------------------------------------------------

  void _stripAt(Offset local, {required bool end}) {
    final size = _strip.currentContext?.size;
    if (size == null || size.height <= 0) return;
    _emit(
      _hsv.withHue(((local.dy / size.height).clamp(0.0, 1.0)) * 359.999),
      end: end,
    );
  }

  void _nudgeHue(int direction) {
    // Wraps, because hue does. Stopping at 359 would put a dead end in the
    // middle of a continuum and leave magenta unreachable from red by one key.
    final next = (_hsv.hue + direction * 1.0) % 360.0;
    _emit(_hsv.withHue(next), end: true);
  }

  // --- Hex and alpha --------------------------------------------------------

  void _onHexFocus() {
    if (_hexFocus.hasFocus) return;
    _commitHex(_hex.text);
  }

  /// Parsed with the *file format's* parser, so what the editor accepts and
  /// what a skin file accepts cannot drift apart. It takes `#RGB`, `#RRGGBB`,
  /// `#AARRGGBB`, with or without the `#`.
  ///
  /// A value it cannot read puts the field back rather than clearing it or
  /// showing an error: the colour on screen is still the colour, and half a
  /// hex value typed and abandoned is not a thing to be told off about.
  void _commitHex(String text) {
    final parsed = Skin.parseColor(text);
    if (parsed == null) {
      _syncHexText();
      return;
    }
    final color = Color(parsed);
    if (color == _hsv.toColor()) {
      _syncHexText();
      return;
    }
    // Straight from the parsed colour rather than through the current HSV:
    // somebody who pastes a hex means that colour exactly, and re-deriving hue
    // from it is the one place where the round trip is allowed to move.
    _emit(HSVColor.fromColor(color), end: true);
  }

  // --- Build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);
    final alpha = (_hsv.alpha * 255).round();

    return SizedBox(
      height: OaaColorPicker._planeHeight,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: OaaColorPicker._planeWidth,
            child: _buildPlane(colors),
          ),
          // Wider than the usual gap by exactly the crosshair. At full
          // saturation the ring is centred on the plane's right edge and half
          // of it hangs into whatever is next to it — which at [Space.sm] was
          // the hue strip, so the two marks touched.
          const SizedBox(width: Space.smd),
          SizedBox(
            width: OaaColorPicker._stripWidth,
            child: _buildStrip(colors),
          ),
          const SizedBox(width: Space.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _FieldLabel('Hex', color: colors.textMuted),
                const SizedBox(height: Space.xs),
                OaaTextField(
                  controller: _hex,
                  focusNode: _hexFocus,
                  width: _hexWidth,
                  onSubmitted: _commitHex,
                ),
                const SizedBox(height: Space.md),
                Row(
                  children: [
                    _FieldLabel('Opacity', color: colors.textMuted),
                    const Spacer(),
                    Text(
                      '$alpha',
                      style: OaaType.readingSmall.copyWith(
                        color: alpha == 255
                            ? colors.textFaint
                            : colors.textPrimary,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Space.xs),
                OaaSlider(
                  value: alpha.toDouble(),
                  min: 0,
                  max: 255,
                  step: 1,
                  onChanged: (value) =>
                      _emit(_hsv.withAlpha(value / 255.0), end: false),
                  onChangeEnd: (value) =>
                      _emit(_hsv.withAlpha(value / 255.0), end: true),
                  format: (value) => '${value.round()}',
                  semanticLabel: '${widget.semanticLabel} opacity',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlane(OaaColors colors) {
    Widget surface(bool focused) => CustomPaint(
      key: _plane,
      size: Size.infinite,
      painter: _PlanePainter(
        hue: _hsv.hue,
        saturation: _hsv.saturation,
        value: _hsv.value,
        border: focused ? colors.textPrimary : colors.hairline,
      ),
    );

    return OaaFocusable.plane(
      focusNode: _planeFocus,
      onNudge: _nudgePlane,
      valueLabel: _announce(),
      nudgeLabels: (
        left: 'Less saturated',
        right: 'More saturated',
        up: 'Brighter',
        down: 'Darker',
      ),
      semanticLabel: '${widget.semanticLabel} saturation and brightness',
      builder: (context, hovered, focused) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Or a two-finger trackpad gesture over the square sets the colour,
        // with no slop to cross and no button pressed. See [kDragDevices].
        supportedDevices: kDragDevices,
        // Without this the drag begins where it was *recognised* rather than
        // where the pointer went down, so the colour jumps by the pan slop the
        // moment it starts moving.
        dragStartBehavior: DragStartBehavior.down,
        onTapDown: (d) {
          _planeFocus.requestFocus();
          _planeAt(d.localPosition, end: false);
        },
        onTapUp: (d) => _planeAt(d.localPosition, end: true),
        onPanStart: (d) {
          _planeFocus.requestFocus();
          _planeAt(d.localPosition, end: false);
        },
        onPanUpdate: (d) => _planeAt(d.localPosition, end: false),
        onPanEnd: (_) => widget.onChangeEnd?.call(_hsv.toColor()),
        onPanCancel: () => widget.onChangeEnd?.call(_hsv.toColor()),
        child: surface(focused),
      ),
    );
  }

  Widget _buildStrip(OaaColors colors) {
    Widget surface(bool focused) => CustomPaint(
      key: _strip,
      size: Size.infinite,
      painter: _StripPainter(
        hue: _hsv.hue,
        border: focused ? colors.textPrimary : colors.hairline,
      ),
    );

    return OaaFocusable.range(
      focusNode: _stripFocus,
      onIncrease: () => _nudgeHue(1),
      onDecrease: () => _nudgeHue(-1),
      valueLabel: '${_hsv.hue.round()} degrees',
      increasedLabel: '${((_hsv.hue + 1) % 360).round()} degrees',
      decreasedLabel: '${((_hsv.hue - 1) % 360).round()} degrees',
      semanticLabel: '${widget.semanticLabel} hue',
      builder: (context, hovered, focused) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        supportedDevices: kDragDevices,
        dragStartBehavior: DragStartBehavior.down,
        onTapDown: (d) {
          _stripFocus.requestFocus();
          _stripAt(d.localPosition, end: false);
        },
        onTapUp: (d) => _stripAt(d.localPosition, end: true),
        onPanStart: (d) {
          _stripFocus.requestFocus();
          _stripAt(d.localPosition, end: false);
        },
        onPanUpdate: (d) => _stripAt(d.localPosition, end: false),
        onPanEnd: (_) => widget.onChangeEnd?.call(_hsv.toColor()),
        onPanCancel: () => widget.onChangeEnd?.call(_hsv.toColor()),
        child: surface(focused),
      ),
    );
  }

  /// What the square reads out. Percentages rather than the hex, because the
  /// hex is what the *field* below announces and a control that repeats its
  /// neighbour tells a listener nothing about which of the two they are on.
  String _announce() =>
      '${(_hsv.saturation * 100).round()} percent saturated, '
      '${(_hsv.value * 100).round()} percent bright';

  /// `#AARRGGBB` and a caret, in the tabular face every number here is set in.
  static const double _hexWidth = Space.xxxl + Space.xl + Space.sm;
}

/// A word beside a field. Uppercase and tracked out, like every other label in
/// a panel.
class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text, {required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) =>
      Text(text.toUpperCase(), style: OaaType.label.copyWith(color: color));
}

/// The swatch inside a well: a checkerboard where the colour is translucent,
/// the colour over it, and a hairline round the lot.
///
/// The checkerboard is not decoration. Alpha is the one thing about a colour
/// that a solid square cannot show — a 50% white and a solid grey are the same
/// rectangle — and the skin format accepts `#AARRGGBB`, so an editor that drew
/// them alike would let somebody set a translucent `panel` and discover it on
/// the canvas.
class _SwatchPainter extends CustomPainter {
  const _SwatchPainter({
    required this.color,
    required this.border,
    required this.checkerLight,
    required this.checkerDark,
    required this.square,
  });

  final Color color;
  final Color border;
  final Color checkerLight;
  final Color checkerDark;
  final double square;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rounded = RRect.fromRectAndRadius(rect, OaaRadius.xs);

    canvas.save();
    canvas.clipRRect(rounded);

    if (color.a < 1) {
      canvas.drawRect(rect, Paint()..color = checkerLight);
      final dark = Paint()..color = checkerDark;
      for (var y = 0; y * square < size.height; y++) {
        for (var x = y.isEven ? 0 : 1; x * square < size.width; x += 2) {
          canvas.drawRect(
            Rect.fromLTWH(x * square, y * square, square, square),
            dark,
          );
        }
      }
    }

    canvas.drawRect(rect, Paint()..color = color);
    canvas.restore();

    canvas.drawRRect(
      rounded.deflate(OaaStroke.hairline / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = OaaStroke.hairline
        ..color = border,
    );
  }

  @override
  bool shouldRepaint(_SwatchPainter old) =>
      old.color != color ||
      old.border != border ||
      old.checkerLight != checkerLight ||
      old.checkerDark != checkerDark;
}

/// The saturation/value square for one hue.
///
/// White to the hue across, transparent to black down, which is the layout
/// every colour picker has used since Photoshop 3 — and being the one tool
/// that arranges it differently is not a principled stand.
///
/// The shaders are built in `paint` because they depend on the size, and that
/// is affordable here in a way it would not be twenty lines away: this is a
/// panel, and `lib/src/panels/AGENTS.md` is explicit that nothing in one is on
/// the frame path. It repaints while a pointer is down and not otherwise.
class _PlanePainter extends CustomPainter {
  const _PlanePainter({
    required this.hue,
    required this.saturation,
    required this.value,
    required this.border,
  });

  final double hue;
  final double saturation;
  final double value;
  final Color border;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rounded = RRect.fromRectAndRadius(rect, OaaRadius.sm);

    canvas.save();
    canvas.clipRRect(rounded);

    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xFFFFFFFF),
            HSVColor.fromAHSV(1, hue, 1, 1).toColor(),
          ],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xFF000000)],
        ).createShader(rect),
    );
    canvas.restore();

    _crosshair(
      canvas,
      Offset(saturation * size.width, (1 - value) * size.height),
    );

    canvas.drawRRect(
      rounded.deflate(OaaStroke.hairline / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = OaaStroke.hairline
        ..color = border,
    );
  }

  /// A white ring with a black one just outside it, so the mark survives being
  /// drawn over white, over black and over the hue in between. See [_markInk].
  ///
  /// The ring is [OaaStroke.heavy]-adjacent rather than a hairline for the
  /// reason the super meter's target tick is: it is a circle, so antialiasing
  /// spreads it over two pixels in every direction at once, and it crosses the
  /// brightest and the darkest thing in the panel within its own diameter.
  void _crosshair(Canvas canvas, Offset centre) {
    final stroke = Paint()..style = PaintingStyle.stroke;

    canvas
      ..drawCircle(
        centre,
        _ring,
        stroke
          ..strokeWidth = OaaStroke.emphasis * 2
          ..color = _markShadow,
      )
      ..drawCircle(
        centre,
        _ring,
        stroke
          ..strokeWidth = OaaStroke.emphasis
          ..color = _markInk,
      );
  }

  static const double _ring = Space.xs + Space.xxs;

  @override
  bool shouldRepaint(_PlanePainter old) =>
      old.hue != hue ||
      old.saturation != saturation ||
      old.value != value ||
      old.border != border;
}

/// The hue strip: the whole wheel, unrolled top to bottom.
class _StripPainter extends CustomPainter {
  const _StripPainter({required this.hue, required this.border});

  final double hue;
  final Color border;

  /// Six stops and a repeat of the first, because the wheel is a loop and a
  /// gradient is not — without the seventh, magenta at the bottom would run
  /// back to red through a grey nobody asked for.
  static const List<Color> _wheel = [
    Color(0xFFFF0000),
    Color(0xFFFFFF00),
    Color(0xFF00FF00),
    Color(0xFF00FFFF),
    Color(0xFF0000FF),
    Color(0xFFFF00FF),
    Color(0xFFFF0000),
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rounded = RRect.fromRectAndRadius(rect, OaaRadius.sm);

    canvas
      ..save()
      ..clipRRect(rounded)
      ..drawRect(
        rect,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: _wheel,
          ).createShader(rect),
      );

    // Inside the clip, so the marker follows the rounded ends rather than
    // hanging off them.
    final y = (hue / 360.0).clamp(0.0, 1.0) * size.height;
    final marker = Paint()..style = PaintingStyle.stroke;

    canvas
      ..drawLine(
        Offset(0, y),
        Offset(size.width, y),
        marker
          ..strokeWidth = _marker + OaaStroke.emphasis
          ..color = _markShadow,
      )
      ..drawLine(
        Offset(0, y),
        Offset(size.width, y),
        marker
          ..strokeWidth = _marker
          ..color = _markInk,
      )
      ..restore();

    canvas.drawRRect(
      rounded.deflate(OaaStroke.hairline / 2),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = OaaStroke.hairline
        ..color = border,
    );
  }

  static const double _marker = OaaStroke.emphasis;

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.hue != hue || old.border != border;
}
