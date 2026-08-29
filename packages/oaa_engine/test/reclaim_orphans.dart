// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `oaa_engine_reset_all` cases, as a program rather than as tests.
//
// **This file is deliberately not named `*_test.dart`.** `dart test` would pick
// it up, and being picked up is the entire problem — see the `reclaiming
// orphans` group in oaa_engine_test.dart, which runs this instead of doing the
// work itself.
//
// The short version: `oaa_engine_reset_all` destroys *every* live engine in the
// process, `dart test` runs its VM suites as isolates inside one process, and
// four other suites in this directory create engines. So a reset run from a
// suite reaches into whichever of them happens to be running, frees engines
// they still hold, and leaves them dereferencing freed memory. A process of its
// own is not a way of making the test tidier; it is the only arrangement in
// which the test means what it says.
//
// Each case gets a fresh process, so "nothing is owed" is a statement about a
// process that has genuinely done nothing, rather than one that has done
// whatever the case before it did.
//
// Exit codes: 0 pass, 1 a case failed (with the reason on stderr), 2 misuse.

import 'dart:io';

import 'package:oaa_engine/oaa_engine.dart';

/// The case names, so the test and this file cannot drift apart silently.
const cases = <String>['nothing-owed', 'disposed', 'orphans'];

void main(List<String> args) {
  if (args.length != 1 || !cases.contains(args.single)) {
    stderr.writeln('usage: reclaim_orphans.dart <${cases.join('|')}>');
    exit(2);
  }

  switch (args.single) {
    case 'nothing-owed':
      _expect(
        OaaEngine.resetAll(),
        0,
        'a process that made no engine owes none',
      );

    case 'disposed':
      OaaEngine.start(source: OaaSource.silence).dispose();
      _expect(OaaEngine.resetAll(), 0, 'a disposed engine is no longer owed');

    case 'orphans':
      // Deliberately not disposed and deliberately not held: these are the
      // orphans, and `resetAll` is the only thing that may free them. Disposing
      // one afterwards would be the double free the doc comment warns about.
      OaaEngine.start(source: OaaSource.silence);
      OaaEngine.start(source: OaaSource.testTone);

      _expect(OaaEngine.resetAll(), 2, 'both orphans are reclaimed');
      _expect(OaaEngine.resetAll(), 0, 'and reclaimed exactly once');
  }
}

void _expect(int actual, int expected, String what) {
  if (actual != expected) {
    stderr.writeln('$what: expected $expected, got $actual');
    exit(1);
  }
}
