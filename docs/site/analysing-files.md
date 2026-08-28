# Analysing files

Open Audio Analyzer measures a file the same way it measures an input, because
it is the same code: the decoder pushes what it reads through the measurement
path a capture device drives. There is no offline approximation, and a test
holds the two readings against each other on the same samples.

**Nothing is resampled and nothing is remixed.** A file is measured at its own
sample rate and channel count, because a converter in front of a measurement
changes the measurement.

WAV, AIFF, RF64, Wave64, FLAC and MP3.

## In the application

Drop a file on the analysis panel, or open it with **Analyse a file**
(`Ctrl+O` / `⌘O`). Pick a delivery target and the report says, line by line,
what the file measured and whether it passed.

Four ways out of a report:

- **Text**, for a note to yourself.
- **JSON**, for a script.
- **CSV**, for the loudness timeline in a spreadsheet.
- **A PNG report card**, for the message where somebody asks whether the master
  is ready. It is drawn as a fixed layout rather than captured from the panel,
  so it does not inherit a scroll position or a window width — two people
  exporting the same report get the same picture.

A quantity nobody measured is an em dash, a `null` and an empty cell
respectively. Never a zero.

## From the command line

```sh
oaa master.wav                                 # human-readable report
oaa --target streaming-14 master.wav           # …and a delivery verdict
oaa --format json --timeline master.wav        # every measurement, for scripts
oaa --format csv -o loudness.csv master.wav    # the loudness timeline
oaa --list-targets                             # what you can measure against
```

`oaa` needs nothing installed beside it — the executable and the engine as a
shared library — which is what makes it usable inside somebody else's CI.

### The exit code is the point

With `--target`, `oaa` fails a build rather than reporting to a log nobody
reads:

| Exit | Meaning |
| --- | --- |
| `0` | Measured, and every criterion passed. |
| `1` | The file could not be read or decoded. |
| `2` | Measured, and it missed its delivery spec. |

```sh
oaa --target streaming-14 master.wav || exit 1
```

A master that is two loudness units too loud stops the pipeline instead of
shipping.

### Delivery targets

`--list-targets` prints the built-ins. Your own live beside them as JSON in
`calibrations/` under the [configuration
directory](install.html#where-open-audio-analyzer-keeps-your-configuration), and the CLI reads
the same library the application does — so a target you defined once in the
interface is available to a build script by name.

A target that names an `odr_i_min` or an `odr_s_min` adds a line to the verdict
for each: the integrated Open Dynamic Range, which falls as a master is limited
harder, checked against a floor — and the lowest short-term one the programme
reached, its most squeezed three seconds, checked against another.
No platform publishes one, so of the built-ins only **Dynamic master** sets
one — 8 LU on the lowest `ODR-S`, a published recommendation rather than a
platform's requirement, and its note says whose. A house standard writes its
own into its file and the build fails on it like on any other line. The report
states the lowest `ODR-S` whether or not a target asks about it, and prints
the band word of ODR Annex A after `ODR-I` — `(balanced)` — in the text
format alone; the JSON stays numbers.

**Reset**, beside Edit in Settings → Meters, deletes every one of those files
and leaves the built-ins. `--target` naming one it removed exits with
`unknown target`, so a pipeline that names a target of your own stops rather
than measuring against something else.

Point either at a different library with `--config-dir`.

## The two readings agree

If a live reading and an offline reading of the same audio disagree, that is a
bug and not a rounding difference — they share the DSP path by construction.
Comparing them on a known-loudness reference file is part of the release check.
