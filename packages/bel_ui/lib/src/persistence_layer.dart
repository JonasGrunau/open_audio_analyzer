// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// A drawing that survives between frames, held on the GPU.
///
/// Three modules need history rather than an instant: the phase scope's
/// afterglow, the stereo cloud's accumulation, and the spectrogram's scroll.
/// All three work the same way — take last frame's image, draw it back
/// transformed (faded, or offset by one column), add what is new, and keep the
/// result.
///
/// The alternative is keeping the history as data and re-drawing it: four hours
/// of spectrogram is a hundred thousand columns, and a phase scope with a
/// second of trail is fifty thousand points. Both re-rasterise the entire past
/// on every frame to add one column. This keeps the past as pixels, which is
/// what it is.
///
/// ---------------------------------------------------------------------------
/// The disposal rule
///
/// [ui.Image] from `toImageSync` holds a GPU texture, and Dart's garbage
/// collector does not know how large it is — it sees a small handle and feels
/// no pressure to collect it. A module that drops one per frame leaks VRAM
/// steadily until the compositor gives up, on a machine that reports plenty of
/// free memory the whole time. Every image this class creates is disposed the
/// moment it is replaced, and [dispose] must be called from the module's
/// `State.dispose`.
class PersistenceLayer {
  ui.Image? _image;
  int _pixelWidth = 0;
  int _pixelHeight = 0;

  /// The image kept from the last [update]. Null before the first one.
  ui.Image? get image => _image;

  /// Records a frame.
  ///
  /// [draw] is given a canvas in **logical** units — the device pixel ratio is
  /// already applied — and the previous image, which it may draw back faded, or
  /// offset, or ignore entirely to start again. The previous image is disposed
  /// once [draw] returns.
  void update(
    Size size,
    double devicePixelRatio,
    void Function(Canvas canvas, ui.Image? previous) draw,
  ) {
    final width = (size.width * devicePixelRatio).round();
    final height = (size.height * devicePixelRatio).round();
    if (width <= 0 || height <= 0) return;

    // A resize invalidates the history: the old image is the right picture at
    // the wrong scale, and stretching it would leave a visibly blurred band
    // travelling across the display for as long as the trail lasts.
    if (width != _pixelWidth || height != _pixelHeight) {
      _image?.dispose();
      _image = null;
      _pixelWidth = width;
      _pixelHeight = height;
    }

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(devicePixelRatio);
    draw(canvas, _image);

    final picture = recorder.endRecording();
    final next = picture.toImageSync(width, height);
    picture.dispose();

    _image?.dispose();
    _image = next;
  }

  /// Draws the kept image back at logical size.
  void paint(Canvas canvas, Size size, Paint paint) {
    final image = _image;
    if (image == null) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, _pixelWidth.toDouble(), _pixelHeight.toDouble()),
      Offset.zero & size,
      paint,
    );
  }

  /// Draws [previous] back into a recording canvas at logical size, which is
  /// what a fade or a scroll is built on. [offset] shifts it; [opacity] fades
  /// it. Does nothing when there is no history yet.
  void replay(
    Canvas canvas,
    ui.Image? previous,
    Size size,
    Paint paint, {
    Offset offset = Offset.zero,
  }) {
    if (previous == null) return;
    canvas.drawImageRect(
      previous,
      Rect.fromLTWH(0, 0, _pixelWidth.toDouble(), _pixelHeight.toDouble()),
      offset & size,
      paint,
    );
  }

  void dispose() {
    _image?.dispose();
    _image = null;
  }
}
