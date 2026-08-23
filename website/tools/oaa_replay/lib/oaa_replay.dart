// SPDX-License-Identifier: GPL-3.0-or-later

/// Replaying a recording of the engine measuring a real track.
///
/// `oaa_record` makes the recording, on a machine with the engine on it. This
/// reads one and presents it as a [MeterSource], which is all a meter module
/// has ever been able to see — so the website's canvas shows the engine's own
/// readings of real music without a line of the application changing, and
/// without an engine in the browser.
library;

export 'src/format.dart';
export 'src/recording.dart' show Recording;
export 'src/replay_source.dart';
