/// A [MeterSource] that plays a plausible programme, for the website's demos.
///
/// SPDX-License-Identifier: GPL-3.0-or-later
///
/// Its own package because two things need it and neither should hold a copy:
/// `module-renderer`, which photographs one module at a time for the catalogue,
/// and `analyzer-demo`, which runs a whole canvas of them live in the browser.
/// Two mocks would eventually disagree about what the programme did, and then
/// the still and the live demo would show different readings for the same
/// material — which is the small version of exactly the problem `MeterSource`
/// exists to prevent.
library;

export 'mock_source.dart';
