// SPDX-License-Identifier: GPL-3.0-or-later

/// Which signal a frequency module reads its bands from.
///
/// The engine transforms every channel and publishes five sets of bands from
/// the front pair. [all] is what the three frequency modules drew before the
/// setting existed and is what they open on: the loudest bin across every
/// channel, which is the worst-case rule the per-channel number boxes use —
/// an average would hide one hot channel, and a hot channel is the thing worth
/// seeing. It is deliberately not called *Sum*, because it is not one, and
/// the metrics reference says exactly which rule it is.
///
/// [mid] is `(L + R) / 2` and [side] is `(L − R) / 2`, so a signal the same in
/// both channels reads its full level on [mid] and nothing on [side], and an
/// anti-phase one the reverse. A source with one channel has a [left] and
/// nothing else to say: [right], [mid] and [side] are unavailable there, and
/// a module asked for one says so rather than drawing the channel twice.
enum SpectrumSource {
  all('all', 'All'),
  left('left', 'Left'),
  right('right', 'Right'),
  mid('mid', 'Mid'),
  side('side', 'Side');

  const SpectrumSource(this.id, this.label);

  /// Stable identifier for presets and the wire protocol. Never change one of
  /// these; add a new source instead.
  final String id;

  /// What the module's menu says.
  final String label;

  static SpectrumSource? fromId(String id) {
    for (final source in SpectrumSource.values) {
      if (source.id == id) return source;
    }
    return null;
  }
}
