# packages/

Four local packages, and the boundaries between them are load-bearing rather
than decorative.

| Package | Depends on | License | Why it is separate |
|---------|-----------|---------|--------------------|
| `oaa_core` | **nothing** | MIT | Four consumers need the domain vocabulary and three have no engine. The tablet display reads measurements off a socket; the CLI and plugin never draw one. |
| `oaa_engine` | `engine/`, `oaa_core` | MIT | The native library and its bindings, usable without any UI. It takes `oaa_core` for `MeterSource` and nothing else — the arrow still points *away* from `dart:ffi`. |
| `oaa_wire` | `oaa_core` | MIT | The remote-display protocol, pure Dart with no I/O. MIT so that a third-party display does not have to be GPL to speak it. |
| `oaa_ui` | `oaa_core` | GPL | Tokens and primitives. Flutter-only, so it cannot go in `oaa_core`. |

`oaa_core` importing `oaa_engine` would make every consumer drag in a native
library most of them never call, and would end `dart test` running without a C
toolchain. The single place the two vocabularies meet is
`lib/src/data/metric_reader.dart`, in the app.
