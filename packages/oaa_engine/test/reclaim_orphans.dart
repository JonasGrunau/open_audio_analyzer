// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `oaa_engine_reset_all` cases, as a program rather than as tests.
//
// Run it after the suite, from this directory:
//
//     dart test && dart run test/reclaim_orphans.dart
//
// `oaa_engine_reset_all` exists for a Flutter hot restart, which re-runs `main`
// in a process that never exited — so nothing disposes the engine the previous
// isolate owned, and it goes on metering (and on macOS goes on owning a Core
// Audio tap) for the life of the process. There is no way to stage a hot
// restart, so what is checked here is the bookkeeping it rests on.
//
// ---------------------------------------------------------------------------
// Why this is a program, and why it is not run *from* a test
//
// **It may not share a process with another suite.** `oaa_engine_reset_all`
// destroys every live engine in the process, and `dart test` runs its VM suites
// as isolates inside one process — two throwaway suites report the same `pid` —
// while four of the six suites here create engines. As an ordinary test it
// reached into whichever sibling was running, freed engines that suite still
// held, and left it calling into freed memory: the Windows engine job failed
// about one run in four with an access violation inside `oaa_engine.dll`, under
// a `GetAndValidateThreadStackBounds failed` because the fault was not on a
// thread that isolate owned. Nothing about it was Windows-specific; that runner
// simply lost the race more often.
//
// **And it may not be spawned from a test either**, which is the second half of
// the lesson and cost a red build of its own. Driving this file with
// `Process.run` from a group in `oaa_engine_test.dart` fixed the race and broke
// Windows outright: `dart run` re-runs the build hooks, which delete and re-copy
// `.dart_tool/lib/oaa_engine.dll`, and the parent `dart test` process has that
// library *loaded*. Windows locks a loaded DLL, so every case died with
// `PathAccessException ... Access is denied, errno = 5` before it measured
// anything. macOS and Linux allow the unlink and showed nothing.
//
// So it runs after the suite, when no process holds the library, which is the
// same shape as `plugin/test/sources_match.sh`: a gate the harness invokes, not
// a test another test starts.
//
// ---------------------------------------------------------------------------
// One process for all three
//
// The order is the point. `nothing-owed` runs first in a process that has
// genuinely done nothing, and each case afterwards leaves the live list empty
// again, so the next one starts from the same place. A case name may be passed
// to run one on its own while debugging.
//
// Exit codes: 0 pass, 1 a case failed (with the reason on stderr), 2 misuse.

import 'dart:io';

import 'package:oaa_engine/oaa_engine.dart';

/// In the order they have to run. Named so the runner and the cases cannot
/// drift apart silently.
const cases = <String>['nothing-owed', 'disposed', 'orphans'];

void main(List<String> args) {
  if (args.length > 1 || (args.isNotEmpty && !cases.contains(args.single))) {
    stderr.writeln('usage: reclaim_orphans.dart [${cases.join('|')}]');
    exit(2);
  }

  for (final name in args.isEmpty ? cases : args) {
    _run(name);
    stdout.writeln('ok: $name');
  }
}

void _run(String name) {
  switch (name) {
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
