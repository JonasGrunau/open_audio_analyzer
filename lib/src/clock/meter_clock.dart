// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:oaa_core/oaa_core.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';

/// The one thing in the app that ticks.
///
/// Every meter on screen repaints from this single [Ticker]. Modules do not own
/// tickers, do not own timers, and do not subscribe to streams. There are three
/// reasons, in increasing order of how much they matter:
///
///   1. Thirteen tickers is thirteen callbacks per frame doing the same work.
///   2. Independent tickers drift, so two meters showing the same measurement
///      can show *different* values in the same frame. On a metering tool that
///      is not a cosmetic problem, it is a correctness problem — a user
///      comparing a Number Box against a Super Meter has to be able to trust
///      that they were sampled at the same instant.
///   3. One clock means one place to throttle the frame rate.
///
/// It is a [ChangeNotifier] purely so it can be handed to
/// `CustomPainter(repaint: clock)`. That constructor argument is the crux of
/// the whole render strategy: a painter given a `repaint` listenable is marked
/// dirty and re-rastered **without its widget being rebuilt**. No element
/// visits, no layout, no allocation — just paint. Notifying a
/// `ValueNotifier<Snapshot>` that widgets rebuild from would undo all of it.
class MeterClock extends ChangeNotifier {
  MeterClock({required MeterSource engine, required TickerProvider vsync})
    : _source = engine {
    _ticker = vsync.createTicker(_onTick)..start();
  }

  /// What these ticks read from.
  ///
  /// **Replaceable, because what is being metered can change without the clock
  /// needing to.** The desktop reads a local engine until a plugin connects, and
  /// then it reads the plugin's decoded frames instead; both are a
  /// [MeterSource] and neither is a reason to build a second ticker. Rebuilding
  /// the clock would be: every painter holds it as its `repaint` listenable, and
  /// a painter still mounted for one frame after its notifier was disposed is
  /// replaced by an error box.
  ///
  /// Setting it forgets the generation the previous source had reached, so the
  /// first tick afterwards repaints rather than comparing two unrelated
  /// counters.
  MeterSource get engine => _source;
  MeterSource _source;

  set engine(MeterSource value) {
    if (identical(value, _source)) return;
    _source = value;
    _seenGeneration = -1;
  }

  late final Ticker _ticker;

  Duration _lastPublished = Duration.zero;
  Duration _minimumInterval = _intervalFor(60);

  int _framesPainted = 0;
  int _framesSkipped = 0;

  /// How many times a second the meters are allowed to update.
  ///
  /// 30 exists because it halves GPU load on a laptop running on battery with a
  /// session open all day, which is a real way people use a meter. 120 exists
  /// because the displays do.
  int get targetFps => _targetFps;
  int _targetFps = 60;

  set targetFps(int value) {
    if (value == _targetFps) return;
    _targetFps = value;
    _minimumInterval = _intervalFor(effectiveFps);
  }

  /// The rate to fall back to when the platform asks for reduced motion.
  static const int reducedMotionFps = 30;

  /// Whether the platform's "reduce motion" accessibility preference is set.
  ///
  /// Open Audio Analyzer has no decorative animation to switch off — there is
  /// not one
  /// `AnimationController` in the application — so honouring this preference
  /// cannot mean what it means elsewhere. What moves here is the measurement,
  /// and a meter that stopped moving would not be a calmer meter, it would be
  /// a broken one.
  ///
  /// So the honest response is the one thing that genuinely reduces motion
  /// without inventing or withholding a reading: halve the update rate. The
  /// meters still show everything the engine publishes — [framesSkipped]
  /// already proves most frames carry nothing new — they simply redraw half as
  /// often, which is the same trade the 30 fps setting exists to offer. The
  /// settings panel says so out loud rather than showing a rate that is not
  /// the rate being used.
  bool get reducedMotion => _reducedMotion;
  bool _reducedMotion = false;

  set reducedMotion(bool value) {
    if (value == _reducedMotion) return;
    _reducedMotion = value;
    _minimumInterval = _intervalFor(effectiveFps);
  }

  /// The rate the meters actually redraw at, once the preference is applied.
  ///
  /// A user who has already chosen 30 is left there rather than pushed lower:
  /// the preference is a ceiling, not an override.
  int get effectiveFps => _reducedMotion && _targetFps > reducedMotionFps
      ? reducedMotionFps
      : _targetFps;

  /// Whether audio has been lost since the last reset.
  ///
  /// The one measurement fact that has to reach the *widget* tree rather than
  /// a painter, because it changes what the UI says rather than what a meter
  /// draws. It is a [ValueNotifier] updated only when the value actually
  /// differs, so the warning banner rebuilds on the transition and never on
  /// the sixty frames a second where nothing changed.
  final ValueNotifier<bool> overrun = ValueNotifier<bool>(false);

  /// Frames where the engine had something new. Diagnostics only.
  int get framesPainted => _framesPainted;

  /// Frames where it did not, and the repaint was skipped entirely.
  ///
  /// This number should be *large*. The engine publishes at about 47 Hz and the
  /// display asks at 60 or 120, so most frames genuinely have nothing new to
  /// draw. Skipping them is free and correct; if this ever sits near zero at
  /// 120 fps, something is notifying that should not be.
  int get framesSkipped => _framesSkipped;

  static Duration _intervalFor(int fps) =>
      Duration(microseconds: (1000000 / fps).floor() - 1);

  void _onTick(Duration elapsed) {
    if (elapsed - _lastPublished < _minimumInterval) {
      return;
    }
    _lastPublished = elapsed;

    final engine = _source;

    // The single FFI call on the frame path.
    engine.refresh();

    // Whether there is anything new is decided by comparing generations, not by
    // trusting what `refresh` returned. That looks like a pointless extra field
    // until you notice there can be a second caller: the remote display's host
    // publishes on its own timer, because a `Ticker` stops when the window is
    // occluded and that is exactly when the tablet is the screen being used.
    // `refresh` answers "is this new *to whoever asked*", so with two askers
    // the first one to call consumes the answer and the second is told nothing
    // happened. One of them would then stop repainting — silently, and only on
    // the machines where somebody was using both screens at once.
    if (engine.generation != _seenGeneration) {
      _seenGeneration = engine.generation;
      _framesPainted++;
      if (engine.hasOverrun != overrun.value) {
        overrun.value = engine.hasOverrun;
      }
      notifyListeners();
    } else {
      _framesSkipped++;
    }
  }

  /// Starts at −1, because 0 is a real generation for a source to be at and a
  /// source that published exactly once must still get that frame painted.
  int _seenGeneration = -1;

  @override
  void dispose() {
    _ticker.dispose();
    overrun.dispose();
    super.dispose();
  }
}
