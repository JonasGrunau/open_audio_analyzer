// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:oaa_ui/oaa_ui.dart';

import 'pair_link.dart';

/// Whether this build can put a camera on screen at all.
///
/// **A capability, not a preference, and it is asked before the row is drawn.**
/// `mobile_scanner` covers Android, iOS and macOS; there is no Windows or Linux
/// implementation, and on those two every call into it throws
/// `UnimplementedError` from the platform interface. A row that opened onto
/// that would be a feature that exists in the interface and not in the
/// product — so the host picker omits it rather than disabling it, and the
/// typed address it sits above is unchanged and still the thing that always
/// works.
///
/// [defaultTargetPlatform] rather than `Platform.isX`, because this is read
/// from `build` and a widget test may say it is an iPad while running on a Mac.
bool get canScanQrCodes => switch (defaultTargetPlatform) {
  TargetPlatform.android || TargetPlatform.iOS || TargetPlatform.macOS => true,
  _ => false,
};

/// The camera, pointed at somebody else's screen.
///
/// Pushed by [HostPickerPanel] and answering the same question its address
/// field does — where to attach — so it hands back a host and a port through
/// [onConnect] and knows nothing about what the caller does with them. The
/// desktop pushes a display screen; the tablet's display screen connects the
/// client it already has.
///
/// **Everything the camera can refuse to do is a sentence in the panel.** The
/// permission dialog, a denied permission, a machine with no camera and a lens
/// another application is holding are four states that all look identical from
/// here — a preview that never produces a frame — and a scanner that shows a
/// black rectangle while any of them is true is indistinguishable from one that
/// is simply pointed at nothing. The same rule the discovery browser lives
/// under: best-effort is not the same as silent.
class QrScannerPanel extends StatefulWidget {
  const QrScannerPanel({required this.onConnect, this.onClose, super.key});

  /// Called with somewhere to attach to, once a code has been read.
  final void Function(String host, int port) onConnect;

  final VoidCallback? onClose;

  @override
  State<QrScannerPanel> createState() => _QrScannerPanelState();
}

