# module-renderer

Renders the application's fourteen meter modules so the website can photograph them.

Not an application. It has one screen, it takes its instructions from the query string, and its only
consumer is `website/scripts/render-modules.mjs`:

```
?module=spectrum&w=340&h=200&seconds=32&timeBase=20ms
```

| Parameter | |
|---|---|
| `module` | A `ModuleKind` id — `number_box`, `lufs_meter`, `distribution`, `spectrum`, … |
| `w`, `h` | Logical size to draw the module at. Pinned top-left so the caller can clip a known rectangle |
| `columns`, `rows` | Grid cells the module believes it occupies. Defaults to the kind's own defaults |
| `seconds` | Programme to play before freezing. Only the modules that accumulate need more than the default, and the recording's own length is the ceiling |
| anything else | Passed through as a module option — `timeBase`, `metric`, `stereo`, `tilt`, … |

## Why it depends on the whole application

`pubspec.yaml` depends on `oaa` by path and imports `package:oaa/src/canvas/module_host.dart`
directly, rather than holding copies of the modules. That is the entire point. The website used to
draw its own approximations of these meters in JavaScript, and two implementations of one measurement
display drift apart silently — the argument `MeterSource` makes for why the application itself
refuses to write its meters twice, in `packages/oaa_core/lib/src/meter_source.dart`.

Depending on the application drags in the engine, and the engine is a native library reached over
`dart:ffi` — which has no web implementation. It builds anyway, because `dart2js` only compiles what
`main()` can reach, and nothing here reaches `OaaEngine`. `ReplaySource` takes its place: a fourth
`MeterSource` beside the native one and the socket-backed one the tablet uses.

## Where the numbers come from

`web/programme.oaa` and `web/programme.wav`, written by `npm run record` and git-ignored. The
recording is what the **real engine measured** while a real track was pushed through it, on a machine
that has an engine; the WAV is the same seconds of that track. Neither is a simulation, and neither
is generated here — see `website/tools/oaa_record/` and `website/scripts/record.mjs`.

Run `npm run record` before rendering. Without it every photograph says so on its face rather than
coming out as an empty frame, because fourteen pictures of nothing that report success is the failure
that actually happens.

The programme is 45 seconds of a CC BY 3.0 track that is **not in this repository** — it is fetched
by `dart run tool/fetch_test_audio.dart` from the repository root. It masters at about −8 LUFS
against the −14 LUFS streaming target these are shot on, so the Validator has two real failures to
report and the alert meter is genuinely red. That is the material the application is developed
against rather than a demo reel chosen to flatter it.

`ReplaySource` is driven by a frame counter here rather than by a clock — one tick is one recorded
frame — so frame *n* is a pure function of *n* and the images come out the same on a fast machine and
a slow one. At `seconds` it stops advancing, which freezes every meter, and
`globalThis.oaaRenderReady` goes up. The renderer waits for that flag rather than for a delay.

## Running it by hand

```sh
flutter run -d chrome --web-port 4402
# then open http://localhost:4402/?module=spectrogram&w=340&h=200&seconds=44
```

Useful when a thumbnail comes out wrong and you want to see the module rather than the photograph of
it.
