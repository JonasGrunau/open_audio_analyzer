# docs/

| File | Contents |
|------|----------|
| `PLAN.md` | The full phased plan, as approved. Update it when the plan changes; do not silently diverge from it. |
| `METRICS.md` | The definition of every published quantity, with its standard. |

`METRICS.md` is not optional documentation. Bel does not implement Decibel's
proprietary `TrueDyn`, and instead publishes `DR-S` / `DR-I` with their formulas
stated so anybody can check them. A metric that appears in the UI without an
entry here is a number nobody can verify.