class _QrScannerPanelState extends State<QrScannerPanel> {
  /// Only QR codes, and at most one reading every 250 ms.
  ///
  /// **The format list is not an optimisation — it is what stops the panel
  /// connecting to a barcode.** A studio has printed codes on everything in it,
  /// and a decoder will read a Code 128 asset tag off the side of a preamp in
  /// the same frame as the code somebody is holding up, from the far end of it.
  /// `DetectionSpeed.normal` is the timeout that goes with that: nothing here
  /// needs a reading per frame, and the ones it skips are frames the panel
  /// would have thrown away.
  late final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.normal,
  );

  /// What the last code said, when it was not an address.
  ///
  /// A pointed camera reads whatever is in front of it, and the interesting
  /// failure is the near miss: the Wi-Fi code taped to the wall beside the
  /// desk, or a colleague's calendar invite. Saying *that code is not an Open
  /// Audio Analyzer address* is the difference between a scanner that is
  /// broken and one that is working on the wrong square of the wall.
  String? _rejected;

  /// Set the moment a code is accepted, and never cleared.
  ///
  /// Detection is a stream: the same code arrives every frame for as long as it
  /// is in view, so without this the panel pops itself off the stack once per
  /// frame and pushes the display screen four times.
  bool _connected = false;

  /// The beat between reading a code and acting on it.
  ///
  /// **A scanner that vanishes the instant it reads leaves somebody unsure
  /// whether it read their code**, and on a wall with two codes on it that is a
  /// real question. Long enough for the brackets to turn and the line under the
  /// viewfinder to change, and short enough that nobody is waiting for it.
  static const Duration _acknowledge = Duration(milliseconds: 350);

  Timer? _pending;

  @override
  void dispose() {
    // Cancelled rather than left to `mounted`: the callback pops a route, and a
    // timer that outlives this panel is one holding a `Navigator` it no longer
    // has any business calling.
    _pending?.cancel();
    // Not awaited. `dispose` may not suspend, and the controller's teardown
    // publishes to its own notifier on the way out — the same shape as the
    // discovery browsers, and the same rule: release the resource here, and
    // let anything that wants to announce something do it somewhere it can.
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_connected) return;

    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null) continue;

      final link = PairLink.parse(text);
      if (link != null) {
        setState(() => _connected = true);
        _pending = Timer(
          _acknowledge,
          () => widget.onConnect(link.host, link.port),
        );
        return;
      }

      // Trimmed hard. Some QR codes carry a kilobyte of vCard, and a panel
      // that reprints all of it to say it was the wrong code has made the
      // wrong code the loudest thing on screen.
      final short = text.length > 40 ? '${text.substring(0, 40)}…' : text;
      if (short != _rejected) setState(() => _rejected = short);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = OaaTheme.of(context);

    return PanelScaffold(
      title: 'Scan a QR code',
      onClose: widget.onClose,
      footer: Row(
        children: [
          // The torch is on the left, away from the way out. It is the one
          // control here somebody presses while holding a tablet up at a
          // screen, and a panel's right-hand end is where the button that
          // closes things lives.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) =>
                state.torchState == TorchState.unavailable
                ? const SizedBox.shrink()
                : OaaButton(
                    label: state.torchState == TorchState.on
                        ? 'Torch off'
                        : 'Torch on',
                    onPressed: () => _controller.toggleTorch(),
                  ),
          ),
          const Spacer(),
          OaaButton(
            label: 'Cancel',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PanelSection(
            title: 'Camera',
            ruled: false,
            note:
                'On the machine you want to watch: the code button beside '
                'PUBLISH in its status bar, or Settings → Publish. Point '
                'this at the square it shows.',
            children: [
              // A fixed shape rather than the camera's own. The preview is
              // `BoxFit.cover`, so a 4:3 sensor and a 16:9 one both fill the
              // same box and the reticle inside it stays square — a viewfinder
              // that changes shape with the hardware is a panel that reflows
              // when somebody switches machines.
              AspectRatio(
                aspectRatio: 4 / 3,
                child: ClipRRect(
                  borderRadius: OaaRadius.allSm,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // The same near-black the scrim is, so a preview that
                      // has not started yet is a dark viewfinder rather than a
                      // panel-coloured hole with brackets floating in it.
                      const ColoredBox(color: Color(0xFF0A0C0D)),
                      MobileScanner(
                        controller: _controller,
                        onDetect: _onDetect,
                        fit: BoxFit.cover,
                        // The framework's own error and placeholder states are
                        // Material: a red icon on a black field, and a blank
                        // one. Both are replaced, because a panel that is
                        // `oaa_ui` everywhere except in the two states nobody
                        // designs for is a panel that looks broken exactly when
                        // something has gone wrong.
                        // Both messages are drawn on the viewfinder's black
                        // rather than on the panel, so their colours come from
                        // the same fixed pair the brackets do. `over` is a
                        // saturated red that holds against it; a muted grey
                        // chosen for a panel does not.
                        errorBuilder: (context, error) =>
                            _Message(_describe(error), tone: colors.over),
                        placeholderBuilder: (context) => const _Message(
                          'Starting the camera…',
                          tone: _ReticlePainter.idle,
                        ),
                      ),
                      // Above the preview and below nothing: the reticle is
                      // painted rather than decorated, and its painter refuses
                      // hits, so the tap-to-focus the scanner offers still
                      // reaches the camera underneath it.
                      IgnorePointer(
                        child: CustomPaint(
                          painter: _ReticlePainter(
                            bracket: _connected
                                ? colors.accent
                                : _ReticlePainter.idle,
                            found: _connected,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              if (_connected)
                PanelNote(
                  'Found a pairing code. Connecting…',
                  tone: colors.accent,
                )
              else if (_rejected != null)
                PanelNote(
                  'That code is not an Open Audio Analyzer address — it says '
                  '“$_rejected”.',
                  tone: colors.warn,
                  mark: OaaMark.warning,
                )
              else
                const PanelNote(
                  'Hold the code inside the brackets. It reads on its own; '
                  'there is nothing to press.',
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// The camera's refusals, in words that name what to go and change.
  ///
  /// `MobileScannerException.toString` is `MobileScannerException(permissionDenied)`,
  /// which is a log line and not a sentence — and the one it is most likely to
  /// print is the one a user can actually do something about.
  String _describe(MobileScannerException error) => switch (error.errorCode) {
    MobileScannerErrorCode.permissionDenied => switch (defaultTargetPlatform) {
      TargetPlatform.macOS =>
        'Open Audio Analyzer is not allowed to use the camera. System '
            'Settings → Privacy & Security → Camera.',
      TargetPlatform.iOS =>
        'Open Audio Analyzer is not allowed to use the camera. Settings → '
            'Open Audio Analyzer → Camera.',
      _ =>
        'Open Audio Analyzer is not allowed to use the camera. Grant it in '
            'the system settings, then reopen this panel.',
    },
    MobileScannerErrorCode.unsupported =>
      'This device cannot scan. Close this and type the address instead.',
    _ =>
      'The camera did not start${error.errorDetails?.message == null ? '' : ': ${error.errorDetails!.message}'}. '
          'Close this and type the address instead.',
  };
}

/// One line, centred over the preview's own black.
class _Message extends StatelessWidget {
  const _Message(this.text, {required this.tone});

  final String text;
  final Color tone;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Space.lg),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: OaaType.label.copyWith(color: tone),
      ),
    ),
  );
}

/// The scrim, the window and the four brackets.
///
/// **The window is what tells somebody where to hold the code**, and it is not
/// a crop: the decoder is given the whole frame, because a scan window that
/// rejects a code the camera plainly saw is the most annoying possible way for
/// this to fail. The brackets are an instruction, not a boundary.
///
/// **The scrim and the brackets are fixed rather than taken from the skin, for
/// the same reason [OaaQrCode]'s two colours are.** Every other surface in this
/// application is a colour the palette chose, so a hairline at 3:1 against the
/// panel is 3:1 wherever it is drawn. A camera image is not a surface this
/// application chose: it is a lit studio, a black rack, or somebody's white
/// laptop lid filling the frame, and a bracket in the light skin's
/// [OaaColors.hairlineStrong] over the last of those is invisible at exactly
/// the moment it is being used. Darkening outside the window and drawing the
/// brackets near-white is what a viewfinder does, and it is the only pair that
/// holds against an arbitrary photograph.
///
/// The accent is the exception and it is momentary: the brackets turn to it
/// when a code has been accepted, which is a panel signalling an affirmative
/// action rather than the measurement surface borrowing the in-spec hue.
class _ReticlePainter extends CustomPainter {
  const _ReticlePainter({required this.bracket, required this.found});

  /// Outside the window. Not pure black — a fully black surround against a
  /// bright preview reads as a hole in the panel rather than as a dimmed
  /// margin.
  static const Color scrim = Color(0xCC0A0C0D);

  /// The brackets, while nothing has been read.
  static const Color idle = Color(0xFFE6EAEB);

  final Color bracket;

  /// Thickens the brackets the moment a code is accepted. The panel is about
  /// to close, and the acknowledgement has to land in the frame before it does
  /// — a scanner that simply vanishes leaves somebody unsure whether it read
  /// their code or their neighbour's.
  final bool found;

  @override
  bool? hitTest(Offset position) => false;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide * 0.62;
    final window = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: side,
      height: side,
    );

    // The scrim is everything outside the window, as one even-odd path. Four
    // rectangles round the edge leave hairline seams where they meet, and on a
    // moving camera image those read as scan lines.
    canvas.drawPath(
      Path.combine(
        PathOperation.difference,
        Path()..addRect(Offset.zero & size),
        Path()..addRRect(RRect.fromRectAndRadius(window, OaaRadius.sm)),
      ),
      Paint()..color = scrim,
    );

    final arm = side * 0.22;
    final paint = Paint()
      ..color = bracket
      ..style = PaintingStyle.stroke
      ..strokeWidth = found ? OaaStroke.emphasis : OaaStroke.mark
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    for (final (x, y) in const [(0, 0), (1, 0), (0, 1), (1, 1)]) {
      final ox = x == 0 ? window.left : window.right;
      final oy = y == 0 ? window.top : window.bottom;
      final dx = x == 0 ? arm : -arm;
      final dy = y == 0 ? arm : -arm;
      canvas.drawPath(
        Path()
          ..moveTo(ox, oy + dy)
          ..lineTo(ox, oy)
          ..lineTo(ox + dx, oy),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_ReticlePainter oldDelegate) =>
      oldDelegate.found != found || oldDelegate.bracket != bracket;
}
