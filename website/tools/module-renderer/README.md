# module-renderer

Renders the application's fourteen meter modules so the website can photograph them.

Not an application. It has one screen, it takes its instructions from the query string, and its only
consumer is `website/scripts/render-modules.mjs`:

```
?module=spectrum&w=340&h=200&seconds=32&dt=0.03&timeBase=20ms
```

| Parameter | |
|---|---|
| `module` | A `ModuleKind` id — `number_box`, `lufs_meter`, `distribution`, `spectrum`, … |
| `w`, `h` | Logical size to draw the module at. Pinned top-left so the caller can clip a known rectangle |
| `columns`, `rows` | Grid cells the module believes it occupies. Defaults to the kind's own defaults |
| `seconds` | Programme to play before freezing. Only the modules with a time axis need more than the default |
| `dt` | Programme seconds per published measurement |
| anything else | Passed through as a module option — `timeBase`, `metric`, `stereo`, `tilt`, … |

## Why it depends on the whole application

`pubspec.yaml` depends on `oaa` by path and imports `package:oaa/src/canvas/module_host.dart`
directly, rather than holding copies of the modules. That is the entire point. The website used to
draw its own approximations of these meters in JavaScript, and two implementations of one measurement
display drift apart silently — the argument `MeterSource` makes for why the application itself
refuses to write its meters twice, in `packages/oaa_core/lib/src/meter_source.dart`.

Depending on the application drags in the engine, and the engine is a native library reached over
`dart:ffi` — which has no web implementation. It builds anyway, because `dart2js` only compiles what
`main()` can reach, and nothing here reaches `OaaEngine`. `MockSource` takes its place: a third
`MeterSource` beside the native one and the socket-backed one the tablet uses.

## The mock

`MockSource` advances by frame rather than by clock — one `refresh()` is one published measurement
worth `dt` of programme — so frame *n* is a pure function of *n* and the images come out the same on a
fast machine and a slow one. At `captureAt` it stops publishing, which freezes every meter, and
`globalThis.oaaRenderReady` goes up. The renderer waits for that flag rather than for a delay.

Nothing in it is a measurement. It is a plausible shape for one, chosen so each module shows the thing
it exists to show: on the −14 LUFS streaming target, so the meters read in spec and are coloured as
such, but with true peak driven to −0.2 dBTP so the Validator has a real failure to report.

## Running it by hand

```sh
flutter run -d chrome --web-port 4402
# then open http://localhost:4402/?module=spectrogram&w=340&h=200&seconds=24&dt=0.03
```

Useful when a thumbnail comes out wrong and you want to see the module rather than the photograph of
it.
