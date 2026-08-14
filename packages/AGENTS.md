# packages/

Three local packages, and the boundaries between them are load-bearing rather
than decorative.

| Package | Depends on | License | Why it is separate |
|---------|-----------|---------|--------------------|
| `bel_core` | **nothing** | MIT | Four consumers need the domain vocabulary and three have no engine. The tablet display reads measurements off a socket; the CLI and plugin never draw one. |
| `bel_engine` | `engine/` | MIT | The native library and its bindings, usable without any UI. |
| `bel_ui` | `bel_core` | GPL | Tokens and primitives. Flutter-only, so it cannot go in `bel_core`. |

`bel_core` importing `bel_engine` would make every consumer drag in a native
library most of them never call, and would end `dart test` running without a C
toolchain. The single place the two vocabularies meet is
`lib/src/data/metric_reader.dart`, in the app.
