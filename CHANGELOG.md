# Changelog

All notable changes to Open Audio Analyzer are recorded here. The format is
defined in [CLAUDE.md](CLAUDE.md#changelogmd-format); the short version is that
**📐 Measurement always comes first**, because a change to a reported number can
invalidate a decision somebody already made about a master.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### ✨ Added
- **An AAX build for Pro Tools.** The plugin now builds a fourth format on macOS
  and Windows, universal on macOS and targeting 14.2 like the other bundles, and
  it ships in the `oaa-plugin-<platform>` release archive. **It is not signed
  for Pro Tools**: an AAX bundle needs a signature from PACE's `wraptool` made
  against an Avid developer account holding a signing certificate, which is a
  different thing from the code signature every bundle already carries and which
  this project does not have yet. Unsigned, it loads in a Developer build of Pro
  Tools and in Avid's developer tools and nowhere else, and a released Pro Tools
  refuses it by simply not listing it. That is why no installer carries it — a
  ticked checkbox that installs something no DAW will show you is worse than no
  checkbox. The bundle passes Avid's own AAX Validator: it describes itself,
  its Describe function validates, every effect instantiates and de-instantiates
  under every host context, and it survives a thousand load/unload cycles.
- The website has a page at `/alternatives/decibel` for readers arriving from a
  search for a free alternative to Decibel by Process.Audio. It states what the
  two share, the four differences there is published evidence for, and the
  repository's Known gaps rather than a softened version of them. The claim that
  this project reimplements Decibel's ideas has been in `README.md` since the
  first commit and was on no page of the site.
- The website has an Impressum at `/impressum` — the provider identification
  § 5 DDG requires of a German site: name, postal address, telephone, email, and
  who is responsible for the content under § 18 Abs. 2 MStV. German first,
  because that is the word a German reader looks for in a footer, with an
  English translation under it. Both footers link it as "Legal Notice
  (Impressum)" — the English for a site written in English, and the German word
  because that is the one § 5's recognisability is judged by — and it is in the
  sitemap.

### 🐛 Fixed
- **The privacy policy was 128 px wider than a phone screen.** The address to
  report a privacy question to is printed as a link whose text is the URL, and
  a 57-character word has no break opportunity in it — so on a 390 px phone it
  laid out at its own width and pushed the document sideways. Nothing scrolled,
  because the page cannot scroll sideways, so what a reader saw instead was a
  page 128 px narrower than the window from the header down, with every heading
  and every paragraph short of the right edge. Long links now break.
- **Every page carrying the one-line footer was 37 px wider than a 360 px
  phone**, for the same reason and on a smaller scale: the row of five links in
  it did not wrap. Small enough to look like nothing, and on every documentation
  page, which is the combination that makes a bug read as the design.
- **`npm run check` reported every page clean while three of them overflowed.**
  It opened each page in an emulated *mobile* viewport, and mobile emulation
  scales a too-wide document down until it fits — so the width the page reported
  was the width of its own content and the check compared a quantity with
  itself. It now measures at the width it asked for, and fails outright if that
  is not the width the page got.
- **The oscilloscope on the website draws a continuous waveform.** It drew a
  comb — half a beat of trace, a gap the same width, over and over — on both
  the front page's still and the live analyzer behind it. The recording is not
  at fault and carries no audio: the browser replays the engine's readings and
  reads the waveform out of the track it is already playing, and it was handing
  the module one 1,024-sample block for every 2,205 samples the clock said had
  gone past. The module is right to draw the shortfall as blank columns —
  audio that was measured and lost is not a straight line — so the fix is the
  window, which is now the four blocks the interface allows for and covers any
  cadence down to eleven frames a second. The waveform also no longer runs nine
  per cent fast on a machine whose audio output is not at the track's sample
  rate: both web targets now decode at the recording's rate, and where a
  browser refuses that, the window is stepped into the reading's time base
  instead. Nothing the application, the CLI or the plugin measures is affected
  — this is the website's replay source alone, and it now has a test.
- **The website's Modules section told readers to drag a meter onto the
  canvas**, which is not a gesture Open Audio Analyzer has or has ever had:
  there is no palette to drag a meter from, and dragging on the canvas moves a
  module that is already placed. It now names the ones that exist — right click
  the canvas, or long press it on a tablet — which is what `README.md` has said
  since the first release, so the first instruction on the page can be followed.
  The credit under the front page's live analyzer also says what that canvas is:
  one measured pass of the track, replayed on a fixed eight, and not the canvas
  the section two screens below is about. (#4)
- **The plugin told every DAW it was 0.11.0.** The VST3, the Audio Unit and the
  AAX have all declared that version since 0.12.0 — in each bundle's version
  field and in the VST3's `moduleinfo.json` — while the installer that carried
  them put the real version on the application, so a host listed a plugin four
  releases behind the program it streams to. The bundles were built from the
  right commit every time and nothing they measure was affected; the number was
  a literal in `plugin/CMakeLists.txt` that a release commit was expected to
  bump, and after 0.11.0 nothing did. It is now read from `pubspec.yaml`, and
  the macOS package refuses to build if a plugin bundle's version is not the one
  on the box — which is also what catches a stale build tree. A DAW that still
  shows 0.11.0 after this release has cached the old bundle, or is loading a
  copy from `~/Library/Audio/Plug-Ins`, which no installer here writes to or can
  remove.
- **GNOME Software and KDE Discover offered 0.11.0.** The flatpak's AppStream
  metadata lists a row per release and its newest row is the version a software
  centre prints; it stopped being written after 0.11.0, so four releases
  installed while the store beside them described the one before them. Every
  release through 0.15.0 is listed now.

### 🚧 Internal
- **The Windows engine job no longer fails about one run in four.** The
  `reclaiming orphans` tests called `oaa_engine_reset_all`, which destroys every
  live engine in the *process* — and `dart test` runs its suites as isolates
  inside one process, four of which create engines. So the reset reached into
  whichever sibling suite was running and freed engines it still held, and the
  job died with an access violation inside the engine library. The three cases
  now run as a program in a process of their own. Nothing the engine does was
  wrong and no measurement changes; the test was.
- `website/tools/oaa_replay` has a test suite, run by the `checks` job. That
  package is not a workspace member, so `flutter analyze` never reached it and
  the only thing that read it at all was `dart format`.

## [0.15.0] — 2026-08-29

### 📐 Measurement
- **`Correlation` and `Balance` are now gated at −70 LUFS and read as a dash
  under it, where they read `0` before.** Both divide by the two channels'
  energy, so with nothing there they are `0/0` and `0` was a reading nobody
  took. Correlation was the visible half: its 200 ms smoother approaches a
  target asymptotically and never arrives, so a substituted `0` left the
  published value carrying the *sign* of the last audio for as long as the
  silence lasted. A track that fades out on a wide reverb tail ends slightly
  out of phase, and the Phase Scope then held its correlation marker off centre
  and lit it in the warning colour — asserting anti-phase content in a signal
  that had stopped — for the twenty-odd seconds the exponential took to
  underflow. The line is R128's own absolute gate, per channel: correlation
  needs both channels above it and balance needs either, so a hard-panned
  source now reports a balance and no correlation. A gate rather than a guard
  against dividing by zero, because a live input is never exactly zero — it
  sits on a converter's noise floor, whose correlation is a random number near
  zero whose sign falls whichever way the block did, and an idle desk reported
  those as readings. An offline report's correlation range and mean now
  describe the programme rather than the file: a master with silence or room
  tone at either end no longer reports a minimum of `0.00` it never reached,
  and its mean is no longer pulled towards zero by however much of the file is
  lead-in and tail. An Alert Meter on either metric no longer latches silence.
  Re-run a report for the corrected range and mean; nothing about the audio
  itself changed, no reading above the gate moved, and a mono source still
  reports `+1` and `0`, which is true rather than substituted.
- **A true-peak ceiling is no longer passed by silence.** True peak max is a
  running maximum, so unlike the gated readings it carries a number from the
  first block — the −144 dB floor every level is clamped to — and that number
  satisfies every ceiling a target states. Both places a verdict is given said
  so: the Validator printed `-144.0 … PASS` for an idle input, the one green
  line on a table whose every other row was still waiting, and the delivery
  report's true-peak check passed for a file with no programme in it. A true
  peak at the floor now reads as not measured in both. **No measured value
  changes and no verdict changes where a programme exists** — anything above
  the −70 LUFS gate puts true peak above the floor — so this can only turn a
  vacuous pass into a dash, and no re-measure is warranted. `oaa`'s exit code
  is unaffected: a file with nothing in it already failed to be compliant on
  `LUFS-I`.
- **An Alert Meter on `Crest` now holds the most squashed block of a session
  rather than the most open one.** Crest is sample peak minus RMS, so a high
  reading is a dynamic passage and a low one is a limited passage — and the
  module held the maximum, printing the best moment of a programme as the
  worst of it. The same defect the two dynamics ratios had through 0.14.0.
  `Balance` is now held by distance from centre rather than by signed value,
  so a mix pulled hard left registers where before only a right-leaning one
  could. Neither metric is judged against a target, so neither reading was
  ever coloured — what changes is which number is held, by however far the
  session swung.
- **An Alert Meter on `ODR-I`, `LUFS-I`, `LRA`, `TP Max` or `Peak Max` now
  prints what the engine holds, rather than the most extreme value that
  reading passed through.** Those five are accumulated over the programme
  since the last reset, and three of them converge rather than climb — so the
  module was latching an artefact of the first seconds. `ODR-I` is
  `TP Max − LUFS-I`, and integrated loudness clears the −70 LUFS absolute gate
  while a track is still room tone: on a 322-second master whose `ODR-I` is
  8.6 LU, the reading swung between 33.5 and 7.6 inside the first second and
  the module then printed **7.6 LU** for the remaining five minutes —
  disagreeing with the Number Box beside it, with the Validator and with the
  delivery report, and lit red under a floor the programme cleared. `LUFS-I`
  had the same failure on any programme that starts louder than it ends.
  Readings on those five change by however far the swing went; nothing else
  in the application reported them and no re-measure is warranted. The nine
  metrics measured moment by moment — momentary and short-term loudness, the
  live true peak, `ODR-S`, crest, correlation, balance and the two per-channel
  levels — still latch their worst, which is what the module is for.
- **The two dynamics readings are Open Dynamic Range: `ODR-S` and `ODR-I`.**
  They were `PSR` and `PLR`, and also `DR-S` and `DR-I` — four names for two
  numbers. The arithmetic is unchanged and every reading that was defined
  before reads the same number now; what is new is the name and the written
  standard behind it, in `docs/METRICS.md` and the README, which pins every
  operand the AES note leaves open. A preset with a Number Box or an Alert
  Meter on any of the four old ids opens on the same reading under its current
  name; the JSON report carries `odr_i` where it carried `plr`.
- **`ODR-S` is undefined in silence and below the −70 LUFS absolute gate, rather
  than a number.** It read 0.0 LU for digital silence — true peak and
  short-term loudness both floor at −144 dB, and a subtraction of two floors is
  zero — and about 8 LU for a noise floor at −90 dBFS: a dynamics figure for a
  passage with no programme in it. It now reads as a dash there, on the same
  line below which `LUFS-I` is not defined, and is unchanged by any amount
  above the gate — a reading that was defined before reads the same number
  now. No re-measure is warranted; a Number Box or Alert Meter watching `ODR-S`
  through a silent gap shows a dash where it showed `0.0`, and nothing else
  changes. `ODR-I` is unaffected, having always been undefined for as long as
  `LUFS-I` is.
- The two dynamics readings are held in CI. A stereo 1 kHz sine reads an
  `ODR-S` and an `ODR-I` of 0.0 LU and the same tone in mono reads 3.01; the
  numerator is
  asserted to be true peak, against a signal whose every sample sits 3 dB under
  its own waveform; and silence and a −80 dBFS tone read as undefined. The
  definition, operand by operand, is now in `docs/METRICS.md` and the README.
- **The spectrum is measured on five signals.** Beside the combined bands —
  the loudest bin across every channel, unchanged — the engine publishes the
  front pair's `Left`, `Right`, `Mid` `(L + R) / 2` and `Side` `(L − R) / 2`
  spectra, each with its own peak hold, and holds them against sines of known
  amplitude: a hard-left sine reads its full level on Left, −6.02 dB on Mid
  and on Side and the floor on Right; an in-phase one its full level on Mid
  and the floor on Side; an anti-phase one the reverse. On a one-channel
  source Right, Mid and Side are not measured rather than reported as the
  channel twice. Nothing previously reported changes.
- **The Histogram records a column every 50 ms, where it recorded one every
  100 ms.** Its short-term line is unchanged to within the width of the stroke
  — a 3 s window does not move in 50 ms — but its momentary band is a maximum
  *over the column*, so a shorter column can only lower it: the band's top now
  reads up to a few tenths of an LU below where it did on transient material,
  and exactly where it did on steady material. The reading it is drawn from is
  unchanged, and no re-measure is warranted; what changed is how finely the
  module samples it, which is what makes zooming in show anything.
- **`LUFS-M` and `LUFS-S` are clamped at the −144 dB floor, which they were
  not.** Both floored their reading by testing it against −infinity, which is
  what an energy of *exactly* zero produces and nothing else does. A window
  that has just emptied holds something else: the K-weighting filters ring on
  after the signal stops, so a window carrying nothing but that tail has an
  energy of around 1e-90, and it was published faithfully as −1,860 LUFS. The
  reading then fell further for as long as the ringing took to age out of the
  window, and jumped back up to −144.0 at the moment the last of it left — a
  second later for momentary, three for short-term. Those figures reached the
  wire and the JSON report as well as the meters. Both readings now clamp the
  way every other dB quantity in the engine already did. **Nothing audible is
  affected**: the excursion starts below −144 LUFS and only in the seconds
  after a signal stops, so no reading of programme material moves and no
  re-measure is warranted.
- **The Spectrogram records every published measurement.** One column is one
  publish, but the record advanced when the module was *repainted*, and
  repaints are throttled to the meter frame rate — so at 30 fps, and under the
  platform's reduce-motion preference, one publish in three never reached the
  record at all and a transient that fell in a skipped one was simply absent
  from the picture. The record is now advanced from the unthrottled
  measurement, so the display is the same at 30, 60 and 120 fps and holds
  every band the engine published. Nothing about how a level is measured or
  coloured changed; what changed is how much of the signal reaches the
  display.

### ✨ Added
- **The Spectrum Analyzer has a cursor.** Click or tap anywhere on the plot and a
  line stands at that frequency with a tag beside it: the frequency, the level
  there, its peak hold, and the level in dB(A). Drag the line to move it; tap
  it, or click anywhere away from the module, to dismiss it. The two levels are
  read off the curve and the hold at that band
  — the lines the cursor crosses — and are the measured values, untilted, so
  under a `Tilt` the tag reads the true level where the axis cannot. dB(A) is
  the band's level plus the IEC 61672-1 A-weighting curve at its centre
  frequency, which is exact for a single band and is the one weighted reading
  in the application; the curve itself stays unweighted. A right click on the
  plot is still the module's menu, and a click still selects the module.
- **The Oscilloscope's overlaid channels can be swapped front to back.** Two
  traces around one centre line hide one another wherever they cross, and the
  right channel was always the dimmed one behind — so it was the one you could
  not read. The `L R` legend is now the control: it sits at the left of the
  slider row, names the front channel first and in the brighter ink, and
  clicking it puts the other one in front. It is remembered in the layout.
- **The Histogram scrolls and zooms.** The overview strip along its floor was a
  map of the recording; it is now the control as well. Drag the frame on it and
  the plot scrolls back through the programme — it keeps recording while you
  look, and dragging the frame back against the right-hand edge re-attaches it
  to the newest reading. Scroll, pinch or wheel over the strip — a trackpad, a
  Magic Mouse and a click-wheel mouse all reach it — and the frame resizes,
  which is the plot's zoom: anything from five seconds across the module to the
  whole seven minutes the ring holds.
- **A Validator chooses which criteria it judges.** `Checks` in its menu, one
  row per delivery criterion, ticked and unticked in a menu that **stays open**
  — every other menu in the application closes on the tap that chooses, and
  choosing four of five that way is four trips through a right click. A
  criterion switched off leaves the verdict as well as the table, which is the
  point: a NOT READY that is really "the LRA of a podcast is 4 LU" is a red
  light people learn to ignore. A module with nothing left to check says
  NOTHING CHECKED rather than READY TO DELIVER. Existing presets are unchanged
  — a Validator that has never been told otherwise checks everything the target
  states — and a dynamics floor the target does not set is greyed in the menu
  rather than dropped from it.
- **The Alert Meter chooses what it watches.** `Metric` in its menu, the row a
  Number Box has always had: the three readings a delivery is decided by are
  LUFS-I, LRA and true peak max, and any of the fourteen metrics works. The
  metric was stored in the preset, read and drawn the whole time — there was
  nowhere to choose it, so every Alert Meter ever placed watched true peak.
- **The Alert Meter can print the distance from the target instead of the
  reading.** `Delta` in its menu: `+0.6` where the module showed `−0.4 dBTP`
  against a −1.0 ceiling, signed so that positive is always above the line
  whichever way the comparison runs, and in the unit of the difference — `dB`
  from a peak ceiling, `LU` from a loudness target. The latch and the colours
  are decided from the measurement either way, so a module in delta turns red
  at the same moment and agrees with the one beside it that is not. A metric
  the target draws no line for — and an `ODR` floor this target does not state
  — reads as a dash rather than as a distance from nothing.
- **A delivery target can set an `ODR-I` floor and an `ODR-S` floor.** `odr_i_min` and
  `odr_s_min` in the target's file, or the two rows of the editor's new Dynamics
  section — the limits that run the other way, and the ones no platform
  publishes; of the built-ins only Dynamic master carries one. Each floor
  the target sets adds a line to the Validator, the report, the report card
  and the `oaa` verdict, and a master limited past one fails a build the way
  one over its peak ceiling does. The `ODR-S` line is judged against the
  **lowest** `ODR-S` of the programme — the most squeezed three seconds — which
  is the check `ODR-I` cannot make, because one transient in a quiet intro
  rescues a flattened chorus. The Validator keeps that minimum since the last
  reset.
- **The Open Dynamic Range specification**, `docs/ODR.md`, published at
  `open-audio-analyzer.com/docs/odr`: the two readings defined to the operand
  — the peak, the window, the gate, the minimum, the display — with seven
  conformance cases, every one a generated signal with a stated tolerance, and
  a table of what ODR is and is not beside the AES ratios, TrueDyn, DR, LRA and
  crest. Normative and versioned; its text is CC BY 4.0 so another product's
  documentation may reproduce it.
- **The specification says what a reading means.** Annex A, informative: the
  identity that a normalised master's true peak is the platform's target plus
  its `ODR-I`, the bands from flat to wide with an arithmetic anchor on every
  row, the published 8 LU floor for the minimum `ODR-S`, and why the TT `DR`
  scale's thresholds do not transfer. Kept apart from the definition so the
  guidance can be revised without a version bump. The bands are also in the
  README's ODR section and, drawn to scale, under the website's Dynamics
  section.
- **Dynamic master is a seventh built-in delivery target** — the streaming
  target's loudness and peak lines plus the one floor with a published source:
  8 LU on the minimum `ODR-S`, Ian Shepherd's recommendation for the loudest
  passage in any genre. The one built-in that is a recommendation rather than
  a platform, and its note says so.
- **The text report prints `ODR-I`'s band word after the reading** —
  `12.8 LU  (balanced)` — the bands of ODR Annex A, flat to wide, in the app's
  export and the CLI's alike. The word appears in the human format alone; the
  JSON stays numbers, so nothing a script gates on changed.
- **A file report states the lowest `ODR-S` reached**, where it was defined, as
  its `ODR-S` line and as `odr_s_min` in the JSON — beside `ODR-I`, which is one
  peak against the whole programme.
- The Super Meter prints `ODR-I` under its LRA readout, in the verdict's colour
  when the target has a floor.
- **A connected DAW plugin is an entry in the source picker**, named after the
  host it is running in — `DAW plugin — Logic Pro` — in the status bar's menu
  and in Settings › Signal. Several inserts are several rows. The selection is
  remembered between launches, so a machine that meters a DAW every day opens
  ready for one.
- **The Spectrum Analyzer and the Spectrogram have a `Source` setting** — All,
  Left, Right, Mid or Side — as the first row of their menus. It is part of
  the module, so it is saved with the preset and a tablet shows the host's
  choice; changing the spectrogram's clears its record, because a picture
  that is one signal on the left and another on the right is a measurement
  nobody took. A source the signal cannot provide says **MONO SOURCE**.
- **The Spectrum Analyzer has a `Range` setting** — 60, 90 or 120 dB below
  full scale, 90 by default, the values and the default Pro-Q uses — as the
  last row of its menu. The dB axis is linear over the chosen range, labelled
  every 6, 10 or 12 dB, and the range is printed in the plot's top-right
  corner, opposite the tilt.

### ⚡ Changed
- **Clicking anywhere outside the selected module clears the selection.** Only a
  click on empty canvas did, and only on the release; a click on the menu bar,
  the tab strip or the status bar left the module outlined, because nothing on
  the canvas could see it. The selection now lets go on the *press*, wherever
  it lands — empty canvas, the bars, another module — with one exception: a
  module's own menu, and any panel standing open, are not "elsewhere", so
  choosing an option for a module leaves it selected, and the click that closes
  its menu does too.
- **A level standing at the dB floor now reads `-∞` rather than `-144.0`.**
  Every dB level is clamped to −144 before it leaves the engine, so that is a
  sentinel and not a reading: printed to four significant figures it was
  precise, plausible and measured by nobody, and it disagreed on screen with
  the meter beside it, whose scale labels that same end `-∞` already. Every
  level readout in the application changes together — the Number Boxes, the
  LUFS Meter, the Digital Meter's peak and RMS rows, the Super Meter's centre,
  the Validator's table and the `oaa` text report — because all of them format
  through one function. Ranges and differences are untouched: `LRA`, `Crest`,
  `ODR-S` and `ODR-I` are subtractions of two levels and never reach the
  clamp. Silence is a measurement, so it is `-∞` and not the em dash that
  marks a quantity nobody measured. The snapshot, the wire protocol and the
  JSON report still carry −144.0.
- **The Super Meter's three centre sections stand apart.** The short-term pair,
  the integrated pair and the true peak were packed at a fixed eight pixels
  while the lower part of the dial's clear disc stood empty, because the stack
  is sized by the width a row has to fit across and the height it did not need
  simply went unspent. It is divided between the two gaps now. The figures are
  the size they always were, and on a small module the ceiling's printed value
  yields to the true peak row rather than crowd it — the red zone and its tick
  still mark where the ceiling is.
- **The Loudness Distribution prints its LRA in the caliper's grey rather than
  in the accent.** The number sits between the two marks of the dimension line
  that measures it, and in the signal hue it read as a separate label that
  happened to be collinear with them rather than as part of the annotation.
  The reading is unchanged; only its ink is.
- **The Super Meter's dynamics arcs end in nothing.** `ODR-S` and `ODR-I` each
  ran into a grey radial tick at the true peak, which put a third mark on a
  dial whose other two — the target and the ceiling — are values somebody set.
  Where the arc stops still says where the peak stands, and the number itself
  is printed in the centre.
- **The LUFS Meter's overshoot is the same solid as the bar under it.** The
  stretch standing above the delivery target was flat paint laid over a bar
  that is modelled across its width, so it read as a cap sitting on the meter
  rather than as the top of the reading. It now carries that same modelling in
  the same red: a bar crossing the target changes colour and nothing else.
- **A new Alert Meter watches the live true peak rather than `TP Max`.** Both
  print the same number — the largest three-second peak of a session is that
  session's peak — but only one of them is the module doing its job: `TP Max`
  is held by the engine, so an Alert Meter on it read rather than latched, and
  the module shipped with the one behaviour it exists for switched off. The
  name above the digits reads `TRUE PEAK` where it read `TP MAX`. An Alert
  Meter already on the canvas, or in a saved preset, keeps the metric it was
  given.
- **The Oscilloscope's time base and overlaid legend moved onto the control
  row.** Both were printed over the corners of the waveform. The legend is now
  at the left of the row, ahead of the height slider, and the time base at its
  right-hand end, under the axis it measures. A module too narrow to hold both
  beside the sliders, and a tablet showing a remote canvas, draw them in the
  corners as before; the lane letters are unchanged, because a lane's letter
  belongs in its lane.
- **Every number a module prints is the signal hue.** Readings were white —
  the same ink as a menu label, a panel's body text and the module's own title
  — so the one thing a meter exists to show was the colour of the chrome
  around it. A value now carries the accent whether or not a target applies to
  it, and the palette's other colours say what is *wrong* with one: amber
  approaching a limit, red past it, a muted em dash for a quantity nobody
  measured. The Digital Meter's peak and RMS rows, the VU Meter's readout, the
  LUFS Meter's momentary and short-term values, the Loudness Distribution's
  LRA, the Number Box, the Alert Meter, the Super Meter's centre and the
  Validator's table all move together; nothing on a module borrows the hue
  that is not a measurement. One consequence worth knowing: a reading under
  its target and a reading in spec are now the same colour, and the verdict is
  the Validator's, the Alert Meter's and the delivery report's to state in
  words.
- **The Validator colours a row by its own verdict.** The measured value and
  the Δ beside it take the accent when the row passes, the over colour when it
  fails, and the muted dash while the measurement is still undefined — so the
  table can be read at a glance rather than only when something is wrong.
- **Every module's panel is lit from its top-left corner**, the way Decibel's
  are: a soft highlight, brightest in the corner behind the title and fading
  back to the panel colour four fifths of the way across and down. The panel
  was one flat colour. Skins carry it with no new colour role — the light is
  the skin's own panel colour lifted — and a light skin, whose panel is already
  near white, is barely lit at all.
- **The Histogram's time axis is elapsed time — `45s`, `1m15s` — where it was
  the wall-clock time a column was recorded at.** A clock is only right while
  the plot is pinned to the newest column: now that it scrolls, one counting
  back from the present would label a chorus four minutes ago with the time you
  are looking at it. The gridlines are pinned to the programme rather than to
  the edge of the plot, so they slide with the material instead of renumbering
  themselves.
- **The Histogram's momentary band is drawn at a weight you can see.** It was
  0.05 to 0.26 alpha under a fill that reaches 0.85, which put the gap between
  the two bands — the whole reading — below the noise floor of the display it
  was drawn on. The short-term edge is still the strongest line on the module.
- **The Histogram's overview strip sits a full gutter below the plot** rather
  than four pixels, and the frame on it is filled as well as outlined, so it
  reads as something to grab rather than as the plot's own bottom margin.
- **The Alert Meter's reading is labelled with the metric's own name.** It read
  `WORST TP MAX`, which labelled the only thing the module does — the title bar
  above it already says which module this is, and the digits and the panel's
  light are now one held verdict, so nothing on the tile reads as a live value
  for the word to correct.
- **The Alert Meter's panel is washed in light off its left edge, in the colour
  of the worst reading it has caught.** It replaces a two-pixel rule down that
  edge — the same statement in a hundredth of the area, a gutter inside the
  panel's own edge, on the one module built to be read from across a room and
  out of the corner of an eye. It is the Number Box's glow turned on its side,
  and one shader draws both. The light and the digits are **one verdict in two
  sizes**: both are decided from the latch, both are cleared by the engine's
  reset and by any setting that changes what the module is showing, so a red
  panel across the room and the number on it can never disagree. A module that
  has caught nothing is not lit at all.
- **A Number Box and an Alert Meter with no reading are no longer lit.** The
  wash under the digits is a verdict on a number, and an em dash — nothing
  measured yet, a link gone quiet, a quantity this build does not compute — has
  none. It glowed in the accent, which is the colour that means "measured, and
  nothing says it is wrong", so a module that had measured nothing at all
  looked like one that was fine.
- **The Validator's Δ is printed at the size of the number it marks** rather
  than at a graticule tick's, which read as a superscript on the reading to its
  left instead of as the label of the one to its right.
- **The Alert Meter shows the worst reading and no longer the live one.** The
  big number was the live value with the latch a small line beneath it, which
  made this a Number Box carrying a footnote — and the canvas already has a
  Number Box that says the live value better. The latch is now the module's one
  number, at the size the live one had, under the metric's own name — and the
  panel's light is that same held verdict, so nothing on the module reads as
  live. Nothing stopped being measured: the live reading is read every frame and it is what the latch is
  taken from. It is simply no longer what the module prints.
- **The Alert Meter prints the unit after its reading**, and sets its label in
  the grey the Number Box uses for its own name and unit rather than in the
  fainter one a graticule tick gets. In `Delta` the unit is the
  **difference's** — `+0.8 dB` under a dBTP ceiling, `−0.6 LU` from a loudness
  target — because the reference cancels in a subtraction and `+0.8 dBTP` would
  name a clipped master rather than eight tenths of a decibel over the line.
- **A source can be changed while a plugin is connected.** A plugin used to take
  the canvas for as long as it was connected, which left every input on the
  machine unreachable until it was removed from the DAW — the app asked the link
  what it was showing rather than asking the selection. The first plugin to
  connect still selects itself, because inserting it is the act of choosing it;
  a second insert no longer takes the canvas off a source somebody has chosen,
  and neither does re-instantiating one.
- **Choosing a DAW releases the capture device.** Nothing local is being metered
  while a plugin is on the canvas, and the microphone stayed open behind it —
  a recording indicator lit on the machine's own menu bar for a window showing
  a DAW.
- The DAW plugin chosen with none connected reads as dashes rather than as a
  measured silence, with a line at the top of the window saying so. That is the
  state a remembered selection opens in when the app is started before the DAW.
- The status bar names a plugin session `DAW PLUGIN — LOGIC PRO` rather than
  `OPEN AUDIO ANALYZER PLUGIN — LOGIC PRO`. The wire is unchanged and a producer
  still names itself in full; what was dropped is this application's own name,
  inside this application, where it was the half of the row that survived the
  chip's 220 px ellipsis.
- The status bar prints no sample rate and channel count when nothing has
  reported one, instead of `0.0 kHz · 0 ch`.
- **Every level scale is tapered, with −∞ at its floor.** The dB scales were
  linear; the top decade now takes most of the track — the filled fraction is
  `10^(dB/60)` — the labelled ticks crowd the top, and the bottom of a track
  means silence rather than "−48, or quieter, who knows". One taper for the
  whole application, so two meters side by side still agree about where −12 is.
  The Spectrum Analyzer is the one level axis that is not tapered: a range
  setting on a taper would move nothing but the bottom tenth of the plot, so
  its axis is linear over the `Range` it is set to.
- **The LUFS Meter draws three bars — momentary, short-term, integrated — with
  their values printed beneath.** Integrated was a line across the other two
  and its number sat in a readout row; the bars now carry their names up their
  own faces, the scale is labelled on both edges, and the target line is
  dashed in the over colour with the target value printed on the axis. The LRA
  readout moved off this module; it stays on the Loudness Distribution, the
  Validator and any Number Box.
- **The Super Meter is a half-gauge on which loudness and dynamics meet at the
  true peak.** Short-term and integrated LUFS fill from the left end; ODR-S
  and ODR-I continue from each loudness tip on the same dB scale as thinner
  arcs, ending at the true peak with a grey tick, so the dark rest of a ring
  is its true-peak headroom — a dynamics arc reaching the right end is a peak
  at 0 dBTP. `LUFS-S` and `ODR-S` ride the outer ring's tips as engraved
  names and nothing else is printed on the rings; with nothing measured both
  rest together at the silent end, since a name parked at the other end of an
  empty dial reads as a tip standing at full scale; the delivery ceiling is a
  red zone at the right end with its value on a tick, the target keeps its
  tick with the value beside it, and the centre prints five readings in
  three rows — `LUFS-S` and `ODR-S` small on top, in the accent and judged
  by nothing, `LUFS-I` and `ODR-I` under them in their verdict colours, TRUE
  PEAK below — every one of the five printing its unit beside it and every
  row labelled with its reading's full name rather than under an INTEGRATED
  heading, and a module too small for three rows keeps the two that are
  delivered. It printed every arc's reading in the lane beside
  it and LRA as a fourth row for part of this cycle, and read as crowded;
  the short-term pair also spent a day cut into its arcs, where an upright
  figure clips to a sliver whenever a tip stands near the dial's vertical
  ends.
- **The Super Meter's arcs arrive from the silent end.** A reading that has
  just become defined — LUFS-S and ODR-S three seconds after a reset or the
  start of a song, LUFS-I and ODR-I after the first gated block — used to put
  its arc into the middle of the dial at once, which read as a glitch. The arc
  now starts at the left end and sweeps to its value over about half a second,
  then follows the reading as before. The numbers in the centre are unchanged
  and show the measurement from the first frame.
- **The three level meters are drawn in a darker shade of the skin's accent,
  deepening towards the floor.** The LUFS Meter's bars, the Digital Meter's
  bars and the Super Meter's loudness arcs are the accent at 70 % of its
  lightness at the reading; they were the grey `meter_fill`, a step above the
  grey track, and read as a level you had to look for. Down each fill the
  ink runs flat for the top three tenths and then to a floor colour that is
  the ink fully saturated and darker, in the same hue — the ramp measured off
  Decibel's bars, whose floor is a deeper colour rather than a shaded one.
  The one gradient before it dimmed from the reading
  downward and reached its darkest only a full scale below it, so a bar at
  two thirds of its track was one flat colour with a lit edge. The LUFS
  Meter's bars are also shaded across their width as tubes, a little darker at
  both edges on the reference's curve, tightened towards the edges so that the
  middle of a bar — the strip a name is printed up — carries the ink
  undimmed. The Super Meter's arcs
  carry the same ramp swept around the dial, where they were flat. Both
  colours are derived from `accent` rather than new skin roles, so a skin
  that sets its accent gets meters to match; `meter_fill` still colours the
  VU needle and the report's bars, so a skin that sets it is unaffected
  there.
- **The Super Meter's loudness arcs keep their colour past the target.** The
  part of an arc standing past the target tick was redrawn in red; it is now
  the arc's own ink to its tip, and the tick alone marks the target — a ring
  that turned red at its tip was a warning laid over a level, on a gauge
  whose centre already prints the verdict. The LUFS Meter's bars, the
  Histogram and the Loudness Distribution still cut to red at the target.
- **The Digital Meter prints peak and RMS per channel above the bars.** The
  bars are lit as segments under one gradient, the peak mark warms from the
  fill colour to red as it nears full scale, and the fixed top-of-scale
  warning region is gone — the mark that is actually hot carries the warning.
- **The Digital Meter lights whole segments only.** Its bars were drawn to the
  measurement with the segment gaps laid over them, so the row at the top of a
  column was whatever fraction of a segment the reading landed on — less ink
  than every row under it, which reads as the paint thinning out rather than as
  a level — and the peak was a two-pixel hairline free to sit across a gap
  between two rows. A column now stops at the top of the last row it fills
  completely, and the peak is one whole lit row on the same grid, so what
  stands between the two is a whole number of segments. **The scale is ruled on
  that grid too**: its gridlines were drawn on their exact values, which put a
  line through the middle of a segment as often as not — a second ruling
  beating against the first — and each one now stands in the segment gap
  nearest its value, at most two pixels from where it was, with its label
  moved to match. A labelled value is one of the meter's own gaps in a lighter
  grey, so the scale reads across a lit bar as well as an empty one, where
  before it was covered by the fill. The column's resolution is one row; the
  peak and RMS printed above it are unchanged and carry the measurement itself,
  rounded by nothing.
- **The Histogram's time axis is wall-clock time, and an overview strip along
  its floor shows the whole recording** with a frame over the slice the plot
  is showing. The momentary band is tinted by how far over target each column
  stands, from the accent into the over colour.
- The Spectrum Analyzer's frequency labels moved to the top of the plot and
  cover the 1-2-3-5-7 series from 20 Hz to 20 kHz; the dB labels moved to the
  left and run over the chosen `Range` rather than a fixed 96 dB; the tilt
  caption sits inset in the plot's top-left corner, with the range in the
  top-right. The setting is unchanged.
- The Spectrogram gained its axes: frequency labels ticked down the left, time
  along the top. Nothing is drawn over the field itself.
- **The Phase Scope is a square goniometer**, with
  balance riding its bottom edge and correlation its right edge as markers —
  the correlation marker in the warning colour below zero, as the bar it
  replaces was — and `L`, `R` and `M` engraved at the ends of the axes they
  name. The correlation bar under the plot is gone. On a mono source the
  markers are withheld beside the notice, as the bar was.
- The Number Box names its metric inside the body and glows at its foot in the
  reading's verdict colour, out to the panel's own edges and fading over four
  fifths of its height whatever shape the module has been given.
- Every Validator row prints the signed distance between its reading and the
  limit that judges it, beside the limit.
- **The VU Meter wears the standard face** — labelled −20 −10 −7 −5 −3 −1 0 +1
  +2 with the pin at +3 and − and + at the ends, a peak lamp that lights while
  the held peak stands over 0 VU, and its reading in a box under the needle.
  The machined hub is gone; the needle wears the instrument colour.
- The VU Meter prints a dash when the programme is below the bottom of its
  scale, in the muted voice every unreported quantity wears, rather than `<-20`
  in the colour of a measurement. The two signs ran together into a mark that
  read as a left arrow, and a needle resting on its stop was printed with the
  weight of a figure the programme had made. The two states are still distinct
  on the face: below the scale the needle is there, on its bottom stop;
  unmeasured, there is no needle at all.
- **The VU Meter's peak lamp is set into the face**, under the end of the red
  and inside the rim, rather than pinned to the right edge of the tile at half
  the face's height — where it was level with nothing, attached to nothing, and
  read as a stray dot beside the instrument. It scales with the dial, and gives
  way to the reading on a tile too small for both.
- The VU Meter's face says which way it runs more plainly: the `−` and `+` past
  the last marks are larger, the `−` is grey rather than in the accent colour —
  it was the one teal thing on an instrument that has no other — and 0 is red
  like the numbers above it, on the heaviest tick of the scale, because 0 is
  where the red begins.
- **The Super Meter's ends are square again**, and every printed value on it
  wears its arc's own ink — the integrated tip value is neutral past the
  target, the way its arc is — so the one red number on the dial is the
  target's.
- **The Stereo Cloud is a field of marks, not an accumulation.** Each
  published frame contributes one diamond per band that stands out of the
  mix, brighter and larger the louder, and the last two seconds of those are
  drawn, fading with age; a bass band drifting off centre leaves a ribbon. It
  accumulated into a grid before, where every band a few decibels down the
  mix added a little forty times a second and the field filled edge to edge.
  Marks sit at the **pan pot's angle** the balance implies rather than at the
  power balance itself, which is steepest at the centre — a three-decibel
  lean is a fifth of the way over now, not a third — and only the top 30 dB
  of a frame place a mark, cubed, so the picture is the bands that matter.
  Its frequency scale sits in a gutter beside the field and `L`, `C`, `R` in
  a strip below it, both outside the box around the field, as Decibel lays it
  out.
- **Six modules are boxed.** The Spectrum Analyzer, the Oscilloscope, the
  Spectrogram, the Histogram — twice, once round the plot and once round the
  overview strip along its floor — the Loudness Distribution and the Stereo
  Cloud each draw a hairline box around their picture, in the same ink as the
  gridlines inside it. They ruled whichever one or two sides a scale happened
  to sit against, in whatever weight looked right there, and a rule that stops
  where the picture stops on two sides of four reads as an unfinished box
  rather than as an edge. The box is drawn *around* the picture rather than
  over it, so the newest column of a spectrogram and the newest sample of a
  scope — both hard against the right-hand edge — are framed instead of hidden
  under a hairline; each plot gives up a pixel on every side to make room.
- **A Spectrogram's floor is the panel it is drawn on.** The skin ramp's level
  0 was an opaque copy of the panel colour, which was the same pixel until a
  module's panel stopped being flat: it now carries a light across its top-left
  corner, and a field painted in the unlit colour cut a rectangle out of it and
  read as a lid laid over the module. Cells the signal reached are unchanged —
  the ramp's colours are the same colours, composited rather than mixed — and
  the `Full RGB` ramp still declares and paints its own near-black ground.
- **The Phase Scope fills its module.** It reserved the label band on all
  four sides to stay centred as a square; the figure with its two label bands
  is what is centred now, and the square is a quarter taller for it.
- **The three frequency axes label by one rule.** Every value of the
  20-30-50-70 series that fits is labelled, 100 Hz, 1 kHz and 10 kHz first,
  on the analyser's top edge and down the spectrogram's and the cloud's
  sides alike; two of the three fell back to three labels the moment one
  pair was tight, so a spectrogram beside a cloud carried three where the
  cloud carried ten.
- **The Histogram's overview strip runs edge to edge and spans the recording
  so far** — the whole ring once it has filled — rather than the ring's
  capacity, which put a session's first minute in a sliver at the right end
  beside seven blank ones.
- **The Loudness Distribution's target line is the over colour**, like every
  other target mark, with its value under the axis in the same, and it stops
  at the picture: the fill is already split at the target, so the dashes now
  run only through the clear space above the distribution and no longer
  through it.
- **The wire protocol is version 5.** A snapshot carries the four extra
  spectra and their peak holds as eight more fixed-point arrays before the
  scope run, which takes a one-block frame from 7,652 to 15,844 bytes — at
  the default 30 Hz display link about 250 kB/s more, a few percent of what
  a tablet's Wi-Fi carries. A version-5 display still reads a version-4
  plugin, reporting the four sources as not measured; a version-4 display
  refuses a version-5 host at the handshake, on payload size, with the
  sentence naming both numbers. Decoding is keyed to the frame's version
  rather than its length, because a long version-4 relay frame can be the
  size of a version-5 one. `docs/WIRE.md` is the specification.
- **The LUFS Meter's bar names are set to the module.** MOMENTARY, SHORT and
  INTEGRATED were written up the bars at one fixed 10 px whatever the module's
  own size, so on a small module the word filled a narrow bar edge to edge and
  read as a label of the meter rather than as one written on a bar. The face is
  now a base plus a share of the track's height — 6 px to 12 px, held under
  what the bar's width and the track's length will carry — so a module resized
  down takes its names with it and one resized up sets them a little larger.
  The default five-cell module lands where it always was. The single letters
  under the bars are still the fallback, now for a bar too narrow to carry a
  word rather than for a module too short.
- **A LUFS Meter bar is lit down its centre line, and shaded far less at its
  edges.** The fill was shaded at both sides and left at the ink in the middle;
  the middle is now lifted instead, and the shading at the sides is under a
  third of what it was — on the accent and on the red above the target alike — so a
  bar reads as a round solid rather than as a bar in a box. The two go
  together: with the middle lit, a hard edge as well gave the bar more range
  across its width than down its height, and the top edge, which is the
  reading, stopped being the first thing the eye found. The stretch above the
  target takes the lighter edges and no centre light. No other module changes —
  the LUFS Meter is the only one whose fill is shaded across its width at
  all.

### 🐛 Fixed
- **A meter with nothing to show no longer leaves a hairline of fill at the
  foot of its track.** The level scale is tapered and its bottom is −∞, which
  no finite reading reaches — but the floor every dB quantity is clamped to is
  −144.0, a finite number, and the taper puts that four tenths of one percent
  up the track rather than at the end of it. So digital silence drew a line of
  lit accent a pixel or two tall along the bottom of every bar, seconds after
  the music stopped. A reading at or below the floor now sits where the scale
  labels it, at −∞. The LUFS Meter is where it was reported; the Digital Meter
  and the Super Meter's arcs are drawn on the same scale and had the same
  hairline.
- **The LUFS Meter's bars no longer change height while the readings fall.**
  The row of numbers under the bars was fitted to whatever string was printed
  at that moment, and the bars stand on that row — so a reading below −100,
  which is one glyph wider, shortened all three bars, and at the size the
  module ships at it took the numbers under their legibility floor and removed
  them entirely until the reading passed. Every meter goes through that decade
  on its way down when the audio stops, so it showed up as a twitch each time.
  The row is now fitted to a fixed budget and only the digits themselves shrink
  to hold a longer number.
- **The Phase Scope's correlation marker and a Number Box on `Correlation` no
  longer paint a reading of `-0.00` as anti-phase.** The rule was the sign bit,
  and correlation prints two decimals — so a signal whose channels are simply
  unrelated sat dead centre and changed colour as the sign fell one way or the
  other, and a value a thousandth below zero was coloured like one at −0.9. The
  warning now starts at the first hundredth the reading actually prints, and
  both readouts go through one function so that two views of one number cannot
  disagree.
- **An Alert Meter in `Delta` no longer reads an em dash for ever on `ODR-S` or
  `ODR-I`.** `Delta` prints a reading as its distance from the line the target
  draws, and the two dynamics floors are the target's to state: no built-in
  target states an `ODR-I` floor and only `Dynamic master` states an `ODR-S`
  one. The menu offered the setting anyway, on the metric alone, so switching
  it on under any other target — including the `Streaming (−14 LUFS)` the
  application starts with — left the module printing a dash from the first
  frame to the last, with a disabled menu row as its only way out. The row now
  follows the target as the Validator's checks already did, and a stored
  `delta` a target cannot satisfy prints the reading itself rather than
  nothing. The choice is kept, not corrected: pick a target that states the
  floor and the distance comes back.
- **The source menu no longer offers "Open Audio Analyzer System Capture".**
  Metering System Output on macOS builds a private Core Audio aggregate device
  to read the process tap through, and private means private to every
  application except this one — so the application listed its own plumbing as
  something to capture from, directly beneath the System Output entry that had
  created it. Selecting it read the tap back through a second path that was
  never designed. Enumeration now leaves out any aggregate this process built,
  matched by device UID rather than by name so that an aggregate of your own
  called the same thing is still offered.
- **`Save` overwrites the preset it opened, on the next launch as well as this
  one.** The session brought the layout back but not the file it came from, so
  the first ⌘S of a morning opened a save panel for a preset that already had a
  home — and the obvious answer, accepting the name the panel offered, wrote a
  second copy of it beside the first. `session.json` now records the open
  preset's path, and the canvas adopts it on the way up: `Save` writes back to
  that file without asking, and only a layout that has never been saved, or
  `Save as…`, opens a panel. A remembered file that has since been renamed,
  deleted or left on an unmounted drive is dropped at launch, so `Save` asks
  where it should go rather than recreating it.
- **The spectrogram's age axis stands still, and stands in the same place on
  the next launch.** The ticks and their labels were laid out from a rate
  re-derived on every published frame — one column is one measurement, and how
  long a column covers can only be measured — so they crept a pixel one way and
  back on every frame, worst in the first seconds after a module was mounted
  and never quite still afterwards. The rate is now adopted in steps of two per
  cent; a tick can stand up to that far from the age it is labelled with, which
  it always could.
- **And the axis is the same picture every time the application starts.** The
  first fix adopted whatever the first third of a second measured and then
  defended it for the rest of the session, which made the axis a photograph of
  the device's spin-up: the engine's clock advances in whole audio callbacks, so
  that early mean lands on one of a handful of quantised values depending on
  where the callbacks fell, and it was never corrected afterwards. Launches
  differing in nothing else spread 2.2 per cent, which at a 2 s rung puts the
  sixth tick anywhere in a 12 px band, and where the spread crossed the
  label-spacing threshold the rung itself flipped and the number of labels
  changed. The measured rate is now weighed against the rate on screen —
  including the nominal one it starts at — so an engine publishing within two
  per cent of nominal draws the identical axis on every launch, while a remote
  host at a genuinely different rate is still corrected to.
- **The Spectrum Analyzer's right-hand edge is one line rather than two.** The
  frequency gridlines are drawn at band *centres*, so the top of the range —
  20 kHz — sat half a band inside the plot's own border, in the border's colour
  and at its weight: on a module of ordinary width the two were adjacent and the
  right edge came out twice as thick as the other three, and on a wide one they
  separated into a rule standing beside the border. The gridline at each end of
  the range is now the border, which is where it was always trying to be.
- **The Alert Meter drops what it has latched when it is asked to show
  something else.** A different metric, Delta on or off, or a different
  delivery target each left the previous setting's worst case standing: a
  true-peak maximum in dBTP printed under LUFS-I as the worst loudness of the
  programme, or a peak latched as over a −1.0 ceiling still red under a −2.0
  one. Switching source does too — the desktop swaps its engine for a plugin's
  the moment a DAW connects, and the two elapsed clocks have no relationship,
  so the reset the module already watched for could not see it.
- **The spectrum analyser's peak hold no longer carries across a change of
  `Source`.** The line over Right was the maximum of Right and whatever Left
  had just been doing — standing at a level Right never reached and sinking
  towards the truth at twelve decibels a second. The curve reseats across a
  discontinuity of the clock for exactly this reason and a source change is not
  one; the spectrogram, reading the same bands from the same setting, has
  cleared its record on it since the setting existed. `Tilt` and `Range` still
  keep the hold, being views of the measurement rather than a different one.
- **The oscilloscope no longer loses a block of audio whenever two measurements
  land inside one display tick.** One picture — a waveform in bursts, with a gap
  between every pair — and two causes. The plugin's streaming thread pushed
  every block a host buffer held and sent one snapshot per drain, so at a
  2048-frame buffer every other block never left the DAW; it now sends every
  push. And every reader in the application took one snapshot per look while a
  snapshot carried only the newest block, so two publishes between two looks
  lost the first even once the plugin sent both — which also cost a third of
  the waveform at 88.2 kHz and above on a device, and a block whenever an
  engine caught up after a stall. Every source's scope buffer is now a window
  of its newest four blocks, and a reader takes from it what the elapsed time
  says it is owed. Every other reading was right throughout, because those are
  integrals; nothing needs re-measuring.
- An Alert Meter watching `ODR-S` or `ODR-I` latches the **lowest** reading. It
  latched the highest — the most open moment of the session, printed as the
  worst of it — because every metric but correlation was taken to be worse when
  higher, and a ratio a floor is set under is the other way round.
- `--open-panel=settings` opens the settings panel again. It asserted "No
  RemoteDisplayScope in scope" and opened nothing, because the flag is acted on
  from a context above the scopes the panel needs — which is the debug build's
  only way to put a panel on screen for review.
- The link preview card no longer says the project is part MIT. 0.14.0 made
  everything but the plugin GPL-3.0-or-later and the card was the one place that
  still carried the old split; it now reads GPL-3.0 · AGPL-3.0, as the site's
  footer does.
- **The Stereo Cloud is readable on dense material.** Every band lit against a
  fixed floor, so real music filled every cell and the picture read as a wall
  of dots; bands now light relative to the loudest in the frame, and the cloud
  is sparse with a spine — which is the picture the module exists to show.
  Frequency gridlines, a C mark and the STEREO 1-2 caption landed with it.
- A skin change recolours every cached readout label and unit immediately;
  they kept the previous skin's ink until their text next changed, which for a
  static label is never.
- The Digital Meter's `dB` sits on the same baseline as `PEAK`, `RMS` and
  their values. The three faces in the row have three line heights, and
  top-aligned the unit floated above the reading it belongs to.
- **The Spectrogram's time axis no longer changes its spacing or its
  labelling while it runs.** The ages along the top are labelled at the finest
  interval whose ticks stay legibly apart, and the interval was chosen by a
  bare comparison against a rate the display measures for itself. A column is
  one pixel and one publish, so that comparison falls on its threshold exactly
  at the ordinary rates — a 30 Hz remote host, a 60 Hz one, and any machine set
  to 30 fps — and the last digit of the estimate decided whether the axis read
  `2s 4s 6s` or `5s 10s 15s`. It landed one way on one launch and the other way
  on the next, and a rate correction mid-session relabelled the whole axis. The
  comparison now carries the tolerance the rate itself does, and the interval
  already on screen is kept on a looser threshold still, so every rate lands on
  the finest legible interval and stays there: a 30 Hz host reads `2s 4s 6s`,
  a 60 Hz one `1s 2s 3s`, and the local engine's 47 Hz is unchanged at
  `2s 4s 6s`.

### 🔥 Removed
- **`PSR`, `PLR`, `DR-S` and `DR-I` as names**, and `plr` and `dr_i` as keys of
  the JSON report. They were the two Open Dynamic Range readings under other
  spellings, and "DR" in particular is what the TT Dynamic Range Meter calls
  its number — a different measurement with a different algorithm — so it was
  the one spelling this pair could not keep. Every old preset id still opens
  on the reading it meant. The wire is unchanged: its two slots per reading
  both carry the one value, as every producer already wrote them.

### 🚧 Internal
- **The website is deployed by a job of its own, after the release it
  describes.** The front page prints the version out of `pubspec.yaml` on its
  download button, so the release commit's own push to `main` deployed a site
  reading `Download 0.15.0` while the newest release was 0.14.0 — and if an
  artefact then fails to build, `publish` never runs and the site goes on
  saying it. `website` still builds on every event; `website-deploy` deploys
  only over a release that exists — from `main` when `pubspec.yaml` already
  names a released version, and from a tag once `publish` has published one.
- **The end-to-end scope test reads what a frame carried rather than what the
  window holds.** ABI 7 grew the engine's scope from one block to four so a
  reader that missed a publish could still find the audio, and both sides of
  the wire mirror that window — so `scopeFrames` became the fill of a buffer
  and stopped being a statement about one frame. The test that proves every
  block crosses the wire in its own frame was still reading it, and failed on
  the second frame of every run with 2048 against a clock that had advanced
  1024: the window filling, not a block sent twice. It reads `lastRunFrames`
  now, which exists for exactly this. Nothing about the plugin or the wire
  changed. It runs only where a built fake DAW exists, which is a release or a
  manual run, so it went unseen from the ABI bump to the 0.15.0 tag.
- `--publish` and `--attach=oaa://host:port` open the display port and attach to
  a host at startup. They are what the website's signal-path photographs are
  taken with: a desktop publishing and an iPad drawing that desktop's canvas,
  neither of which could be reached from a script without posting mouse events
  at the machine somebody was sitting at. Nothing persists either, so the next
  launch publishes nothing again.
- Flags reach the application on iOS. `main` is handed an empty argument list
  there and `Platform.environment` is empty as well, both without error, so
  every launch option did nothing on the one platform a tablet runs on — and
  `xcrun simctl launch --args` looked exactly as though it had worked.
  `ios/Runner/OaaLaunchArguments.swift` answers with the real `argv` over
  `oaa/launch_arguments`, the application's seventh platform channel.
- `packaging/signal_path.sh` takes the website's desktop and tablet plates from
  one session, replacing `packaging/macos/screenshot.sh` and the website's use
  of `packaging/ios/screenshots.sh`. The tablet in it is a **remote display
  attached to that desktop**, so the two pictures are one measurement drawn
  twice rather than two runs matched by transport position — which is what they
  were, and which shipped a pair reading 00:01:19:21 against 00:01:20:03. It
  posts no mouse events and needs no Accessibility grant: both windows are
  placed by writing the preferences that hold their geometry.
- The signal-path plates on the front page were reshot. The tablet one is now
  an iPad attached to the desktop beside it rather than an iPad metering a
  plugin of its own, which is what the paragraph above them describes.
- `OAA_ABI_VERSION` is 8, and this release moves it twice.
- `oaa_engine_reset_all` destroys every engine the process created and did not
  destroy, and the application calls it from `main`. It reclaims nothing in a
  shipping run: it exists for a Flutter hot restart, which re-runs `main` in a
  process that never exited, so nothing disposed the previous isolate's engine
  and it went on running its analysis thread — and holding a macOS process tap
  and the aggregate device under it — for the rest of the session. A
  development afternoon left a dozen of them metering at once.
- `oaa_snapshot.scope` holds 4,096 stereo pairs rather than 1,024 and
  `scope_frames` counts how many are audio. The wire protocol is unchanged at
  version 5 — a plugin still sends one block per frame, the newest of the
  window — and the engine's tests hold the window's order, its slide and its
  reset.
- The CLI suite decodes the tool's output as UTF-8, which is what the tool
  writes. It was decoded with the system encoding — on Windows the ANSI code
  page — so the two dynamics-floor tests, the first to assert a line carrying
  `≥`, failed on that platform alone while the CLI itself was fine.
- `OAA_GATE_ABSOLUTE` lives in `oaa_loudness.h` rather than in the loudness
  source, so the analysis layer gates the dynamics readings on the same
  constant the integrated measurement is gated on.
- The Open Graph card is rendered at 1280×640 rather than 1200×630, which is the
  size GitHub asks a repository's social preview for, so the same image serves
  the link unfurl and the repository page without being cropped.
- The website's photographs are re-rendered against these modules: all fourteen
  thumbnails and the front page's analyzer still at its five widths. They are
  committed output rather than built in CI, so they go stale silently, and the
  modules moved under them twice over — the Decibel pass and the readings above
  it. The three signal-path plates are not among them and still show the
  previous design: making one needs a signed application on a window server or
  an iPad simulator, which the machine that renders the rest does not do.

## [0.14.0] — 2026-08-27

### ⚡ Changed
- **The engine, the FFI bindings, the domain model and the wire protocol are
  GPL-3.0-or-later; they were MIT.** Open Audio Analyzer is copyleft throughout
  now, apart from `plugin/`, which stays AGPL-3.0-or-later because it links
  JUCE. Nothing changes for anyone using the application, the CLI, the plugin or
  a tablet display. What changes is embedding: `engine/`, `oaa_engine`,
  `oaa_core` and `oaa_wire` could be linked into a closed-source product and now
  cannot — a derivative you distribute has to carry its source under the same
  terms. Commercial use is still permitted, as the GPL has always permitted it;
  the proprietary fork is the part that is not. Releases up to 0.13.0 stay MIT
  and that grant cannot be withdrawn, so anything already built against those
  versions keeps working under the terms it was written to. `docs/WIRE.md` is
  unchanged and still normative: a display implemented from the specification
  rather than from `packages/oaa_wire` is unaffected, which is the case for two
  of the three implementations that exist.
- **The front page says what you do before it says what that buys you.** Its How
  it works section opens with the setup — the plugin on your master bus, the app
  on the desktop beside you, a tablet attached to the same session — and makes
  the claim about one engine and one set of numbers after it, which is what it
  used to open with.
- **The Known gaps section is off the front page**, along with its entry in the
  site navigation. All twelve are in `README.md` and in the documentation, which
  is where the section already pointed for the other six. The one gap a reader
  has to act on rather than know about stayed on the page: the tablet link has no
  password, so publish on a network you control. It is now a sentence in the
  paragraph that describes the tablet.
- **The website says less about how a number is arrived at and more about what it
  tells you.** The percentiles behind LRA, the FFT behind the spectrum's band
  spacing, how a colour scheme file inherits and what a layout is stored as have
  come off the front page; every one of them is still in `docs/METRICS.md` or the
  README. Nothing a reader acts on was removed.
- The documentation's overview page is trimmed the same way: the window length
  behind the spectrum's bands, the filter order behind the VU needle, how the
  oscilloscope derives a column's colour and why the official vector files cannot
  be a build step have come off it. Every control a module offers is still
  documented there, and every claim about a measurement is unchanged; the
  mechanism is in `docs/METRICS.md`, `README.md` and the engine's own headers.
- The Android test page says what staying opted in is for: Google wants twelve
  testers opted in for fourteen unbroken days before the app can leave closed
  testing. The site footer reads a little shorter, with no change to what it
  says.
- The install page and the documentation's overview stop explaining the parts of
  themselves that only a contributor reads: why an AppImage is built on an old
  distribution, what the Mac App Store sandbox would do to a container, how Apple
  makes a refused system-audio tap undetectable, how Play generates a download
  from an app bundle. Every instruction, path, permission and warning on those
  pages is unchanged.
- The note under the front page's download table is gone. Which installers carry
  the plugin is a column in the table above it, and what metering your computer's
  own output needs is on the install page.

- The install page's download table says which installers carry the plugin in
  the same colour the front page's does, rather than with a tick. The two
  tables answer the same question and now answer it the same way; the rows that
  carry no plugin stay in the body colour, so the column reads as an answer
  rather than as decoration.

### 🐛 Fixed
- **`plugin/` ships a `LICENSE` file.** Every source file there carried the
  AGPL-3.0-or-later identifier and the directory carried no licence text at all,
  which is the one thing AGPL section 4 asks of anyone conveying it. The
  installers were unaffected — they generate their notice from the repository
  root — so this was missing only for somebody reading the source.
- **The privacy policy said the Android build never asks for the microphone,
  because it was "a remote display only".** It has metered a live input since
  0.12.1 and declares `RECORD_AUDIO`, so the policy described a permission the
  application does ask for as one it could not. It now says what both tablets do:
  the microphone is asked for the first time you choose an input, on Android as on
  iPadOS, and a tablet that only draws another machine's meters is never asked.
- The documentation contents and the install page called the iPad and Android
  builds "tablet displays". They run the whole application, with the engine
  compiled in, and can additionally draw a remote host's meters.

### 🚧 Internal
- The Play Store's "What's new" text is chosen from the release's changelog
  section rather than taken from the top of it until the 500 characters run
  out. An entry's **bold lead** is now its store note where it has one, those
  entries are taken before the rest, and the sections are filled a turn at a
  time — so 0.13.0's note reaches the mono Phase Scope and the machine that
  could attach to itself, where the old rule spent the whole budget inside
  Added. The text is en-US and deliberately has no second language.
- TestFlight builds carry a **What to Test** note, and the App Store listing a
  **What's New**, both generated from the same changelog section as Play's by
  `packaging/store_notes.py`. Apple allows 4000 characters against Play's 500,
  so a release usually arrives there with its entries whole. Every build up to
  0.13.0 went to TestFlight with that field empty.
- A manual run of the workflow can write those notes onto a build App Store
  Connect already holds, without uploading anything — which is the only way to
  exercise that path that does not cost a tag and a build number. Naming a
  build also turns the plugin, the installers, the IPA and the app bundle off
  for that run.
- The end-to-end test that carries a DAW's audio through the plugin, the app
  and out to a display no longer fails when the frame it freezes for comparison
  carries no oscilloscope audio. A relayed scope run holds what was measured
  between two sends and is legitimately empty when a publish lands between two
  of the engine's generations; the test indexed it regardless and died on the
  arithmetic. It failed the 0.13.0 release with every other job green.

## [0.13.0] — 2026-08-27

### ✨ Added
- **A status bar across the bottom of the window.** Everything the top row used
  to report is in it: the signal source, the sample rate and channel count, the
  DAW's playhead, the elapsed clock and the delivery target. What is left in the
  top row is what you press — the File menu, ANALYSE FILE, the pairing code,
  PUBLISH, ATTACH, settings, restart and `?` — with the open preset's name
  centred between them, which on macOS is where a window's title goes because
  that row is the title bar.
- A layout nobody has saved yet is called **Unnamed** rather than Loudness, and
  that is the word the Save as dialog opens with for you to replace. A fresh
  install used to print a document name nobody had chosen and offer
  `Loudness.json` as though it were the name to keep.
- The front page carries the App Store and Google Play badges, beside the
  Download, Source and Documentation buttons. The App Store badge is drawn
  greyed and unlinked until the iPad build clears review, which is the whole of
  what says so — each badge stands on its own artwork, with no caption under
  it.
- A new page at `/testing` explains how to get into the Android closed test, in
  three steps. It is where the Google Play badge leads, and it exists because
  neither URL Play offers can be sent to a stranger: a closed test grants access
  by list rather than by link, so both of them turn away anybody who is not
  already a tester, and neither explains why.

### ⚡ Changed
- **The File menu moved to the far left of the top row**, where a menu bar's
  first menu is, on Windows and Linux. It was between ATTACH and ANALYSE FILE at
  the right-hand end.
- **SETTINGS and RESET are drawn as marks** — two faders, and a ring with an
  arrowhead — beside the `?` that was already one. Both keep a tooltip, and
  RESET's has always been where the scope of what it discards is written. The
  words were 145 px of a row that has to leave room for the document's name;
  the marks are 84.
- The smallest supported window is now **960x808**, up from 960x768 (macOS; the
  only platform that enforces one). The canvas is a fixed 24x16 cells, so a row
  taken out of the window is height taken off every module: at 768 the smallest
  module in the default preset had 4 px of body to spare and the Alert Meter had
  none, so the new row is paid for by the window rather than by the meters.
- The prompt that asks about unsaved work says "The layout on the canvas has
  changes that are not in a file" for a layout that has never been saved, rather
  than quoting the placeholder name back at you.
- The file analysis dialog opens without 64 px of empty space above and below
  its drop zone. It also no longer changes height when you drop a file: the idle
  state and the analysing state are now within a few pixels of each other.

### 🐛 Fixed
- **The open preset's name no longer disappears on a window under 1266 px.** It
  had the highest width gate in the old single row and was the first thing
  dropped; centred in the top row it needs 900 px, which is under the narrowest
  window the application supports.
- **PUBLISH can no longer be taken away by narrowing the window.** It was the
  last of the three remote controls to be dropped, and under that width there
  was no way anywhere in the application to stop publishing — a capability
  removed by a window size. The whole remote group now survives every width the
  row is built at.
- **The Phase Scope no longer looks broken on a mono source.** A one-channel
  source is `L == R` exactly — the engine copies channel 0 into the right slot,
  which is true and documented — and rotating that gives a hard vertical line
  that never moves, indistinguishable from a display that has stuck. It says
  **MONO SOURCE** across the face now, keeps its graticule, dissolves whatever
  trail was there rather than freezing it, and draws its correlation bar as an
  empty track — `+1` pinned against the right end is the same tautology one row
  lower. Correlation is still measured, and a Number Box set to it still prints
  the number. The Stereo Cloud has said this since 0.2.0 for the same reason.
- Android can measure a live input. The manifest declared no `RECORD_AUDIO`, so
  Android refused every capture device while the canvas, the modules and the
  engine behind them all worked — which looked like the platform being a remote
  display by design, and was documented that way. It asks for the microphone
  when you first choose an input, not at launch, so a tablet that only mirrors
  another machine is never asked.
- **The File menu reads as one menu.** Three things, all of them visible the
  first time it was drawn on the machine it is written on: the shortcuts are in
  one column at the right of the menu rather than packed against the end of
  each label, where `Ctrl+O` sat 90 px left of `Ctrl+I`; all six labels are in
  one column, where the two rows that carry a tick used to be indented past the
  four that cannot; and neither tick row is greyed while it is off, because the
  two are checkboxes and not a choice between each other. Windows and Linux
  only — macOS draws this menu in the system menu bar.
- The gap between FILE and ANALYSE FILE is the same 8 px seam as everywhere
  else in the top row. It was 16, meant as a boundary between a menu and a
  command, and read as one control placed wrong.
- **A machine can no longer attach to itself.** A desktop that is publishing
  hears its own announcement, so its own name was a row in its own host list —
  the only row, on a machine alone on the network — and tapping it covered the
  canvas with a copy of the canvas, arriving over a socket a frame late, with
  nothing failing anywhere to say so. The list leaves this machine out and says
  that is why it is empty, and an address typed or a code scanned that points
  here is refused with a sentence instead of dialled.

### 🚧 Internal
- Apple's and Google's badge artwork is committed under `website/public/badges/`
  exactly as each publishes it, and the trademark credit line both of them
  require is in the site footer.
- Both rows' width gates are arithmetic on one table of measured control widths
  (`BarMetrics`) rather than eight hand-measured totals, and `scaling_test.dart`
  holds every number in that table against the widget it names — from both
  sides, so a bound that has gone slack fails as loudly as one that has been
  outgrown. Twice a gate was measured against a string the running application
  had already replaced, and both times the suite stayed green while the row ran
  off its edge.
- The sweep that pumps the whole application at every width now runs from 480 px
  rather than 600, which is where both rows actually stop, and it measures the
  distance from the centred document name to every control in the top row: the
  name is a layer of a `Stack`, and two layers of a `Stack` overlap in silence.
- A debug build draws the FILE button on macOS as well, beside ANALYSE FILE,
  so the row two thirds of the platforms ship can be looked at on the machine
  most of this is written on — both defects it has had were ones a glance would
  have caught. Release builds are unchanged: a Mac's File menu is in the system
  menu bar. It was `--in-window-menu` for an afternoon; a flag nobody remembers
  to pass shows nobody anything.

## [0.12.0] — 2026-08-25

### ✨ Added
- The front page shows how the parts fit together. A new section between the
  analyzer and the module catalogue follows one stream of audio through the
  three programs that read it — the plugin measuring in a DAW, the desktop
  drawing the canvas, a tablet mirroring it over Wi-Fi — with a photograph of
  each. It was only ever stated in prose, two-thirds of the way down the page.
- The Android build is distributed through Google Play. A tagged release builds
  a signed app bundle and uploads it to the internal testing track once the
  release is published, so a build on a track always belongs to a release that
  exists. There is no `.apk` on the releases page and there will not be one: an
  app bundle is a publishing format rather than an installable file, and the
  download Play generates from it is signed with a key Google holds. Play offers
  it to tablets only: the manifest asks for a 600dp shortest screen edge, which
  a 7-inch tablet clears and a handset does not. It is a store filter and not a
  runtime one — nothing about the application behaves differently, and a build
  installed by hand runs wherever it is put.

### 🚧 Internal
- `packaging/android/screenshots.sh` photographs the Android build for the Play
  Store, driven by the fake DAW through the real plugin, the way
  `packaging/ios/screenshots.sh` already photographed the iPad. An emulator is
  not on the host's network stack the way an iOS simulator is, so the
  application binds the emulator's own loopback and `adb forward` is what lets
  the plugin reach it.
- The default preset does not fit a real 10-inch tablet. At 1280x800 dp the six
  readouts along the top row render the words TOO SMALL rather than a number,
  because the layout wants roughly the iPad Pro's 1376x1032 pt. The screenshot
  script works around it with a lower density; the layout itself is unchanged.
- The release on GitHub is titled with the tag alone — `v0.12.0` rather than
  "Open Audio Analyzer v0.12.0". The repository's name is already printed above
  every release, so the prefix said it three times in one row and pushed the
  version off to the right.
- The Android jobs pin the JDK from `.tool-versions` rather than naming their
  own. The two disagreed — the file said 25 while CI said 17 — which is the
  drift the Flutter pin already had a rule against.
- `packaging/macos/screenshot.sh` photographs the whole desktop application
  window, driven by the fake DAW through the real plugin, the way
  `packaging/ios/screenshots.sh` already photographed the iPad. The website had
  no picture of the application as a program — only of its meters.
- The Play Store listing's two graphics are generated and committed. The icon is
  written by `packaging/icon/make_icons.dart` like every other icon, now with the
  alpha channel Play asks for and Apple rejects; the feature graphic is a card
  set in the application's own faces, rendered from a page by
  `packaging/android/make_store_graphics.sh`. Both were going to be exported by
  hand from a drawing at upload time, which is the arrangement the icon
  generator exists to have ended.
- The Android release build signs with a real upload key when one is configured,
  where it signed with the debug key unconditionally. Without the key it still
  falls back to the debug key, so `flutter run --release` keeps working for
  somebody who has never seen the credential — but `packaging/android/make_aab.sh`
  reads the certificate back off the finished bundle and discards a debug-signed
  one rather than offering it. Nothing in an `.aab` records which key signed it,
  so Play rejecting it by fingerprint at the end of an upload would otherwise be
  the first thing to notice.
- The Android version code is the workflow's run counter, for the reason the
  iPad build's already is. Play refuses a version code it has ever accepted, on
  any track, and refuses any number below the highest it has seen; the
  hand-maintained `+N` in `pubspec.yaml` collides on a re-run of a tag.
- `android/build/` and `android/.kotlin/` are git-ignored. Gradle writes them
  whatever Flutter does with the artefacts, and they only appear once somebody
  builds for Android — which nothing here did routinely until now.
- The website is built by CI on every event and deployed to Cloudflare on a push
  to `main`. It was deployed by hand, which is as durable as somebody
  remembering: the site reads the application's version out of `pubspec.yaml` at
  build time, so from a tag until the next deploy it advertised the previous
  release. Building it on a pull request is also the check that every document
  the manual publishes is still where the manifest says it is — a renamed page
  now fails a pull request rather than disappearing from the site.
- The GitHub Pages job is gone, and `tool/docs.dart` with it. What it published
  was a redirect per page to the website that replaced it; those redirects are
  already deployed and Pages serves whatever it was last given, so the old
  `jonasgrunau.github.io` addresses go on arriving at the documentation without
  anything continuing to publish them.
- The live analyzer's recording and the 45 seconds of audio it was measured from
  are committed — 1.2 MB, and already published on the site. They were written
  by `npm run record` on a developer's machine and git-ignored, which a runner
  that deploys the site cannot do: recording needs the 35 MB source track, and
  no job here fetches somebody else's music to publish a page. The CC BY credit
  is committed beside them.
- `npm run record` encodes through ffmpeg where `afconvert` is not there, so the
  whole recording path runs on Linux rather than on a Mac only. afconvert is
  still preferred where it exists — Apple's AAC is the better encoder at
  128 kbit/s, and the committed excerpt was made with it.
- `oaa.h` said this build never sets `OAA_FLAG_SPECTRUM_UNAVAILABLE`, and
  `README.md` repeated it. It does set it: a reset raises the flag and the
  analysis pass clears it once a full window has been transformed, about 85 ms
  in. A consumer that believed the header and skipped the check drew the floor —
  indistinguishable from digital silence — and presented it as a measurement.
  The flag itself is unchanged, so no ABI version moves.
- `plugin/AGENTS.md` gave the plugin bundles' macOS deployment target as 11.0.
  It has been 14.2 since the tap landed, which is what `plugin/CMakeLists.txt`
  sets and what every other document says.
- `docs/AGENTS.md` pointed at `tool/AGENTS.md` for how the documentation site is
  published; that moved to `website/` when `tool/docs.dart` went.
- `packaging/AGENTS.md` records that GitHub substitutes a dot for each space when
  an installer is attached to a release, which is why the scripts write
  `Open Audio Analyzer-…` and the install pages quote
  `Open.Audio.Analyzer-…`. Nothing said so, and the two read as a stale copy of
  each other.
- The site offers `OAA` to Google as an alternative site name. A result was
  headed `open-audio-analyzer.com` rather than `Open Audio Analyzer`, which is
  what Google shows when its site-name system is not confident enough to use the
  name a page states — every other signal already agreed, so `alternateName` is
  the one lever left. The domain is deliberately not among the alternatives.

## [0.11.0] — 2026-08-24

### 📐 Measurement
- Audio missed while the capture source was stopped is now counted as lost
  audio, so the frame count includes it and the warning appears. It previously
  counted nothing at all: integrated loudness and LRA average every block since
  the reset, so a device that stopped for a minute produced a reading of the
  programme minus that minute and presented it exactly like a clean one. A
  stall's share of the count is derived from the analysis clock rather than from
  the ring, so it is accurate to about a quarter of a second rather than to the
  frame — enough to prove audio was lost, which is what the figure is for.
  Re-measure any session where the warning appeared.
- The System Output tap no longer measures an output device that has changed its
  own sample rate. A macOS output device can move rate without ceasing to be the
  default output — AirPods drop from 48 kHz to 24 kHz the moment anything opens
  their microphone — and the tap went on delivering while the K-weighting
  filters, the true-peak oversampler, the spectrum's frequency axis and the
  elapsed clock all stayed built for the rate the engine opened at. Every
  reading was then wrong by the ratio between the two rates: at half the rate
  the spectrum sat an octave low and the elapsed clock ran at half real time,
  with the meters moving convincingly throughout. The source is now reported as
  stopped and reopened at the device's new rate. Re-measure anything metered
  through System Output on a Bluetooth output device.

### ✨ Added
- **A File menu, and presets that are documents.** `Open…` picks a preset
  through the platform's own dialog, starting in the presets folder and reaching
  anywhere else you point it — a preset somebody sent you now opens where it was
  downloaded to, instead of having to be moved into the configuration directory
  first. `Save` writes back to the file it came from without asking, `Save as…`
  places a copy anywhere and names the preset after the file, and the open
  preset's name sits at the left of the status bar with a dot beside it when it
  differs from what is on disk. On macOS the menu is in the system menu bar,
  after the application menu; on Windows and Linux it is the FILE button in the
  status bar. Opening a preset over unsaved changes asks whether to save first.
- A privacy policy, at
  [open-audio-analyzer.com/privacy](https://open-audio-analyzer.com/privacy).
  It states what the microphone, the camera, the local network and the disk are
  used for, that nothing is collected or transmitted, and — the part worth
  reading — that the remote display link has neither encryption nor
  authentication, so publishing on a network you do not trust means anybody on
  it can read your meters. App Store Connect requires the URL; the page is
  written for a person rather than for that field.

### ⚡ Changed
- The website serves its three typefaces itself instead of loading them from
  Google Fonts. Reading a page no longer makes a request to Google, which
  previously saw the IP address of everybody who opened one — the privacy policy
  said so and now says the opposite. It is also the reason the site's text used
  to move a moment after the page appeared: the fallback face is a different
  width, so the first paragraph re-wrapped once the real one arrived.
- The faintest text on the website — the footer, the small readouts above each
  section, every table heading and the documentation contents list — is light
  enough to read. It was the application's own `textFaint`, which is 2.97:1
  against the page and under what WCAG asks even of large text; in the
  application it labels a meter you are already looking at, and on a phone in
  daylight it was text you could not. The application's own interface still has
  this and is not changed here.
- ⌘O now opens a preset, and analysing an audio file has moved to ⌘I. The
  layout is this application's document — the thing that is opened, saved and
  sent to somebody — so it takes the chord every desktop user tries first, and
  analysing a file is an import, which is what ⌘I means elsewhere. `Save` on ⌘S
  and `Save as…` on ⇧⌘S are both new. Ctrl on Windows and Linux, as always.
- The preset browser is gone, and ⌘P with it. Saving is `Save` and `Save as…`;
  the list of saved layouts is the presets folder in a file manager, which is
  also where the delete button that used to be in that panel now lives.
  Settings → Session still prints that folder and lets you select the path.
- Whether a preset carries the delivery target and the skin is a property of the
  preset now, rather than two switches beside a Save button: two rows in the File
  menu, each asking whether the preset should carry one and ticked when it
  does. They cannot go in the platform's save dialog — macOS would need a save
  panel of our own, Windows a plugin of its own, and Linux cannot do it at all
  — and as properties of the document they survive a save, which the
  switches did not.
- The plugin's window is drawn in the application's own palette and the
  application's own two typefaces, both compiled into the VST3, the Audio Unit
  and the Standalone rather than asked of the platform — so the panel looks the
  same in Logic on a Mac as it does in Reaper on Windows, and looks like the
  tool whose meters it is feeding. What it shows changed with it: a diagram of
  the three places the path can break, with each run lit only while something is
  travelling down it, and the socket's dashes moving while frames are actually
  being sent, so a link that came up and quietly stopped no longer looks
  identical to one that is working. The middle of that chain is the app icon
  itself, drawn as line art in the shape macOS masks an icon with, so the thing
  you picked out of the DAW's plugin browser and the thing in the diagram are
  recognisably the same object. It also names the format it is loaded in and
  the host it is loaded into, which are the first two facts on every bug report
  and were the two nobody wrote down.
- A dropped-frame warning in the plugin's window no longer erases the readings
  it is a warning about. The count, the missing playhead and the loudness
  reading shared one line, so the worst news arrived by deleting the evidence;
  the readings now have a row of their own and the warning sits directly above
  the Reset button that answers it.
- The plugin's window says where the meters are when everything is working. A
  metering plugin that draws nothing is a confusing object the first time
  somebody inserts one — it loads, it reports itself healthy, and nothing
  happens — and the line that was blank in exactly that case is the calmest,
  most readable moment in the window.
- The Super Meter's target tick is a plain mark again rather than one cut into
  the arcs. 0.10.0 widened the slot beneath it to stand 1.5 px out either side,
  which put a notch through all three rings at the target; the slot is back to
  the tick's own width, so the rings run unbroken and only the tick crosses
  them. 0.10.0's note describing the wider slot stands as written and is
  superseded by this one.
- Every menu in the application marks the value it holds with a check and a
  band across the whole row. The band used to be the darkest colour in the skin,
  which in Precision Instrument put a near-black hole in a menu that is itself
  nearly black, and it stopped short of the menu's edges so the current value
  read as a chip sitting in the list rather than as one of its rows. It is a
  wash of the colour the rest of the interface already uses for selection now,
  it reaches both sides, and the check says which row it is without anybody
  having to compare two greys. Menus of actions — duplicate, rename, delete —
  hold no value and are unchanged.
- The iPad build no longer offers itself to iPhones. Its Xcode target had been
  universal since the project was created, so a phone could install a
  twenty-four-column canvas drawn for a tablet, and App Store Connect asked for
  a set of iPhone screenshots of it. It is iPad-only now, which is what every
  document already said it was.

### 🐛 Fixed
- The live analyzer's own document no longer offers itself to search engines as
  `oaa_analyzer_demo`, described as "A new Flutter project.". It is the page the
  front page loads into an iframe, and it had shipped as the Flutter scaffold
  wrote it — no language, no viewport, and a title and description that
  described the project worse than nothing would have. It now says what it is
  and asks not to be indexed.
- The website's 404 page no longer asks to be indexed, and no longer tells
  crawlers that every address without a page is really `/404`.
- "Linux dependencies" in the building document is a second-level heading, so
  the page no longer skips from its title straight to a third level.
- Re-saving a preset no longer silently drops the delivery target or the skin it
  was carrying. The two switches in the preset browser reset to off every time
  the panel opened and were never read back from the preset being saved, so
  opening a layout that carried EBU R 128, moving one module and saving wrote a
  preset that carried nothing — and nothing in the interface said so. They are
  rows in the File menu now, and they are ticked from the preset itself.
- The meters no longer freeze until you switch to another source. A capture
  source that stopped delivering left the engine publishing an empty ring at the
  same forty-seven frames a second for the rest of the session: every meter held
  its last reading, the window and the menus stayed perfectly responsive around
  it, RESET moved the readings to their floors and they held *there*, and
  nothing anywhere said why. The engine now notices within a quarter of a
  second, puts the source back itself when the format allows it, and says so on
  screen; when only a new engine can follow the device, the application opens
  one and the notice says the measurement has restarted. Reported as: the meters
  freeze, reset resets them but they stay stuck, and it only comes back when I
  switch to another sound source.
- A System Output tap whose rebuild fails when the default output device changes
  is no longer dead for the rest of the session. It tore the old chain down,
  failed to build the new one — a format that had moved, a device that vanished
  between the notification and the query — and left no producer and nothing that
  would ever try again. It is retried once a second now, against whatever the
  default output is at the time, so a device that comes back or a rate that
  returns is picked up without the source being reselected. Reselecting it was
  never the remedy the code comments claimed it was: choosing the source that is
  already chosen changes no setting, so nothing reopened.

### 🚧 Internal
- `npm run audit` runs Lighthouse over every page the website publishes, mobile
  and desktop, and prints the four category scores per page. Nothing in
  `ci.yml` builds or measures that directory, so the score was only ever as
  durable as the next change; the page list comes out of the documentation
  manifest, so a new document is measured without the script being edited. It
  also parses every JSON-LD block, which no Lighthouse audit does.
- `website/public/_headers` gives the deploy a cache policy. Cloudflare's
  default for static assets is `max-age=0, must-revalidate`, which is an ETag
  round trip for a typeface that will never change again; the fonts are a year
  and immutable because their filenames carry the family version, the committed
  photographs a month because they are regenerated in place, and the HTML
  revalidates so a deploy is seen at once.
- The website's sitemap is generated from the documentation manifest rather than
  written by hand, and its `<lastmod>` is each source file's commit date, left
  out rather than guessed when git cannot answer. The hand-written one it
  replaces named the front page alone for as long as the documentation had been
  part of the site.
- Every page of the website states what it is in JSON-LD rather than all ten
  claiming to be the application: the front page is the software, a
  documentation page is a `TechArticle` with a breadcrumb, the privacy policy is
  a page, and the 404 claims nothing. No rating is asserted, because there is no
  rating data.
- The front page's photograph is published at 768, 1024, 1440, 1920 and 2560 px
  with a `srcset`. It is the element the page's Largest Contentful Paint is
  measured on, and one 2560 px file was arriving on phones to be drawn a seventh
  of that wide — a phone now gets 28 or 41 kB depending on its screen, against
  121 kB before.
- The plugin's editor renders to a PNG without a DAW.
  `plugin/test/editor_snapshot.cpp` photographs its five states — waiting,
  connected, reconnecting, no playhead, dropping frames — in about a second,
  needing no host, no window and no screen-recording permission. It is the one
  surface in this repository that nothing but a person loading a bundle could
  previously look at, and its interesting states were the ones that had to be
  arranged for.
- Pressing "Load the live analyzer" on the front page now animates rather than
  swapping its label: the play mark travels to the middle of the picture, the
  label goes the other way and disappears behind it, and the square around the
  mark rounds into a ring that spins for as long as the two megabytes take —
  then the whole control fades out with the frame it was covering. A reader who
  has asked the system for less motion gets the label change instead, and either
  way a live region announces the wait and the end of it.
- The live analyzer's "play the audio" control sets the gap between its note and
  its label from `Space` rather than from two monospace spaces, which at that
  size was 13 px — wider than the padding around the pair, so the note read as
  sitting nearer the border than the words it belongs to. The note and the words
  are also centred in the button now: they share a baseline but not a face —
  `♪` is in neither of the two the demo bundles — so the fallback's descent set
  the row's depth and left the words two pixels low and the note one.
- The front page's demo canvas draws its oscilloscope over five seconds,
  overlaid on one centre line and zoomed to fill the lane. A triggered
  twenty-millisecond window is the right default in the application, where the
  picture moves; frozen into a still it read as one cycle of a sine and said
  nothing about the programme.
- The front page says less. The hero no longer recites the standards, the module
  catalogue no longer explains that its pictures are photographs, and the
  dynamics section states what Open Audio Analyzer reports rather than framing
  it as a substitute for a figure another product computes.
- The website no longer names the commercial analyser it set out from. The
  footer, the manual's opening page, the macOS system-audio section of the
  install page and the Dynamics section of the metrics reference each explained
  Open Audio Analyzer by comparison; each now states what it does on its own
  terms, and the one claim that mattered — that no proprietary single-figure
  dynamics number is reproduced or approximated — is made without naming a
  product. The footer says what the canvas is *for* while it is at it: a preset
  per way of working, one for tracking, one for mixing, one for the last hour
  before a master goes out. Released sections of this changelog still name the
  product and are left as written.
- On a phone the front page's canvas is a photograph and nothing else. The
  control that loads the live analyzer is not drawn there, and neither is the
  line under the picture: eight dense meters scaled to a 390 px screen are not
  legible, the compiled application behind that control is two megabytes over
  whatever connection a phone has, and an iframe that takes touch inside a
  document you are scrolling fights the scroll for every gesture. The two go
  together — the credit is required of a page that publishes the programme, and
  with nothing to press the audio is never fetched. A tablet is above the
  breakpoint and still gets the real thing.
- The analyzer still is re-rendered without the demo's own play-the-audio
  button in the corner of it. `?seconds=` — the query string that freezes the
  demo for a screenshot — now takes that button off the canvas as well; the
  audio is still decoded, because the oscilloscope and the phase scope draw from
  it. It matters because of the line above: with no facade control on a phone,
  the button inside the photograph was the only play mark left on that screen,
  and it was a picture of one.
- The play mark on that control is a drawn path rather than a typed character.
  `▶` is on the emoji tables with a text default presentation, which a desktop
  honours and a phone does not: iOS and Android both resolved it out of the
  colour emoji font, so the hairline square came out holding an oversized emoji
  play button.
- The front page is written for somebody making a record rather than for
  somebody reading the source. The architecture section is gone, and so is the
  readout of a quantity nobody measured; the measurement table says what each
  reading means and which published standard it follows instead of how the
  filters and windows are built; the modules, the configuration and the dynamics
  sections are in a musician's terms; the correctness panel says that the meters
  are held against the EBU's own reference cases rather than listing what a
  continuous-integration run asserts and in what units; and **Known gaps carries
  the six a musician will actually meet** — no Pro Tools plugin, metering the
  system's output takes all of it, the plugin needs the app running beside it —
  in place of two that only meant something to a contributor, one of which had
  also been wrong since releases started being signed. All of it is still stated
  in full in `README.md` and `docs/METRICS.md`, which is where a reader has asked
  for it.
- The documentation pages mark the section you are reading again. The list on
  the right was driven by an `IntersectionObserver` watching a band of negative
  height — nothing intersects one of those, so the callback ran once as the page
  loaded and never again, and every page marked its first heading and held that
  mark to the end. It reads the scroll position directly now, once per frame.
- Four things about how the documentation is set. A code listing has space above
  it again: the rule removing the browser's own block margins outranked the one
  that spaces every other block, so a listing stood flush against the sentence
  introducing it. The `#` beside a heading sits in front of the words rather
  than a line above them, and is drawn in the accent it declares rather than in
  the heading's own white. And the first column of a metric table fits its
  names — it had been sized from a width that let `Correlation` break in half
  while the sentence beside it took the room.
- `packaging/ios/screenshots.sh` renders the App Store screenshots, and
  `packaging/ios/app-store.md` holds the listing text beside them. The pictures
  are of the application metering real music rather than a test tone: a
  simulator app binds the host's own loopback, so the fake DAW in
  `plugin/host/` plays a track through the real plugin into the port the
  application already listens on, and every reading in them was measured by the
  engine.

## [0.10.1] — 2026-08-23

### ⚡ Changed
- The name under the application's icon is **Audio Analyzer** on iPadOS and
  Android, where it was `OAA`. A home screen gives a label about eleven
  characters before it starts dropping the spaces out of one, so the full name
  has never fit there and the initials went in instead — which read as an
  acronym nobody outside this repository knows. Nothing else is renamed: the
  bundle identifier, the window title, the installers and the desktop builds
  are untouched, so no permission grant moves with it.

### 🐛 Fixed
- The documentation site's sitemap names the eight documentation pages as well
  as the front page. It had named the front page alone since before the manual
  was part of the site, so nothing but the home page was being offered to a
  search engine that asked.
- The version on the site's download button is read from `pubspec.yaml` at
  build time. `src/lib/app.mjs` was written to do exactly that and then had no
  importer at all — both pages still carried the number as text, so the button
  was correct only for as long as nobody tagged anything.

### 🚧 Internal
- The site's demos replay what the engine measured instead of playing a mock.
  `website/tools/oaa_record/` is a Dart CLI that links the real engine by FFI,
  pushes forty-five seconds of a real track through it and writes down the
  readings; `website/tools/oaa_replay/` holds that format and `ReplaySource`,
  a fourth `MeterSource` beside native memory, the socket a tablet reads and
  the mock this replaces. Both Flutter targets play the same recording, so the
  fourteen stills and the live canvas can no longer disagree about what the
  material did — and no reading on the site is invented any more. The track is
  CC BY 3.0 and is not in this repository: `npm run record` refuses to run
  without the attribution file `tool/fetch_test_audio.dart` writes, because the
  licence asks for the credit wherever the audio is published, and the front
  page carries it under the canvas.
- `npm run check` in `website/` opens every page at 360, 390 and 768 px with
  the viewport actually overridden and fails if the document scrolls sideways,
  naming the widest element rather than the overflow. It is the one responsive
  defect that is invisible in a screenshot and obvious on a phone, and a
  browser window cannot be dragged narrow enough to show it. Not part of
  `npm run build`, because it needs Chrome.
- The front page's hero is one column and a measure wide rather than two, and
  the section rail in the manual tracks at 0.08em so that the longest heading
  fits on one line in the 215 px it has.
- Claude Code's `.claude/` is ignored. Its `settings.json` named a hook by an
  absolute path inside one developer's home directory, which would have failed
  silently on any other machine.
- The website's tab icon survives a run of the icon generator.
  `packaging/icon/make_icons.dart` wrote the app icon's tile over
  `website/public/favicon.svg`, which is a different drawing on purpose — the
  wave cropped out of the tile and stroked in the signal colour, because a tab
  shows it at 16 px where the tile is mostly ramp. The hand-drawn version
  therefore lasted until the next run of the generator and was reverted with no
  error and no diff anybody read. The generator no longer writes that one file,
  and says why where the line was.
- `website/public/oaa.svg` is back. It is the app icon's tile, written by the
  generator, and `scripts/og.html` references it rather than holding a copy of
  the mark; it was deleted in the change that redrew the logo while that
  reference stayed, so the Open Graph card had been pointing at a missing file.
- `website/AGENTS.md` describes the directory as it is: the documentation pages
  and the two lists that decide what they are, the live analyzer and the mock
  the two Flutter targets share, and why `tools/` is outside the repository's
  analyze gate. Its file table had been an inventory of a website that no longer
  existed — three files it named were gone and eighteen it did not name were
  there.
- `CLAUDE.md`, `assets/AGENTS.md` and `tool/AGENTS.md` no longer say that
  `tool/docs.dart` renders the documentation site. It renders one redirect per
  page now, and the manifest it used to carry lives in
  `website/src/lib/docs.mjs`.

## [0.10.0] — 2026-08-22

### ✨ Added
- A skin editor. Settings → Appearance → **Edit skin** opens all thirteen colour
  roles with a picker on each, and the canvas behind the panel repaints as you
  drag — as does a tablet mirroring the session. Every role prints its contrast
  ratio against the surface it is read on, and the ones below the floor that
  role is held to are marked with the reason; a low-contrast palette still
  saves, because refusing to save what is already on screen is worse than a
  warning. Skins remain plain JSON files and hand-editing them is unchanged.
- Skins can be deleted from the editor, which previously meant finding the file.
- **Reset**, beside Edit on Settings → Meters → Delivery target, deletes every
  target you have saved and puts the built-in six back. It asks first, in a
  dialog naming what goes, and afterwards says how many files it removed.
  Targets you wrote by hand are gone from the disk, so this is also how a
  correction to a built-in is undone without going looking for its JSON file.
- The VU Meter marks where the needle reached. A mark rides the scale at the
  loudest point of the last second and a half and then falls back to the
  needle, because a 300 ms movement is slow by design and the loudest moment of
  a phrase is over before the needle has finished describing it. It is the same
  quantity the needle draws, held rather than measured a second time.
- The VU Meter prints its reading and its reference along the bottom of the
  face: the deflection in VU on the left, and which dBFS level reads as 0 VU on
  the right. The second one is the genuinely confusing thing about a VU meter
  and the face now says it out loud. A module too small for either drops it and
  keeps the dial.
- **The Spectrogram and the Oscilloscope can be drawn in full colour.**
  `Colour: Full RGB` in either module's menu replaces the skin's one-hue ramp,
  and what it paints is the quantity that module's axes leave uncoloured. On the
  Spectrogram that is the **level**: the spectrogram rainbow, indigo through
  green and yellow to red and white, which separates far more steps of level than
  one hue can. On the Oscilloscope it is the **band balance**, because a waveform
  has no frequency axis at all: red, green and blue are its bass, its mids and
  its highs, split at 200 Hz and 2 kHz, so a kick is red, a hat is blue and a
  full-spectrum hit is white, the way DJ software has coloured audio for twenty
  years. That balance is taken in decibels against the loudest of the three bands
  rather than in power — bass carries an order of magnitude more power than air
  does, and a power mix draws every piece of music red — and it is recorded with
  the column, so the picture holds its colours instead of being repainted by
  whatever is playing now. A column whose source published no spectrum keeps the
  accent rather than being handed a colour that would claim a balance nobody
  measured. **Off by default in both**, because a rainbow reads as more precise
  than the measurement behind it, it collapses for the eight percent of men who
  cannot separate red from green, and on the Spectrogram it brings its own dark
  ground into a light skin. Nothing measured changes at either setting: no
  reading, no report and no byte on the wire moves.

### ⚡ Changed
- **A menu marks the value it holds by recessing that row, not by brightening
  it.** Every dropdown in the application — the delivery target, the signal
  source, and a module's dozen settings — used to print its current value as the
  lightest row in the menu, which put the emphasis on the one choice pressing
  cannot change and left the options you can still take looking greyed out. The
  chosen row now sits in a darker well and the alternatives sit on the menu's
  own surface, which is how selection reads everywhere else in the interface.
  Nothing about what the menus contain or choose changed.
- The signal source in the status bar is a bordered chip, the same shape the
  delivery target beside it has always had. It is the menu people open most and
  it was drawn as a dot and a bare word in a row of bordered controls, which
  reads as a caption rather than as something you can click. The dot stays,
  inside the chip: bright while something is being metered, dim on Silence.
- **The `OAA` wordmark is gone from the status bar.** The window carries the
  application's name; the bar carries what changes while you work, and three
  capitals that never change were the one item in it saying nothing about the
  signal. Every width at which the bar drops an item moved with it — the
  controls at the narrow end now leave 25 to 40 px earlier than they did,
  because a bordered chip cannot give back the width a bare word could. All of
  them still have keyboard shortcuts except the three remote controls, which is
  unchanged.
- The sample rate no longer prints flush against the DAW's playhead. The gap
  between the source group and the readings is a fixed one now rather than
  whatever the window had left over, so it is there at every width instead of
  only on a wide one.
- The VU Meter has a face. The scale is a band along the rim rather than a
  hairline arc, red above 0 VU over a tinted ring, and the needle is a taper
  under a machined hub — so how far up the scale the programme is can be read
  from the rim before the needle is read at all. Nothing about the movement,
  the ballistics or the reading changed.
- The Loudness Distribution fits its loudness axis to the programme instead of
  always drawing −60 to 0 LUFS. A mastered programme's gated distribution
  occupies eight to fifteen of those sixty decibels, so the picture the LRA
  reading is taken from was squeezed into a fifth of the module with the rest
  left blank; the axis now holds every occupied bin, the gated range and the
  delivery target, rounds outwards to whole ticks, and stays where it is until
  the distribution grows past it. No reading changes — the same bins are drawn
  against a shorter stretch of the same scale. `Scale: Full range` in the
  module's menu restores the published axis, which is the one to pick when two
  distributions are being compared side by side.
- **Open Audio Analyzer has a new logo, and every icon it ships follows it.** A
  white waveform on a teal ramp, replacing the four teal bars on graphite. The
  app icon, the installers' icons, the Android launcher icon, the layered icon
  macOS and iOS render, the favicon, the documentation site's header, the
  README and the social card all change together. The tile is also a rounder
  shape than it was, because the one macOS 26 and iOS 26 draw is rounder than
  the one every version before them drew. Nothing about what the application
  measures or displays is affected.
- The icon reads less well at 16 px than the one it replaces, and that is a
  real cost rather than an oversight. Four bars at four heights survived being
  two pixels wide; a waveform with nine excursions across twelve pixels does
  not, and no stroke weight rescues it. The line is held at one device pixel so
  that it stays white instead of smearing to grey, and the sizes the icon is
  now designed around are 32 px and up. Where this shows is the Windows
  Explorer list view and a Linux panel at its smallest setting.
- **Precision Instrument and Daylight can no longer be replaced.** A skin file
  naming one of their two ids used to shadow the built-in; it is now ignored,
  and the skin editor offers *Save as new* rather than an in-place save. The two
  shipped skins are what proves the thirteen colour roles are semantic rather
  than aliases for particular colours, and a reference point a file on disk can
  quietly redefine is not one. **If you had such a file it is inert now** —
  rename its `id` and it comes back as a skin of its own. Delivery targets are
  unaffected and still shadow their built-ins, because a target is a claim about
  somebody else's published specification and has to be correctable without a
  release.

### 🐛 Fixed
- The VU Meter no longer draws a needle for a reading nobody measured. The
  per-channel arrays are NaN while a remote display's link to the host is
  quiet, and the dial rested at the bottom of its scale with exactly the
  confidence it reads a quiet passage with; the face now shows no needle and
  the reading is an em dash. Only a tablet display could reach this.
- The VU Meter's scale numbers no longer overprint each other on a small
  module: −5 and −3 sit close together on a face that crowds towards the bottom
  in voltage, and at the narrowest widths they collided into one smear. The
  face now sheds the numbers it has no room for, keeping 0 and both ends.
- **A panel that scrolls draws one scrollbar rather than two.** Settings, and
  every other panel tall enough to scroll, carried the skin's own thumb on its
  right edge and a second, wider grey one immediately inside it, which faded in
  whenever the panel was scrolled. The second was supplied by Flutter, which
  decorates a scrolling region on macOS, Windows and Linux without being asked;
  the panel now declines it. Tablets never showed it.
- **The Super Meter's target tick sits in its slot again.** The slot is a
  surround laid down under the tick so that its contrast is identical on all
  three rings, whatever each ring is currently drawing; it was being stroked at
  exactly the tick's own width, so the tick covered it completely and was read
  against the arc after all. It stands 1.5 px out either side now, which is what
  the constant describing it always said. The tick itself is unchanged.

### 🚧 Internal
- The skin editor's suite waits for the *effect* of a save rather than for the
  file. Its helper stopped as soon as the skin's file existed, which is one
  event-loop turn before the editor is told the write finished — so the four
  assertions about what saving then selects raced the disk, and won on a Mac and
  lost on the Linux runner every time.
- `flutter analyze` no longer walks `website/tools/`. The two Flutter web
  targets that render the real modules for the site now share the mock
  `MeterSource` as a package rather than each holding a copy, and a
  `package:oaa_mock` import needs package resolution where the relative one it
  replaced needed none — so on any machine that had not run `pub get` inside
  each of them, which is every CI runner, the repository's analyze gate failed
  on eight unresolved references in code that no gate builds. They are excluded
  in `analysis_options.yaml` and analysed by their own.
- The remote display's skin frame is rate-limited to one every 150 ms, with the
  last value always delivered. Dragging a colour in the new editor produces a
  palette per pointer move, and those frames are queued rather than dropped —
  unthrottled they grew that queue for as long as the pointer was down.
- The artwork and the program that renders it swapped places.
  `assets/brand/oaa-logo.svg` is now the drawing, hand-edited, and
  `packaging/icon/make_icons.dart` reads it; previously the mark was four
  rectangles described as numbers in that program and every vector in the
  repository was a hand-copied transcription of them, kept in step by a rule
  saying the mark changed there first and was brought across afterwards. That
  rule does not scale to a path with three hundred control points. The program
  now also writes `packaging/icon/oaa.svg`, the rest of `assets/brand/` and the
  website's icons, which removes the last four files anybody kept by hand.
- `make_icons.dart` grew a path rasteriser — an SVG path parser, a cubic
  flattener and a scanline fill — because the mark is a stroked cubic path and
  the old renderer only knew rectangles. Still no dependencies. The stroke is
  drawn as the union of a rectangle per segment and a disc per vertex rather
  than by offsetting the outline, which is the same shape and is not a research
  problem.
- The tile's corner is measured rather than remembered. Three macOS 26 system
  icons were rendered through `NSWorkspace`, thresholded to a silhouette and
  fitted: a corner of a third of the side on a superellipse of exponent 2.7,
  where the shape Apple drew from iOS 7 to iOS 18 was 22.37% on an exponent
  near 4. The first cut of this release used the remembered numbers and looked
  visibly square next to everything else in the Dock.
- The documentation site serves its favicon as a file instead of inlining it
  into every page as a data URI. The mark was a few hundred bytes when that
  choice was made and is three kilobytes now, which across twenty pages was a
  hundred kilobytes of the same icon.

## [0.9.0] — 2026-08-22

### 📐 Measurement
- **7.1 material reads 0.35 LU quieter, and correctly.** The +1.5 dB surround
  weight was applied to every channel past the LFE, so a 7.1 stream had it on
  the rear pair as well as the side pair. BS.1770 gives it to the surround pair
  only — Report ITU-R BS.2217's channel table states 7.1 as
  1.00 / 1.00 / 1.00 / N/A / 1.41 / 1.41 / **1.00 / 1.00** — and the ITU's own
  two 7.1 compliance files read 0.35 LU high against a ±0.1 tolerance until this
  was fixed; they now read −23.000 and −24.000 exactly. **Only 7.1 and wider is
  affected**: mono, stereo, quad, 5.0 and 5.1 never reached the arm that was
  wrong, and every reading from them is unchanged. Anything measured from a 7.1
  master — its `LUFS-I`, `LUFS-M`, `LUFS-S`, `LRA` and the delivery verdict
  drawn from them — was 0.35 LU too loud and is worth re-measuring.
- **`Max M` and `Max S` are found on a 10 ms grid, where momentary and
  short-term loudness previously advanced only every 100 ms.** The official EBU
  test vectors caught this: Tech 3341 tests 13 and 14 slide a 400 ms tone —
  exactly one momentary window long — through twenty files in 20 ms steps and
  require `Max M` within ±0.1 LU of −23.0 every time. On a 100 ms grid a tone
  offset by anything else never lies inside one window whole, so sixteen of the
  twenty read low, by up to 0.45 LU, and test 14 by 0.70. Every `Max M` and
  `Max S` therefore rises rather than falls: on the EBU's two authentic
  programme segments `Max M` rises by 0.16 and 0.11 LU and `Max S` by 0.02 and
  0.01, and a transient that fell between the old grid points can rise by up to
  0.7 LU. **`LUFS-I`, `LRA` and its percentiles, `TP Max` and `Peak Max` are
  unchanged** — identical to three decimals across all 70 files of the test set
  — because both gating windows are still filed every 100 ms, which is the 75%
  overlap BS.1770 asks for. Re-read a delivery decision that turned on `Max M`
  or `Max S` against a ceiling; one that turned on the integrated numbers stands.
- **The spectrum analyser draws its bands tilted, at 4.5 dB per octave by
  default.** The curve is rotated about 1 kHz, so 20 Hz is drawn 25.4 dB lower
  than it measures and 20 kHz 19.4 dB higher — 44.8 dB between the ends of the
  range, where previously the drawn level was the measured level at every
  frequency. It is a view: the offset is added per band at the moment of
  drawing, and `Spectrum` and `Spectrum peak` are published and sent over the
  wire exactly as the engine measured them, so nothing needs re-measuring. What
  changes is that a level read off the analyser's own dB scale is only true at
  1 kHz now, which is why the module prints the tilt it is drawing at and why
  `Tilt: 0 dB/oct` — where the scale is true everywhere — prints nothing.
- **The analyser's peak-hold line holds the drawn curve rather than the raw
  bands.** It is the highest the curve has been, held for a second and a half
  and then let down at 12 dB a second, which is the schedule the engine's own
  per-band hold already followed. Two consequences: the line moves with the
  curve instead of jumping to a peak the curve is still easing towards, and on
  `Response: Slow` it reads *lower* than it used to — by as much as the pole
  smoothed the transient away — because the curve it is holding never went
  there. `Response: Fast` holds every published frame and is the setting to
  find a click with. `Spectrum peak` itself is unchanged.
- **The histogram draws both of its bands averaged over a second, where it
  previously drew every 100 ms column exactly as measured.** `Smoothing` in its
  menu chooses Off — the old picture, byte for byte — Light at 0.5 s, Normal at
  1.0 s or Broad at 2.0 s, and **Normal is the default**. The window is centred
  rather than trailing, so nothing moves along the time axis; what it costs is
  height on a short event. A transient the momentary band reached for a single
  column now reads lower by roughly the distance between that column and its
  neighbours — a 6 LU spike over a steady body reads about 1 LU above it on
  Normal — and the newest column at the right edge lags the live meters by up to
  half the window, settling as it ages. Nothing measured changes: the ring holds
  the columns as they arrived, the smoothing is applied on the way out every
  frame, and reports, the wire protocol and every other loudness module are
  untouched. Choose Off to find the loudest 100 ms in a programme.
- **The loudness distribution's fill no longer double-draws itself.** Each of
  the 120 published bins was stroked half a pixel wider than its own spacing to
  keep butt caps from leaving seams, so every overlap was composited twice
  through the translucent gradient — a brighter line at all 119 bin boundaries,
  and on a default-sized module nearly a fifth of the fill drawn at double
  alpha. The bins are unchanged and none of them moves; what changes is that the
  drawn area is now a shape rather than a row of overlapping lines, and a column
  covering more than one bin takes the loudest of them rather than blending
  them, the way the engine already maps transform bins into spectrum bands.

### ✨ Added
- **The oscilloscope locks to the DAW.** `Sync: Tempo` makes the width a
  musical division — 4 bars down to 1/32, straight, triplet or dotted — and
  puts every sample in the column its position in the bar falls in, so each
  pass overwrites the last in place and a kick is drawn in the same spot every
  bar. The graticule divides into beats rather than tenths while it is locked,
  and the corner says which division is on screen. It uses the host's own
  playhead, tempo and time signature, which the plugin already forwards: MIDI
  clock carries neither a bar position nor the accuracy, and is not involved.
  A source with no playhead — a sound card, or a DAW that reports none — draws
  the free window and labels it as the free window, because a display that
  said `1 bar` over something else would be worse than one that is not synced.
- **The spectrum analyser has a tilt**, `Tilt` in its menu: 0, 1.5, 3, 4.5 or
  6 dB per octave, rotated about 1 kHz. Programme material falls with frequency
  at something like 3 to 4.5 dB an octave, so an untilted analyser draws every
  mix ever made as the same ramp — bottom octaves against the ceiling, top
  octaves crushed into the floor — and spends most of its height on the one
  part of the picture that carries no information. Tilted, a mix is roughly
  horizontal and what is left is the deviation. The analyser prints the tilt it
  is drawing at, because a dB scale quietly rotated across its width is worse
  than no scale at all.
- The oscilloscope draws a stereo signal either as two lanes or with both
  channels around one centre line, from `Stereo` in its menu. Overlaid, the
  two are told apart by weight rather than by colour, and the trace gets the
  whole height of the module — which is the arrangement that shows what the
  channels are doing *differently*.
- **The oscilloscope can be triggered by a transient.** `Trigger: Transient`
  makes the display wait, armed, until the signal rises through a level you set,
  draw forward across the whole width once from that sample, and hold what it
  caught until the next crossing. It works at every time base — the roll above
  200 ms is replaced by the sweep rather than left in place — so the attack of
  one kick can be looked at instead of a picture that lands somewhere different
  every pass. `Trigger: Off`, which is the default and what the module did
  before, is unchanged: a rising zero crossing below 200 ms, a rolling display
  above it, and always something on screen. A threshold nothing reaches leaves
  the last capture where it is, which is the mode working rather than failing.
  `Trigger` stays in the module's menu under `Sync: Tempo`, greyed rather than
  dropped: a bar-locked window is placed by the bar line and has no use for it,
  and a row that vanishes is a row somebody hunts for. `Grid` is now greyed
  under `Sync: Free` for the same reason instead of being dropped — there is no
  triplet of a millisecond.
- **The oscilloscope's height and trigger threshold are sliders on the
  module**, `HEIGHT` and `THRESHOLD` in a strip along the bottom of the plot,
  and the threshold is drawn across the lane at the height it is set to. Both
  are numbers over a wide range that are chosen by watching the waveform while
  they move, and a menu that closes over the waveform on every step cannot be
  used for that. The height goes from 1x to 32x, continuously rather than in
  named steps — a reverb tail thirty decibels under full scale is a flat line at
  1x, and the setting that fits the material is rarely a round multiple. The
  strip is dropped on a module too short to spare the room, like the graticule
  and the lane letters, and is not drawn on a remote display, which has no
  layout to write to. Nothing measured changes: a sample is still marked as
  clipped only if it reached full scale, and a trace that runs off its lane is a
  trace that is zoomed.
- **`AUTO` beside the threshold takes it from the loudest transient.** It
  follows the largest positive excursion of the mid signal over the last two to
  four seconds — the quantity the trigger itself compares against — and sets the
  threshold six decibels under it, which is half the amplitude and so still
  inside the attack: the sweep starts before the transient rather than on top of
  it, which is what a threshold set exactly *at* the peak would do. The slider
  shows where the level has got to and stops answering while the box is checked;
  unchecking it keeps the number Auto found rather than snapping back to
  whatever was dragged before. Silence moves nothing — a passage nobody played
  is not a measurement, and a threshold dropped to the floor would arm the
  trigger on the noise underneath it.
- **The histogram has a `Smoothing` setting** — Off, Light, Normal or Broad. See
  the Measurement note above for what each one does to the picture and why the
  window is centred rather than trailing.
- **The loudness distribution prints LRA.** The module drew the picture behind
  the number for two phases without ever showing the number, so reading one off
  it meant putting a Number Box beside it. It is now on the bracket across the
  top, which is the distance the reading *is*.

### ⚡ Changed
- **macOS 14.2 is now the stated requirement for the application, the VST3 and
  the Audio Unit**, where the application claimed 10.15 and the plug-ins 11.0.
  Nothing is lost that worked: neither could load below 14.2 at all — see the
  Fixed entry. The installer refuses the volume under 14.2 rather than gating
  its plug-in rows, because there is no longer a version that can run one
  component and not another.
- **Nothing crosses the loudness distribution's plot except the target.** The
  10th and 95th percentiles were two full-height lines at the reading weight,
  and on steady material they and the dashed target line piled up within a few
  pixels of each other over the bars. The percentiles are now a bracket across
  the top strip carrying the LRA reading, with short end marks at the top and at
  the axis and the gated range shaded between them — so the distribution is the
  only thing in the plot, and the target, which is the one line the user chose,
  is the only line through it. The `10%` and `95%` labels are gone: the bracket's
  ends are those percentiles and the number on it is the distance between them.
- **The loudness distribution's annotations are painted over the bars rather
  than under them.** The percentile marks and their labels were drawn before the
  fill, so the translucent gradient was composited on top of the part of the
  module meant to be read first.
- **The settings panel says what the source list actually offers.** The note
  under the device picker still read "input devices only" and told macOS users
  to install BlackHole, sitting directly beneath a picker that has offered
  **System Output** since 0.8.0 — so the one sentence read at the moment of
  choosing said the feature was not there. It now names what each platform does,
  and says that macOS asks permission and reads silence if it is declined.
- **Upgrading from 0.5.0 or earlier is documented as revoking every macOS
  permission, not just Local Network.** The bundle identifier moved in 0.6.0 and
  macOS keys permissions to the identifier, so Microphone, Camera and System
  Audio Recording were revoked as well. System Audio Recording is the one worth
  checking first, because Apple's refusal of it is silent — see the install
  page.
- The page switcher on a remote display's link bar sits at the right-hand end
  of the bar, beside `Disconnect`, where it used to sit between the host's name
  and its playhead readout. It no longer moves when the host gains or loses a
  DAW, or reports a tempo where another reports only a clock.
- The iPad display needs iPadOS 15 or later, where it previously needed 13.
  Apple stops accepting uploads built against anything below 15 in Spring 2027
  and warns on every one until then, so the floor moves now rather than in the
  release that would otherwise have been refused. **No iPad loses the display
  by this.** iPadOS 13, 14 and 15 support exactly the same devices — every model
  back to the iPad Air 2 and the mini 4 — so what this excludes is an iPad that
  has not been updated, not an iPad that cannot be.
- Disconnecting a remote display lands back on the view it was opened from,
  rather than leaving the host picker on the screen. Leaving a display used to
  put it in its no-host state, and that state *is* the panel that asks which
  machine to attach to — so the one control marked as the way out asked a
  question instead of answering one. A display with nothing behind it, which is
  a tablet that opened straight into one, still lands on the picker, because
  there is nowhere else for it to go.
- The phase scope's correlation bar and the super meter's three rings have
  rounded ends. On the bar the fill is clipped to the same corners, so ±1 fills
  the rounded tip rather than sitting square over it. On the gauge it is the
  *scale* that is rounded, at both extremes of the sweep: a reading's own moving
  end stays square, because a round tip is half a ring of ink standing past the
  number it points at, which on that scale is most of a decibel nobody measured.
  The M, S and I names step a little further round the open end to keep their
  clearance from ink the rings did not have before.
- **Everything drawn against the delivery target is red above it.** The LUFS
  meter's momentary and short-term bars and the super meter's three arcs are
  now cut at the target and drawn in `over` past it, where they were one colour
  from the floor to the reading. The histogram and the loudness distribution
  already split at the target and already used `over`, so their picture is
  unchanged. One rule in four modules, and red is the single mark for past the
  number you set. The cut is a clip at the target rather than a verdict on the
  whole shape, so what it shows is how much of the reading is over — a momentary
  peak 3 LU above a −14 target is three quarters grey with a red cap, not a red
  bar.
- The histogram's outline turns red past the delivery target, where it stayed
  the accent colour across the whole programme. The fill under it already split
  there, so the line the eye lands on ran one colour straight through the
  boundary and disagreed with the area it bounds. Cut at the target like
  everything else, on the same pixel row as the fill.
- **The super meter's innermost ring no longer turns entirely red when the mix
  is over its target.** The ring takes its verdict's colour for its whole
  length — which is what makes an in-spec reading a green ring rather than a
  green tip — and once over-target became a red verdict that meant the arc ran
  red from the bottom of the scale to the reading, with its own target tick
  stranded in the middle of it and the same colour on both sides. At −11 against
  a −14 target, three quarters of the arc claimed to be over when a quarter of
  it was. It is now drawn like the other two rings: neutral up to the target,
  red past it, so the red segment is the size of the miss. In spec it is still
  green end to end, and the centre readout is red either way.
- **The super meter's three target ticks read as one mark, and are drawn at 3 px
  rather than 2.** The same grey on three rings is not the same *appearance*:
  the backdrop at the target is the track on a ring that has not reached it,
  that ring's fill on one that has, and red on the far side of the line —
  measured at L* 24, 39 and 51 in one ordinary frame, so a single grey stood
  +36, +21 and +9 above what surrounded it and read as three different greys. No
  choice of shade fixes that, because the backdrop moves with the audio, so each
  tick is now laid in a slot of the meter's own track colour — the mark reads as
  cut back to the empty scale, and a ring that has not reached the target shows
  no notch at all, because there is nothing there to cut. Local contrast is +36
  on all three rings at every reading and under every skin. The extra weight is because the mark is *radial*: antialiasing
  spreads it across two pixel columns where an axis-aligned rule lands on whole
  ones, and it now has red on one side of it as well.

### 🐛 Fixed
- **A mix over its loudness target is red in the Number Box and the Alert Meter,
  where it used to be drawn as a reading with no opinion.** `LUFS-I` past the
  target and its tolerance returned a neutral state, so the delivery report
  called the same mix a failure while the meter beside it printed the number in
  plain text — and the bars and arcs that cut at the target now paint that
  region red, which made the disagreement plain. Under the target is still
  neutral: quiet is not over. Amber is unchanged and still means approaching —
  true peak inside the last decibel before the ceiling is the case it exists
  for. The rule now has a test; it had none, which is how this stood for eight
  phases.
- **The macOS application and its plug-ins load again on every macOS they claim
  to support, and the floor is now 14.2.** The engine holds a strong reference
  to `CATapDescription` — the Core Audio class behind System Output — and a
  strong reference to a class that does not exist is a library dyld cannot
  resolve. Below macOS 14.2 the *entire* engine library therefore failed to
  load, so the application died at launch and a DAW found the plug-in absent,
  on every version between the old floor and 14.2. Nothing degraded to "no
  system capture"; it was all or nothing. The application previously declared
  10.15 and the plug-ins 11.0, both of which were promises the binaries could
  not keep, and the library itself was being compiled at 13.0 by a build flag
  that ignored either setting. All three are 14.2 now, `engine/src/oaa_tap.h`
  fails the build if any of them is lowered again, and the five
  unguarded-availability warnings the old floor produced are gone.
- **The super meter's target ticks read as marks rather than as rendering
  artefacts.** All three are drawn at the emphasis weight now. They are radial,
  so unlike every other target mark in the application they cannot be drawn with
  antialiasing off and land on whole pixels — at the mark weight the same 1.5 px
  was spread across two pixel columns at about half the alpha each, which is a
  deliberate annotation with half the contrast of the ones it was matched to.
- **Backspace, Delete and the arrow keys work inside the tab rename field.**
  Renaming a tab, the keys that edit text did nothing at all: Backspace and
  Delete are bound to "delete the selected module" and the arrows to "move the
  selected module", and the guard that was supposed to stand these aside while a
  text field has focus was checked one layer too late. `CallbackShortcuts`
  reports a key handled the moment its activator matches, whatever the callback
  then decides, so the keystroke was consumed and never reached Flutter's own
  text editing bindings. Typing was unaffected throughout, which is why this was
  easy to miss and infuriating to hit: a name could be entered but not
  corrected. The guarded chords are now absent from the map while a field has
  focus rather than present and declining.
- **An alert meter's latch can be cleared again after the source has gone
  quiet.** The latch holds the worst reading since the last reset and is cleared
  by the elapsed clock running backwards, which is what a reset looks like. A
  link that goes quiet reports its elapsed time as "not a number", that value
  was stored, and every later comparison against it was false — so the lamp
  stayed lit for the rest of the session, across every source selected
  afterwards. It now ignores a non-number rather than remembering one.
- **A remote display no longer receives one frame of the previous source's
  audio.** The waveform collected for the tablet was not dropped when the
  desktop switched sources, so up to one publish interval of the old
  programme was sent spliced onto the front of the new one's first frame — a
  join the display had no way to know about.
- **The oscilloscope's trace no longer comes apart at short time bases.** From
  about 20 ms to 100 ms across the width, one or two samples land in each
  column of the display, so each was drawn as a dot a pixel tall with nothing
  joining it to its neighbours — a waveform that arrived on screen as a dashed
  line. Columns now reach to the one before them, which draws the connecting
  line a per-sample trace would have drawn anyway, and the picture is snapped to
  whole pixels so its density no longer flickers sample by sample. Below 10 ms,
  where the display is one point per sample, the trace is a single joined
  polyline instead of a segment per sample; independent segments were composited
  independently and the line read as chewed.
- **The Super Meter's arcs no longer step ten times a second.** Momentary,
  short-term and integrated loudness advance on the engine's 100 ms gating
  grid, and the meters repaint at about 47 Hz — so four frames in five drew the
  arcs exactly where the frame before had left them and the fifth jumped, which
  on a gauge that size reads as an instrument stuttering. The arcs now travel
  between readings over 50 ms, which is half the gap between them and an eighth
  of the shortest window any of the three measures. **No reading changes**: every
  number the module prints, and the pass or fail colour it takes, is the
  measurement drawn the frame it arrives.
- The playhead and the elapsed clock in the status bar are packed left, like
  the pair on a remote display's link bar, and the gap between them is the
  same seam as every other one in the row. Both used to sit in boxes reserved
  for the widest thing they could ever print — a drop-frame timecode, eleven
  glyphs — so a host counting bars left 56 px of nothing beside its own counter,
  and the elapsed clock another 14. The boxes are the width of what is in them
  now.
- **The rule between items in a menu is no longer drawn in pure white.**
  Material's `outlineVariant` — the colour a Material 3 divider actually reads
  — was never named in the theme, and a `ColorScheme` role left unset falls
  back to a *foreground* colour: `#FFFFFF` under a dark skin and `#000000`
  under a light one. So the rules in the signal-source menu were brighter than
  any colour a skin defines and brighter than the text beside them. They are
  the hairline every other division in the application uses, at the graticule
  weight rather than the border weight so they still read against the raised
  surface a menu is drawn on.
- A module's settings no longer look like entries that cannot be chosen. The
  `Metric`, `Response` and `Time base` rows in a module's menu were drawn in
  muted text to mark them as settings rather than actions, directly above a
  `Duplicate` at full brightness — which is what a disabled item looks like
  everywhere else in the interface, including in the menu one row up. They are
  the same colour as every other row now, and a rule separates them from
  `Duplicate` and `Delete` instead.
- A module setting reads `Time base: 50 ms` where it read `Time base — 50 ms`.
  An em dash between a setting and its value is the punctuation this interface
  uses for a value that was never measured, and a menu row is the one place
  that reading is available.
- **The oscilloscope on a remote display draws a continuous waveform.** It
  could not before, at either of the two slower link rates, and the reason was
  structural rather than a slip: a snapshot carried one analysis block — 1,024
  frames, 21.3 ms at 48 kHz — while a link at 30 Hz stands for 1,600 frames of
  audio and one at 15 Hz for 3,200. The module worked out how much audio had
  elapsed, correctly concluded its buffer was no longer contiguous, and cleared
  it. On every single frame. Nothing logged anything and no test failed; it
  simply would not draw, and only the 60 fps rate escaped it. The host now
  accumulates what it measured between two sends and says how much that is, so
  the trace is continuous at 15, 30 and 60. Above 48 kHz on the slowest rate
  more audio can elapse than one frame may carry, and the shortfall is drawn as
  the gap it is rather than filled in.
- **A remote display honours the system's reduce-motion preference.** It
  ignored it entirely and redrew at 60 fps whatever the tablet had been asked
  for — the desktop reads that preference in its status bar, and a display has
  no status bar. It now caps at 30 fps when the platform asks, like every other
  screen. Choosing the display's own refresh rate from the tablet is still not
  possible; the setting exists but nothing on that screen writes it.

- **The phase scope costs less than half what it did to draw**, which is felt
  on a tablet before anywhere else. It was 9.6 ms of rasterising per frame on
  an Apple Silicon Mac — over half a 60 fps budget for one module — and is now
  3.3 ms, from switching off antialiasing that a 1.4 px dot in a cloud of tens
  of thousands gains nothing from, and from drawing the dimmest half of the
  trail more sparsely than the half you actually read. The trail is the same
  length, fades over the same time, and is still computed exactly rather than
  compounded through an 8-bit surface. The figure it draws is unchanged; the
  faintest edge of the cloud is very slightly sparser.

- **A remote display uses less than half the network it did.** The measurement
  frame is 7,648 bytes where it was 15,056, so a tablet at the default 30 Hz
  link rate now costs about 230 kB/s instead of 452 kB/s, and 406 kB/s instead
  of 904 kB/s at 60 Hz. The five arrays that exist only to be drawn — the
  spectrum, its peak hold, its pan, the scope and the histogram — travel as
  fixed point instead of 32-bit floats, at a resolution between two and four
  orders of magnitude finer than the pixels they land on. **No number you read
  changes**: every scalar, and the per-channel peak, RMS, VU and clip figures,
  are carried exactly as before. This is wire protocol version 4, so a tablet
  and a desktop must be on the same release to link — a mismatch is refused at
  connect with a sentence naming both. A plugin already installed in your DAW
  keeps working with a newer app, as it did before.

  The waveform is the one thing that got *bigger*: it is now carried at the rate
  it was measured rather than one block a frame (see the oscilloscope entry
  under Fixed), which costs about 190 kB/s at 48 kHz whatever the link rate. Net
  of that, 30 Hz is still down by a third and 60 Hz by more than half; 15 Hz is
  the one rate that costs slightly more than it did, and it is the rate that was
  most broken.

### 🚧 Internal
- `packages/oaa_engine/test/vectors_test.dart` runs the two official vector sets
  through the decoder and the engine: the EBU Loudness Test Set — every case in
  Table 1 of Tech 3341 and of Tech 3342 — and the compliance material of Report
  ITU-R BS.2217. 112 cases, all passing, and each group skips unless
  `OAA_VECTORS` or `OAA_VECTORS_ITU` names an unzipped copy. Not a gate, because
  neither set may be redistributed here and fetching 811 MB would put the
  network in front of the one suite that must never be flaky; the generated
  cases in `conformance_test.dart` remain the gate, and now assert the 7.1
  weights too, since no official file can be committed to hold them. Both
  measurement entries above are what the first run found.
- The six ITU files wider than 7.1 — 10, 12 and 24 channels — are asserted to be
  refused rather than measured. The engine carries eight channels and has no
  weights for those layouts, so a number would be worse than an error.
- Decoding a snapshot was measured and cleared as a cause of a slow tablet:
  4 µs a frame against a 33,000 µs budget at the default link rate. It was
  briefly rewritten as nine block copies, eleven times faster and worth
  nothing; protocol version 4 then made that impossible anyway, because
  fixed-point arrays have to be converted element by element rather than moved.
  Recorded because the wire was the obvious suspect and was the wrong one —
  the cost was in a single module's rasterising, two benchmarks away.
- `tool/bench_wire.dart` and `tool/bench_modules.dart` measure the two halves of
  what a remote display costs — decoding a frame, and drawing it — with
  recording and rasterising reported separately, because they are different
  costs on different threads and the interesting one is not always the one
  being measured.
- `tool/bench_gpu.dart` measures the same modules on a real GPU, off the
  engine's own frame timings in a profile build. It exists because the software
  rasteriser `flutter test` uses overstated the phase scope by two and a half
  times and reordered the table under it — the module that needed the work was
  still the one at the top, but no figure from a software backend was worth
  quoting.
- Every benchmark now reports how many pixels it inked, and fails or says so
  loudly when that is none. The harness had drifted from the wire layout it was
  writing by hand and stopped drawing altogether, while still reporting timings
  that were low, stable and entirely plausible; it was caught by somebody
  looking at the window rather than by anything in the suite. The material is
  now built through the real encoder and decoder — `tool/bench_material.dart` —
  so there is no second implementation of the protocol to drift.
- `website/` holds `open-audio-analyzer.com`: a static Astro site, deployed by
  hand to Cloudflare Workers, in this repository rather than beside it because
  its content is derived from the code next to it. The numbers on its front page
  are measured at build time by `website/scripts/measure.mjs` rather than typed,
  and the fourteen thumbnails in its module catalogue are photographs of the real
  widgets, taken from `package:oaa` by `website/tools/module-renderer` — an
  approximation of a measurement display is the one picture this project should
  not publish. No job in `ci.yml` builds it or deploys it, and nothing in a
  release contains it.

## [0.8.0] — 2026-08-22

### ✨ Added
- An **Oscilloscope** module: the waveform itself, in a lane per channel. Its
  one control is a time base, from 5 ms to 5 s, and it sets both how much time
  the width holds and how the window is found — below 200 ms the display is
  triggered on a rising zero crossing, so a periodic signal stands still and
  can be read, and above it the display rolls right to left the way a DAW
  draws a waveform. Anything that reached full scale is drawn in the over
  colour, so a clipped passage is a red band rather than a flat top somebody
  has to notice. It measures nothing the previous thirteen modules did not:
  the samples were already published, and it works on a tablet unchanged.
- The oscilloscope leaves a gap where audio was measured and never published —
  a file pushed through faster than real time, or a device that overran. The
  alternative is drawing the samples that happen to be at hand across the
  whole stretch, which is a picture of a programme that never played, at the
  right amplitude and in the right place.

### ⚡ Changed
- The default layout's Spectrum tab carries the oscilloscope across its full
  width. The analyser and the three displays below it are a row shorter each
  to make room. A layout you have already arranged is untouched — the canvas
  as you left it is what reopens.

### 🚧 Internal
- The meter clock now acquires the engine's snapshot on every tick and throttles
  only the repaint. The frame-rate setting still does what it says — at 30 fps
  the meters rasterise thirty times a second — but a measurement is no longer
  lost between two of them. The engine's snapshot has one slot, so anything a
  reader does not take before the next publish is gone; that cost the old
  arrangement one measurement in three at 30 fps against a 47 Hz publish rate.
  The oscilloscope is the first module for which that is a hole rather than a
  coarser picture, and it reads the new unthrottled channel.

## [0.7.0] — 2026-08-22

### ✨ Added
- Pairing a display by camera. The sending machine shows a QR code under
  the code button beside PUBLISH in its status bar, and a tablet reads it
  under Scan a QR code on the screen it opens with. It carries the address and
  the port and nothing else, so a display that scans one can still only watch.
  This is the route that works where discovery does not — a venue or a guest
  network that blocks multicast previously left somebody reading four numbers
  off a laptop across the room and typing them into a tablet.
- The pairing code names which network interface it is for, on a machine with
  more than one. A laptop on Wi-Fi with a dock has two addresses and only one
  of them may be reachable from the tablet, which is not knowable from the
  sending side.
- Scanning is offered on Android, iPadOS and macOS. Windows and Linux have no
  camera implementation, so the row is absent there rather than present and
  refusing; the typed address is offered on every platform, as before.
- The macOS, Windows and Linux downloads now install the plug-in for you, with
  a checkbox that starts ticked. macOS offers the VST3 and the Audio Unit as
  separate rows, Windows and Linux the VST3; unticking leaves the application
  on its own. Previously the plug-in was a bare archive and the instructions
  for placing it by hand ran to a screenful, most of which existed because a
  bundle in the wrong folder and a bundle that failed to load look identical
  from inside a DAW.
- A plug-in installed by the macOS package needs no `xattr` step. Files placed
  by an installer are not quarantined, so the Gatekeeper refusal that has no
  override — the one a DAW reports as "could not verify … is free of malware" —
  does not arise.
- The Windows installer registers an uninstaller under Settings → Apps, which
  removes the plug-in as well as the application.
- A third Linux download, a tarball, beside the AppImage and the flatpak. It
  is the only one of the three that carries the VST3: unpack it and run
  `./install.sh`, which needs no root and writes under your home directory
  unless you ask it for `--system`.
- The Linux tarball's `install.sh` is its uninstaller too, and takes `--vst3`,
  `--no-vst3`, `--system` and `--uninstall` for use without a prompt.

### ⚡ Changed
- **The remote display is reached from the status bar in one press, from
  either end.** `REMOTE` and the panel behind it are gone. In their place the
  bar carries a **PUBLISH** switch, a button beside it showing the pairing
  code, and **ATTACH**, which opens *Show another machine* directly. Publishing
  no longer takes three presses and a question about which end of the link this
  machine is — a question anybody pressing the button had already answered.
- The remote display's name, port, update rate and pairing code are now in
  Settings under **Publish**, with the rest of what the application remembers,
  instead of in a modal of their own. The section also states whether it is
  publishing and how many displays are attached, which the switch has no room
  to print.
- The name and port commit when the edit ends — on Enter or on leaving the
  field — rather than from an Apply button. Nothing else in the settings panel
  has one.
- The pairing code's button is disabled, rather than absent, while publishing
  is off. A code nothing is listening at is a display that scans, connects and
  times out, which reads as a broken feature rather than as a switch that is
  not on.
- The pairing-code mark is redrawn on Material's `qr_code` geometry: three
  finders and a scatter of data cells. The previous mark was five filled cells
  in a 3x3 grid, which reads as a dice face.
- A module's title bar and its corner resize grip now accept a finger from a
  larger area than they draw: 40 px down from the top edge instead of the
  24 px bar, and a 32 px corner square instead of a 16 px one. Both were well
  under the 44 pt and 48 dp the platforms ask for, which made a module fiddly
  to move and harder still to resize on a tablet. Nothing on screen changed
  size, and neither did anything for a mouse, a trackpad or a stylus-free
  pointer — the larger targets are admitted to touch and stylus only.
- A tap on a module's resize grip selects the module. It previously did
  nothing: the grip is opaque, so it took the tap from the module underneath
  it and had nothing of its own to do with it.
- A typed address that is not an address now says so, instead of the Connect
  button appearing to do nothing. A mistyped port — `192.168.1.20:70000` — was
  previously read as a host name with a colon in it and dialled, which failed
  several seconds later as a name lookup, and an unbracketed IPv6 literal was
  split at its last colon into a host and a port that could never connect.
- The macOS download is an installer package rather than a disk image, and the
  Windows download is an installer executable rather than an msix. Neither
  original format can install a plug-in: a disk image has no install step at
  all, and an msix's virtualised filesystem cannot write the shared VST3
  directory.
- The Windows installer is not yet signed, so Windows shows "Windows protected
  your PC" and the user clicks More info → Run anyway. The msix it replaces was
  refused outright when unsigned, so this is a state a user can get past rather
  than one they cannot.

### 🐛 Fixed
- **Publishing to a tablet no longer stops following the desk when the window
  is narrowed.** The status bar drops whole items rather than squeezing them,
  and everything that fed the display host ran inside the item it dropped — so
  past that width the socket went on streaming measurements while layout, skin
  and delivery-target changes stopped arriving, and a changed name, port or
  rate was never adopted. Nothing said so, and the tablet looked healthy
  throughout.
- The status bar no longer overflows its own row while publishing at narrow
  window widths. The remote button's label grew from `REMOTE` to `REMOTE · ON`
  when it was switched on — 27 px the width gate below it had never been
  measured against, because the sweep that proves the bar fits never published.
  The switch that replaced it is the same width in both states.
- A warning that no display will find this machine no longer flashes on screen
  for a second every time publishing is switched on. The first announcement of
  a session is often refused before the multicast join settles and succeeds on
  the next one a second later; the notice now waits for the responder's opening
  burst to finish before it says anything, and clears immediately.
- Publishing that could not start — the usual cause is a second copy of Open
  Audio Analyzer already running — now says so on screen. The switch flicked on
  and back off under the pointer with the reason recorded nowhere anybody was
  looking.
- A desktop that cannot announce itself on the network now says so, on the
  Remote row and in the panel behind it, instead of reading *Publishing* while
  no tablet ever lists it. The advertisement had no error reporting at all: its
  bind error, its send error and its socket's error stream were all discarded,
  and the last of those is the one a refused local-network permission arrives
  on. Nothing about the machine looked wrong either, because the permission
  blocks the announcement and not the port — a display given the address by hand
  connected and worked perfectly throughout.
- **macOS users upgrading from 0.5.0 or earlier have to allow local network
  access again.** 0.6.0 changed the bundle identifier from
  `dev.openaudioanalyzer.oaa` to `com.openaudioanalyzer.oaa`, and macOS keys the
  permission to the identifier — so the entry granted to the old application no
  longer applies to this one and tablets stop finding the desk. Allow Open Audio
  Analyzer under System Settings → Privacy & Security → Local Network. Presets,
  skins and paired hosts are unaffected; they are keyed by name, not by
  identifier.
- A panel now moves clear of a tablet's software keyboard. Every panel stayed
  centred on the whole screen while the keyboard covered the bottom third of it,
  so the address field in Show another machine — the last row above the footer —
  was behind the keyboard together with the caret and everything typed into it.
  Panels make room for the keyboard now, and the field being typed into is
  scrolled in front of whoever is typing.
- The DAW's playhead no longer floats loose in the middle of the status bar. Its
  box reserves the width of a timecode, so a host that counts bars and beats
  instead — `1|1.0` — filled a third of it and left the rest as a hole on the
  right, while on the left the sample rate and channel count printed flush
  against the reading at every window between about 1160 px and 1310 px. The
  playhead now sits one gap from the elapsed clock it is read beside, and a
  group's width away from the format readout at every window size.
- A tablet's page tabs now sit beside the name of the machine they belong to.
  The playhead was in front of them, and it reserves room for a timecode, a
  tempo and a time signature whether or not the host at the other end keeps all
  three — so on a host counting bars the tabs stood 88 px clear of the reading
  with nothing between the two, and on one reporting a clock and no tempo 190 px,
  reading as a control floating in the middle of the bar. The tabs come first
  now, and nothing that appears, vanishes or reserves unused room can move them.
- The Linux VST3 now loads on the same distributions as the Linux application.
  It was built against a newer glibc than everything shipped beside it, so on an
  older distribution it was simply absent from the DAW's plug-in browser with
  nothing logged — indistinguishable from having installed it in the wrong
  place. Affects every release that shipped a Linux plug-in.

### 🔥 Removed
- The **Remote** panel, and the *Send these meters* panel behind it. Both ends
  of the link are controls in the status bar now, and what those panels
  configured is in Settings → Publish.
- The macOS `.dmg` and the Windows `.msix`. Their replacements are above, and
  each installs a superset of what the one it replaces did.

### 🚧 Internal
- Turning the remote display off publishes its state before it closes its
  sockets rather than after. Both closes suspend and `dispose` does not wait for
  them, so a service that had been publishing wrote to a disposed
  `ValueNotifier` from inside a microtask — visible only in the console, and
  only ever reached by a service that had actually been switched on.
- A release no longer carries `artifact.tar`, an unlabelled tarball of the
  documentation site that has been attached to every release since 0.3.0. The
  publish step downloads every artefact the run produced, and the Pages action
  gives its payload that fixed name.
- The signing keychain accepts a `.p12` carrying both Developer ID
  certificates, grants `productbuild` and `productsign` use of the key, and
  verifies what it imported against the identities the job asked for instead
  of printing a summary that could not show an installer certificate at all.
- The macOS package turns off bundle relocation. Left on, the Installer asks
  Spotlight where the application already lives and writes the update *there* —
  so a stale copy in `~/Downloads` would receive it while `/Applications` kept
  the old version, and the install would report success.
- The five packaging jobs in `ci.yml` are named for the platform and the
  artefact they produce — `macos-pkg`, `windows-installer`, `linux-tarball`,
  `linux-appimage` and `linux-flatpak` — where a format, a platform and a
  container had been three naming schemes for one family of jobs.
- The plugin and CLI artefacts are named by platform rather than by runner
  image. Three installer jobs download the plugin bundles by name, and the
  name was `oaa-plugin-ubuntu-22.04` — the image is pinned for glibc reasons
  and moving it would have failed those downloads rather than the job that
  moved it.
- `OAA_IOS_TEAM_ID` now reaches the iPad build. The Runner target's Release
  configuration set its own `DEVELOPMENT_TEAM`, which outranks the xcconfig
  `make_ipa.sh` writes, so a profile created under any other team was installed
  and valid and Xcode looked for it under the project's team instead — the
  archive failed and no build could reach TestFlight. `make_ipa.sh` also
  compares the profile's team against the build's before archiving, as its
  fourth pre-build check.
- The test that holds the two ends of the link to different advice no longer
  asserts it on the one path that writes no advice at all. Outside macOS a
  refused multicast send is reported as its errno, by both ends, because the
  errno is the only fact there is — so the assertion passed on the machine it
  was written on and failed the Linux job.

## [0.6.0] — 2026-08-22

### ✨ Added
- macOS releases can be notarised, which is what lets a downloaded plugin or dmg
  be opened with no further steps. A Developer ID signature now also carries the
  hardened runtime and a secure timestamp, both of which Apple requires before it
  will notarise anything and neither of which was being requested.
- Tagging a release now builds the iPadOS display and uploads it to TestFlight,
  so a tablet no longer has to be built from source to be updated. The upload
  runs after the release is published rather than before it, which means a
  TestFlight build always corresponds to a release that exists. The IPA itself
  is deliberately not attached to the release: an App Store build provisions no
  devices, so a downloaded copy could not be installed by anyone.
- The iPadOS build declares that it uses no encryption. Without that declaration
  every TestFlight build waits in "Missing Compliance" until somebody answers
  the export question by hand, which is the one step an automatic upload cannot
  take.

### ⚡ Changed
- The application identifier is now `com.openaudioanalyzer.oaa`, and the
  plugin's is `com.openaudioanalyzer.oaa.plugin`. Both were under `dev.`, which
  reversed a domain nobody held; these reverse `open-audio-analyzer.com`. The
  hyphens do not survive the trip, and cannot: an Android `applicationId` and a
  Kotlin package are Java identifiers and reject `-`, while Apple's
  `CFBundleIdentifier` accepts only letters, digits, `-` and `.` and so rejects
  the `_` that Android would want in its place. Stripping them is the one form
  that is legal on all six platforms. The Linux application id, the AppStream
  and flatpak ids, the msix identity and the hicolor icon filenames all move
  with it.

### 🐛 Fixed
- The macOS plugin bundles are built for Apple silicon **and** Intel, and load on
  macOS 11 and later. Every release up to 0.5.0 shipped a bundle built for
  whichever machine the release ran on — Apple silicon only, and requiring that
  machine's own macOS version or newer — which a DAW reports in exactly the way
  it reports a plugin that was never installed.
- The instructions for a downloaded macOS plugin now describe what macOS 15 and
  later actually do when the quarantine flag is still on it: a modal saying the
  plugin cannot be verified free of malware, or that it will damage your
  computer, **with nothing in System Settings to override it** — the "Open
  Anyway" button there is only offered for a blocked launch, and loading a plugin
  into a DAW is a library load. The fix has not changed and is still
  `xattr -dr com.apple.quarantine`; what was wrong was the description of the
  symptom, which called the failure silent and sent people looking for a
  different problem.
- The README no longer claims the macOS build is distributed "signed with a
  Developer ID and notarised". It has never been either.

### 🚧 Internal
- CI imports a signing certificate before anything signs. `OAA_SIGNING_IDENTITY`
  was being handed to `codesign` on runners whose keychain was empty, and
  `OAA_NOTARY_PROFILE` named a credential that only exists on a developer's own
  machine, so neither secret could have worked on a runner — and neither failed a
  job, because they had never been set and the scripts took their no-credential
  branches instead.
- `packaging/ios/make_ipa.sh` and `packaging/ios/testflight.sh`, and the `ipa`
  and `testflight` jobs in `ci.yml`. Manual signing is injected through
  `ios/Flutter/Release.xcconfig` so the Xcode project stays on automatic signing
  for local development; the script reads the signing authority back off the
  archive, because `flutter build ipa` exits 0 on an export that silently fell
  back to automatic signing.

## [0.5.0] — 2026-08-22

### ✨ Added
- Double-clicking the status bar on macOS zooms the window again, as
  double-clicking a title bar does everywhere else on the Mac — the status bar
  is this window's title bar, and it had answered nothing since 0.3.0. It obeys
  the system's "double-click a window's title bar to" setting, so a Mac set to
  minimise minimises and one set to do nothing does nothing, and it waits the
  double-click interval that Mac was configured with. No control in the row
  answers any later for it: what Flutter recognises there is still a single
  click, and the pair is counted in the runner.

### ⚡ Changed
- The iOS and Android home screen label is `OAA`, the wordmark the status bar
  already draws. It was `Open Audio Analyzer`, which no tablet ever actually
  showed: iOS fits an icon label to the width of one icon by tightening the
  tracking before it truncates, and tracking is spent on the spaces between
  words first — a 19-character name arrived on the home screen as
  `OpenAudioAnal…`, run together and cut short anyway. Apple's guidance is
  twelve characters. The product's name is unchanged everywhere it fits: the
  macOS, Windows and Linux applications, both permission prompts, and every
  configuration directory — nothing a tablet has saved moves.

### 🐛 Fixed
- The canvas no longer gets slower the longer a spectrogram is on screen. The
  spectrogram redrew its whole history as run-length marks on every published
  frame, and its cost was budgeted against smooth columns — real material
  jitters a brightness step between most adjacent rows, so a large display was
  re-recording and re-rasterising 150,000–230,000 marks about 47 times a
  second, a cost that ramped for the half-minute the history took to fill after
  a mount and then stayed. Every meter repaints from the same clock, so it
  dragged the whole canvas — most visibly the analyser — and the remote display
  paid the same price on weaker hardware, more of it at the 60 fps link rate.
  The history is now kept as pixels and drawn as one image, a quarter of a
  millisecond per published frame whatever the signal does; the numbers are in
  `tool/bench_spectrogram.dart`.
- On a remote display, the tab control now sits beside the name of the machine
  being watched instead of stranded in the middle of the link bar. The bar kept
  room for the host's playhead whether or not the host had one, so on every host
  with no DAW behind it — a desktop metering a device or a file, which is most
  of them — 248 px of nothing stood between the name and the tabs. The slot
  appears with the playhead and does not move again while the link lasts, so a
  reading that goes stale does not shift the tabs out from under your finger.

### 🚧 Internal
- `tool/bench_spectrogram.dart` is formatted the way the test job's
  `dart format --set-exit-if-changed` step demands. It was not, so that job
  failed on every push after the benchmark landed while the analyzer, the
  suites and the benchmark itself all stayed green. That step is now listed
  with the other gates in `README.md` and `CLAUDE.md`, which is why it was
  never run by hand.

## [0.4.1] — 2026-08-22

### 🐛 Fixed
- The macOS plugin bundles now carry a valid code signature. All three — the
  VST3, the Audio Unit and the Standalone — shipped with an invalid one in every
  release up to 0.4.0: the VST3's resource seal was computed before JUCE wrote
  `moduleinfo.json` into the bundle, and the other two were never bundle-signed
  at all. On Apple Silicon that is enough for a DAW to leave the plugin out of
  its browser without logging anything, and for `auval` to refuse the Audio
  Unit. Each bundle is now signed after everything that writes into it and
  verified on the spot, so the build fails rather than producing a bundle it
  cannot verify. `auval -v aufx OaaM OaaA` passes. **If the plugin never
  appeared in your DAW, this is why** — and on macOS also strip
  `com.apple.quarantine` from a copy you downloaded, which no build can do for
  you.

### ✨ Added
- The documentation site's [Install](https://jonasgrunau.github.io/open_audio_analyzer/install.html)
  page now has an **In a DAW** section: which folder the VST3 and the Audio Unit
  have to be copied into on each platform, the `xattr` line that a downloaded
  copy needs on macOS, and the Ableton Live preference that has to be on before
  Live looks in the folder at all. The page had linked to that section since the
  site was first published, and the section did not exist.

### 🚧 Internal
- `OAA_CODESIGN_IDENTITY` signs the macOS plugin bundles with a Developer ID
  instead of ad-hoc. Releases stay ad-hoc.
- Signing runs from a target that depends on the format target rather than from
  `POST_BUILD`, which is not last: a `MACOSX_PACKAGE_LOCATION` resource is
  copied by a sibling rule that make may run after the link, and on a
  from-scratch build it does. Only visible with the bundle deleted first.

## [0.4.0] — 2026-08-21

### ✨ Added
- An Android tablet now finds hosts on the network by itself, like every other
  platform. It held a multicast socket that never received an answer, because
  Android's Wi-Fi driver discards multicast for an app that is not holding a
  `WifiManager.MulticastLock` — silently, with the search still saying it was
  looking. The lock is held while a search is running and given back when it
  stops, so it costs nothing once a display is attached.
- An Android tablet now remembers its layout, its skin and the host it was last
  attached to. Nothing in an Android process names a directory it may write to,
  so the configuration directory is asked for over a platform channel and lives
  in the app's own `files` directory; every launch before this one started from
  the defaults.
- Metering your Mac's own output no longer needs a loopback driver. On macOS
  14.2 and later, **System Output** is the first entry in the source menu, named
  after the output device it is metering. It is a Core Audio process tap, so
  there is nothing to install, nothing to reroute and no password prompt — the
  audio still reaches your speakers while it is being measured. macOS may ask
  for permission to record system audio the first time. Below 14.2 the entry is
  absent and BlackHole or Loopback is still the answer; Windows and Linux are
  unaffected, since WASAPI loopback and a PipeWire monitor source already appear
  in the list.

### ⚡ Changed
- The wire protocol is at version 3, and a receiver now accepts any version it
  knows rather than only its own. A plugin built against 0.3.0 keeps working
  with a newer app, which under the old equality check it would not have: a
  plugin lives in the DAW's plugin folder and stays there across app upgrades,
  so the mismatch was the ordinary case, and what it looked like from the plugin
  was a port that accepts and hangs up forever — indistinguishable from the
  defect where the port was never bound at all. The rule is one-way on purpose:
  a peer *newer* than this build is still refused, because a later version may
  have moved a table and misreading a measurement table is how a meter draws a
  confident wrong number. **A tablet still running 0.3.0 or earlier will refuse
  a newer desktop** and say so, rather than drawing anything; update both ends.
  Version 3 adds a frame type and moves no byte of any existing table — held by
  a test that decodes the frozen version-2 golden and diffs it against the
  version-3 one, where exactly four bytes differ and all four are version
  fields.
- A host search that is running but cannot receive says so instead of
  "Looking for hosts on this network…", which is the face a search that is about
  to succeed wears.

### 🐛 Fixed
- The plugin's status panel no longer claims a playhead from a host that is not
  giving one. The line was drawn from whether a transport had ever been
  published, and the plugin publishes one for every audio block — the empty one
  that means "this host said nothing" included — so it read as a playhead the
  moment audio started flowing, on precisely the host it exists to warn about.
  It now follows what the host is reporting now, and says "no playhead from
  host" again if a host stops.

### 🚧 Internal
- Groundwork for the Elapsed and Timecode LUFS modes, which are **not yet
  offered by any module** — this is the protocol and the engine underneath them,
  and the modules and their menu are the change after this one. `docs/WIRE.md`
  gains `0x0020 SET_LUFS_MODE`, the first frame that travels from consumer to
  producer, permitted on the ingest port only because that one binds loopback
  where whatever connects is already running as this user; the display port
  binds every interface and stays read-only until somebody designs
  authentication for it. Three implementations moved together, as that file
  requires.
- The engine can reset itself when the signal returns after a silence
  (`oaa_engine_set_silence_reset`, ABI 5), which is what the System mode is made
  of. It lives in `engine/` rather than above it because silence is a property
  of audio and not of a host — one implementation serves a plugin and a sound
  card, where two would eventually disagree about when a track began. The gate
  runs *before* the block it judges, so a track whose loudest sample is in its
  first block keeps that peak rather than having it cleared by its own reset.
  Off by default, and off for file analysis, which must measure a file whole.
  The two transport-driven modes need no engine API at all: they are the
  producer declining to push, so `engine/` still does not learn what a DAW is.
- The plugin's answer to a host that supplies no transport is now held by a
  test. `plugin/test/transport_capture_test.cpp` hosts the `AudioProcessor`
  directly, which is the only way to reach either of the two branches behind it:
  no VST3 or Audio Unit host can express "no playhead" or "no position", so
  neither a DAW nor the fake DAW can ask for them. It runs in the gated plugin
  job's `ctest`, and both it and the transport box's own test were verified by
  breaking the code under them and watching them fail.
- Five documents caught up with protocol version 3's two goldens. `docs/WIRE.md`
  still gave the SNAPSHOT payload size "at protocol version 2" in the one
  document whose header declares version 3; `packages/oaa_wire/AGENTS.md` named
  `wire_v2.bin` as the golden its codec test decodes, when the test reads both
  and `wire_v3.bin` is the one tracking the current serialiser; and two comments
  in `ci.yml` credited the C++ producing side with writing `wire_v2.bin`, which
  it no longer does. The one that could have cost something: the regeneration
  command in `plugin/test/wire_fixture.cpp` still wrote to `wire_v2.bin` — the
  frozen file whose whole purpose is to hold bytes produced before version 3
  promised to move no table. Following it would have destroyed the evidence and
  left every test green.
- Two claims about that branch are corrected here rather than in the 0.3.0
  notes, which are released. It is **not** reached by the Standalone build —
  JUCE 8's `AudioProcessorPlayer` installs a counting playhead whenever the
  processor it is given has none — and it is unreachable through an Audio Unit
  as well, not only through VST3. The plugin's own handling was correct
  throughout; only the note about what exercised it was wrong. `README.md` no
  longer lists it under Known gaps, because it now has a test instead of a
  paragraph.

## [0.3.0] — 2026-08-21

### 📐 Measurement
- The clip indicator now catches clipping. `clip` is the longest run of
  consecutive full-scale samples since the last reset, latched until Reset; it
  was the run still in progress at the block boundary, which is zero for every
  clip that ended inside the block — almost all of them. A run of 40 full-scale
  samples in the middle of a 1024-frame block published 0. The Digital Meter's
  clip lamp is drawn from this, so it was dark for real clipping, which reads as
  proof that nothing clipped. No other reading changes; nothing that was
  reported as clipped is now reported as clean.
- Crest is now taken over the block being measured rather than from the values
  the meters draw. Both operands were the displayed peak and RMS, which carry a
  1.5 s hold and a 300 ms averager, so the figure described the ballistics: a
  single block of DC at 0.9 read 11.6 dB where the answer is 0, and 0.43 s after
  a transient it read 17.8 dB and was still climbing. A steady sine reads
  3.0103 dB either way, which is why the test suite never caught it.
  **Re-measure anything whose crest you recorded from a moving signal** —
  readings on transient material fall, typically by several dB, and were
  previously too high. Multichannel now reports the peakiest channel rather than
  the loudest peak minus the loudest RMS, which could describe no channel at
  all.

### ✨ Added
- A DAW's playhead now reaches a tablet. The desktop decoded the plugin's
  transport frame and kept it: bars, beats, tempo, time signature and timecode
  stopped at the desktop, so a remote display showed a plugin's meters beside no
  position at all. It is relayed to every attached display now — on change
  rather than with every measurement, so a parked session costs nothing, and
  replayed when a display attaches so that one joining a parked session is not
  left blank until somebody presses play. A jump in the playhead survives the
  hop: the flag is an edge delivered once, and a relay publishing thirty times a
  second against a DAW's ninety-odd blocks accumulates it rather than sampling
  it.
- The status bar and a tablet's link bar both show the host's transport: the
  position in the most precise unit the host gave — timecode, else bar and beat,
  else its own clock — with the tempo and time signature where there is room for
  them, and brighter while the transport is rolling than while it is parked. The
  app had been decoding all of it and showing none of it. A value the host did
  not supply is not drawn at all, rather than printed as a plausible zero.
- The app accepts plugin connections. `PluginLink` was written, tested and never
  constructed, so port 47822 was never bound: a VST3 or AU inserted in a DAW
  retried against nothing forever while the README said the desktop app meters
  what the DAW is playing. Inserting a plugin now puts it on the canvas — the
  act of inserting it is the act of choosing it — and removing it hands the
  canvas back to the local source. A port that cannot be bound is reported in
  the window rather than being silent, because the usual cause is a second copy
  of Open Audio Analyzer already running.
- `oaa --target` reads your own delivery targets, not only the six built-in
  ones. The app has always merged `calibrations/*.json` over the built-ins by
  id; the CLI knew nothing about them, so a corrected `atsc-a85.json` changed
  the verdict in the window and left the exit code — the one a release pipeline
  believes — judging against ours. `oaa --list-targets` shows them, and
  `--config-dir` points at a directory other than the default.
- The VST3 and the Audio Unit are published with each release, as one archive
  per platform holding the plugin bundles. They are not bundled inside the
  desktop installers yet.
- The plugin is compiled on Linux, macOS and Windows as part of a release, and
  on demand. Nothing built it before: the only plugin check in CI compared two
  text files and never invoked CMake, so a JUCE dependency fetched by tag, a C++
  wire producer that has to agree with the Dart one byte for byte, and a version
  that moves every release were all held together by whoever last built it by
  hand. It is not built on every push, because three parallel JUCE builds cost
  more than a push asks for.

### ⚡ Changed
- The application is called Open Audio Analyzer everywhere it names itself. The
  window title, the macOS menu bar, the Windows version resource and the Android
  launcher label all said `oaa`, which is the repository's short name and not the
  product's. The executable moves with them: `Open Audio Analyzer.app` on macOS,
  `OpenAudioAnalyzer.exe` on Windows and `open-audio-analyzer` on Linux, where a
  space is not available — the Flutter-generated CMake makes the executable name
  a CMake target name, and CMake rejects one containing a space. The `oaa` CLI
  keeps its name; it is a command, and a command with spaces in it is not one.
  Bundle identifiers are unchanged, so no configuration moves and no host loses
  track of the plugin.
- The plugin's bundle identifier is `dev.openaudioanalyzer.oaa.plugin`. It was
  `io.github.jonasgrunau.bel`: the rename to Open Audio Analyzer moved every
  other identifier and missed this one, because nothing built the plugin to
  notice. A host caches a plugin by that string, so it moves before the first
  published build rather than after.

### 🐛 Fixed
- A relocate is reported once rather than twice. The plugin marks the single
  audio block on which the playhead jumps, and that flag was carried both in the
  accumulator that exists to deliver it exactly once *and* in the transport
  payload, which is sampled — so a machine loaded enough for two frames to leave
  inside one audio block delivered one relocate as two, and a three-lap loop
  reported four. `docs/WIRE.md` lets a consumer count relocations by counting
  flagged frames, so the count was wrong; no reading changes, because nothing
  yet acts on the flag. Held by a new deterministic test rather than by a loaded
  machine.
- The "audio was lost" notice counts the frames the *metered* source discarded.
  It read the local engine's counter while the flag that raises it comes from
  whatever is on the canvas, so a plugin that overran produced "Audio was lost —
  0 frames were discarded": a warning that contradicts itself, about a real loss
  of audio, carrying the number somebody would put in a bug report.
- The remote display no longer reads a destroyed engine. Changing the audio
  source or device while publishing to a tablet left the publish timer holding
  the engine it was built with, acquiring through a freed handle thirty times a
  second and sending 15 kB of returned heap to the tablet as a measurement. The
  service now follows the engine, and lives beside it rather than inside the
  status-bar button — which the status bar drops below 620 px of window width,
  so narrowing the window silently tore down an active session.
- A disposed engine reports itself unavailable instead of reading freed memory.
  Every scalar reading returns NaN, false or zero and `refresh` returns false, so
  a holder that keeps one a frame too long draws em dashes rather than plausible
  numbers. The array views cannot be guarded and are documented as invalid the
  moment `dispose` returns.
- Cancelling a file analysis no longer leaves the previous one running. The
  native cancel flag was freed while the worker isolate was still reading it, so
  the next analysis reallocated those four bytes as zero and the old worker read
  "not cancelled" and went on decoding its whole file — competing for the frame
  budget the isolate exists to protect. The flag is released once the isolate has
  actually exited.
- Resizing a module that a stored layout had left smaller than its own minimum,
  against the right or bottom edge, no longer throws. Rects are now pinned to
  the canvas and to the module's minimum as they are read, whatever wrote them.
- The remote display's advertised name can be cleared, not only replaced.
  Emptying the field restored the previous name, so "use this machine's name"
  was unreachable once a name had been set.
- A file analysis that cannot start no longer leaks its open decoder.
- A preset named `CON`, `AUX`, `NUL`, `PRN`, `COM1`–`COM9` or `LPT1`–`LPT9` can
  be saved on Windows, where those are reserved with any extension.
- Stopping a pushed engine clears its running flag. It never started a thread,
  so `oaa_engine_stop` returned early and the snapshot reported a stopped engine
  as running for the rest of its life.
- A capture device's id is no longer truncated to an odd number of hex digits
  with its terminator landing by luck. Trailing zero bytes are dropped before
  encoding, which keeps every id a real backend produces well inside the field.
- The plugin drops a wrong-length frame rather than sending it. The check was an
  `assert`, and the plugin is built `Release` everywhere including CI, so
  `NDEBUG` removed it from the only build that exercises the C++ producer.
- The plugin no longer tells the app the playhead relocated while the transport
  is parked. A stopped DAW still runs its graph and reports the position it sits
  at, unchanged, every block; the plugin compared that against "one block
  further on" and raised its discontinuity flag on every published frame for as
  long as the transport was stopped — measured at 140 frames out of 140. It is
  now only evaluated while the transport is rolling. Nothing in the application
  consumes the flag yet, so no reading changes today; the Elapsed and Timecode
  LUFS modes are what would have been affected.
- The plugin's name arrives at the app as text rather than as mojibake. The
  HELLO frame's producer name was built with `juce::String`'s `const char*`
  constructor, which reads its argument one byte to one codepoint, so the em
  dash in "Open Audio Analyzer plugin — " was mangled on the way in and
  re-encoded on the way out: the app's title bar read
  `Open Audio Analyzer plugin â<80><94>`. `docs/WIRE.md` specifies that field as
  UTF-8, which makes it a protocol defect rather than a typographical one. JUCE
  asserts on this and the assert is compiled out of the Release build, which is
  why nothing caught it.
- A relocate now reaches the app instead of usually being missed. The flag marks
  the single audio block on which the playhead jumped, and the streaming thread
  samples the transport once per published frame — every second block at a
  512-frame buffer, one in sixteen at 64 — so it was set on one publish and read
  from another: three loop laps in a row delivered it zero times out of 186
  frames. Edge flags now accumulate outside the seqlock and are delivered once
  each, which makes the count independent of buffer size. Verified at 64, 128
  and 512 frames.

### 🚧 Internal
- The plugin's framework-free C++ tests run on every push. `plugin/`'s JUCE fetch
  is conditional now, so `-DOAA_BUILD_PLUGIN=OFF` configures the directory in
  under a second and builds liboaa, the wire fixture and the transport box test
  in three — where the full job takes about ten minutes and, being gated to
  releases and manual runs, had been the only place any of it ran. It closes a
  real hole as well as a slow one: the wire golden is only worth having from both
  ends, and only the decoding half had been checked between releases.
- The fake DAW no longer invents relocates on a slow machine. An offline run
  handed the transport a read-ahead thread, and when that thread falls behind,
  JUCE's buffering source returns silence while the reported playhead stops
  advancing — a host claiming to play with a position that sits still, which is
  a discontinuity by any definition, and the plugin flagged it. The plugin was
  right; the instrument was wrong. Offline runs read the file synchronously now,
  which is what makes their timeline independent of the scheduler; the device
  path keeps its buffer, where a stall is a click rather than a wrong number.
- `resolveConfigRoot`, `ConfigDir`, `ConfigFile` and `slugify` moved from the app
  into `oaa_core`, which is what lets the CLI read the same delivery targets the
  app writes. They are pure functions, so the package keeps its "no I/O" rule.
- A fake DAW, in `plugin/host/`. It plays an audio file through the VST3 or the
  Audio Unit and hands it a transport — tempo, time signature, timecode frame
  rate, loop points, the record flag, and the playhead itself, which can be
  switched off. None of the plugin's playhead handling had ever been run before:
  the only host that could reach it was a real DAW driven by a person. It is
  built by the same CMake run as the plugin and shipped nowhere.
- The plugin is driven end to end by a test. `plugin/host/` also runs headless —
  no window, no sound card — and
  `packages/oaa_wire/test/plugin_e2e_test.dart` spawns it, listens on the port
  the app listens on, and decodes what arrives. It is the only coverage of
  `prepareToPlay`, the FIFO, the playhead, the engine, the streaming thread and
  the socket at once; the byte-for-byte golden beside it is produced by a
  fixture that links no JUCE. It generates its own audio, so nothing in CI
  downloads anything, and it skips rather than fails without a built plugin.
- A DAW's meters are held against what a tablet shows, in one test.
  `test/plugin_to_display_e2e_test.dart` runs the same fake DAW through the
  application's own plugin ingest and display host, attaches a display client —
  which is what a tablet runs — and compares twenty-nine readings field by
  field, plus the playhead: the tempo, the meter, the timecode and the bar the
  host was told to be at. What a display receives is a re-encode of a snapshot
  the app decoded off the plugin's socket, so a field dropped in the middle left
  both halves' suites green and the tablet showing a dash. It skips without a
  built plugin, and CI runs it on the Linux leg of the plugin job.
- One thing the fake DAW found is written down rather than patched, under Known
  gaps in `README.md`: the plugin's "host supplies no transport" branch cannot be
  reached through VST3 at all, because the format has no way to say it. That is a
  property of VST3 rather than a defect, and the branch is reached by the
  Standalone build. The other finding recorded that way on the first run — that
  the discontinuity flag usually did not survive the trip to the app — was
  fixed inside this release instead, and is under Fixed above; it moved a value
  `docs/WIRE.md` describes, which is why it was a decision before it was a fix.
- `tool/fetch_test_audio.dart` downloads the Creative Commons music the
  application is looked at with — a tone produces a spectrogram that is one
  bright line and a stereo cloud that is a dot, both correct and neither
  informative. Two CC BY 3.0 post-rock tracks from Wikimedia Commons, chosen by
  measuring four candidates with `oaa` rather than by reading titles: the
  default is a loud master with a real 10.3 LU range, a true peak above its
  sample peak, and a stereo field that moves. It resumes a partial download,
  verifies the length and signature, writes the attribution the licence asks for
  beside the audio, and is run by hand. No test depends on it.
- One workflow instead of three. `ci.yml` runs the tests, the documentation
  site, the installers and the release as jobs gated by event, so a push
  produces one run rather than two and a tag no longer produces a third that
  names neither. The reason it was split — that packaging must not slow the
  signal everybody waits on — is kept by not running those jobs on a push,
  which is a condition rather than a file. Two things the split had made
  impossible: a release can now depend on the test jobs, so a tag cannot
  publish from a red commit, and `workflow_dispatch` builds every installer
  without publishing anything.

## [0.2.0] — 2026-08-19

### 📐 Measurement

- **The VU meter reads differently, and lower on most material.** It was a
  one-pole smoother over mean square — an RMS meter with a 300 ms time constant.
  It is now what a VU movement actually is: **average-responding and
  RMS-calibrated**, through a second-order mechanism. A steady sine still reads
  its own RMS exactly, so a calibration tone is unchanged; anything peakier now
  reads **lower**, by 9 dB on a signal with a 10% duty cycle and typically 1 to
  4 dB on dense modern masters. If you have been matching levels by VU against
  Open Audio Analyzer's previous readings, re-check them. The needle also
  overshoots by about 1.2% on a transient, which is inside the tolerance the
  standard allows and is most of why a VU feels like a VU.
- **The spectrum is now measured.** 512 log-spaced bands from 20 Hz to 20 kHz,
  from a 4096-point Hann window per channel at a 1024-sample hop, zero-padded
  to a 16384-point transform. A band wide enough to contain bins takes the
  loudest of them rather than their average, so that a narrow resonance
  survives the mapping; a band too narrow to contain one — everything below
  about 216 Hz at 48 kHz — reads the transform between its two nearest bins.
  Levels are window-compensated: a full-scale sine on a bin centre reads
  0.0 dBFS, verified on every push, and one falling between two bin centres
  reads within 0.3 dB of its own level rather than up to 1.4 dB low. Frequency
  resolution is that of the 4096-point window and the padding does not change
  it: two tones closer than 11.7 Hz still merge. What changes is that the
  bottom three octaves are drawn as the curve the transform measured instead
  of as a staircase of up to twenty-five identical bands.
- **Per-band stereo position** and the **raw stereo sample stream** are now
  published, which is what the stereo cloud and the phase scope draw.
- **The short-term loudness distribution is now published**, together with the
  10th and 95th percentiles LRA is the difference of and the relative gate they
  were taken above — the same population the LRA number is computed from, so a
  distribution drawn from it cannot disagree with the number beside it.
- LRA itself is unchanged. It is now computed *through* the published
  percentiles rather than beside them, which is a refactor, not a new number.

- **Loudness is now measured.** LUFS-M, LUFS-S, LUFS-I and LRA previously read
  as a dash and now report real values, verified against the EBU Tech 3341
  cases within the standard's ±0.1 LU on every push, on all three desktop
  platforms. K-weighting follows ITU-R BS.1770-4 with coefficients designed at
  the stream's own sample rate, so 44.1, 88.2, 96 and 192 kHz are correct rather
  than approximately correct.
- **True peak is now measured**, with the 4× polyphase oversampler from
  BS.1770-4 Annex 2. It reads **higher than sample peak** — by up to about
  3 dB on dense, limited material — because that is what the signal actually
  reaches between samples. **A master that previously passed a −1 dBTP ceiling
  on sample peak alone may now fail it. Re-measure before delivery.**
- DR-S, DR-I, PLR and PSR are now defined, being differences of the above. See
  [docs/METRICS.md](docs/METRICS.md) for the formulas; none of them is
  Decibel's proprietary TrueDyn and none pretends to be.
- LFE is excluded from loudness and surround channels are weighted +1.5 dB, per
  BS.1770-4. Channel layout is inferred from the channel count, and the
  four-channel case is read as quad (L R Ls Rs) rather than L R C LFE — see
  METRICS.md, and expect this to be replaced by real layout metadata when a
  device or file source can supply it.

- **A device's own sample rate and channel count are adopted, not converted
  to.** Open Audio Analyzer measures the stream the hardware produced;
  resampling in front of the measurement would move inter-sample peaks and shift
  the K-weighted energy, and the resulting numbers would still look plausible.
- An interface wider than 7.1 is **refused** rather than measured eight
  channels at a time and reported as programme loudness.
- An unknown device id **fails** instead of falling back to the default. A
  preset naming an interface that is not plugged in would otherwise silently
  meter the laptop microphone.

- **Files can now be measured, and they read exactly as the live meters do.**
  Analysing a file decodes it and pushes the blocks through the same
  `oaa_analyse` a capture device drives — there is no second DSP path — so the
  numbers are identical rather than merely close. A test asserts that equality
  on the same samples analysed both ways, to the bit. A file is measured at its
  own sample rate and channel count; nothing resamples or remixes, because a
  converter in front of a measurement changes the measurement.
- **A file report states maxima, not final values.** Momentary and short-term
  loudness, correlation and per-channel peak describe an instant, so reading
  them once at the end would report the fade-out and call it the programme.
  They are watched across the whole file instead. Integrated loudness, LRA and
  the "max since reset" peaks are integrating quantities and are read at the
  end, which is correct for them.
- Sample values are **not clamped** on the way out of the decoder. A float WAV
  may legitimately hold values beyond ±1.0, and those are precisely the
  overshoots true-peak metering exists to find.
- **The Spectrum Analyzer draws an average of the bands rather than the last
  transform, and it now says which.** The engine publishes about 47 transforms a
  second and the module drew every one untouched, which flickers hard enough
  that the shape of a balance is difficult to read. A new `Response` setting in
  the module's menu chooses Fast — no averaging, exactly what it did before —
  Normal at 120 ms, or Slow at 500 ms; **Normal is the default**, so an existing
  analyser reads calmer than it did and a band's drawn level now lags a change
  by about that much. A short peak reads lower on Normal than it did on the
  frame it happened, by as much as the difference between the peak and what
  surrounds it. Nothing measured changed: the peak-hold line above the curve is
  never averaged at any setting, reports and the wire protocol carry the bands
  as measured, and the spectrogram and stereo cloud draw them as published.

### ✨ Added

- **A remote display.** Turn on publishing in the desktop's status bar and a
  tablet on the same network shows the same meters — the same modules, the same
  layout, the same skin and the same delivery target, rendered by the same
  painters from measurements sent over the network rather than reimplemented.
  Hosts are found by name over mDNS (`_oaa._tcp`), and an address can always be
  typed instead, because multicast is the first thing a guest network blocks.
- **A remote display says when it has stopped being current.** Two seconds
  without a measurement and every reading becomes a dash and the link is marked
  stale, rather than leaving the last picture on screen. A frozen meter is
  indistinguishable from a quiet passage, so a display left running after its
  host slept would otherwise show a confident, detailed reading of a signal that
  had stopped existing.
- **The display is watch-only, and off until switched on.** It cannot reset,
  retarget or reconfigure the machine it is watching, and the port is closed
  until a human opens it. There is no password on the connection; anyone who can
  reach the port can read the measurements and the layout, which is why it is
  offered rather than assumed.
- **A headless VST3 and Audio Unit plugin.** Insert Open Audio Analyzer on any
  track, bus or master and the desktop app meters what the DAW is playing,
  through the same engine and the same painters as a live input — so a plugin
  reading and a device reading of the same audio cannot disagree. The plugin
  draws no meters itself; it measures and streams, and a small status panel says
  whether it is connected. Built for macOS, Windows and Linux, plus a standalone
  target for testing the link without opening a host.
- **The DAW's transport reaches the app**: play and record state, playhead in
  seconds, samples and quarter-notes, tempo, time signature, loop points and
  SMPTE timecode with its frame rate. Every field carries a "the host supplied
  this" flag, because hosts differ enormously in what they report and a missing
  tempo arriving as zero is indistinguishable from a real one — an absent value
  renders as an em dash rather than a plausible number. **The Elapsed and
  Timecode LUFS modes are not built yet**; this is the measurement they will be
  counted from, and no module offers them today.
- The plugin reports when the playhead **jumps** — a relocate, a loop, a scrub.
  Anything integrating across that boundary is averaging two passes of the same
  music into one number and nothing about the result looks wrong, so it is
  stated rather than inferred. Acting on it — restarting an integration when the
  transport moves — needs an app-to-plugin control frame, and so wire protocol 2.
- The app listens for plugins on port 47822, loopback only. Several inserts may
  be connected at once; the most recently connected is the one shown, on the
  grounds that inserting a plugin *is* the act of selecting it.
- **All twelve modules.** The eleven that said `NOT BUILT YET` now measure
  something: a **LUFS Meter** (momentary and short-term as bars, integrated as a
  rule they pass through, the target as a band); a **Digital Meter** (per
  channel to 7.1, RMS as the column and peak as a floating tick, so the gap
  between them is the crest factor); a **Super Meter** (the three integrations
  on concentric arcs); a **VU Meter** (0 VU at the calibration's reference
  level, not at digital full scale); an **Alert Meter** (one metric with its
  worst reading latched until reset); a **Validator** (three delivery checks and
  a verdict); a **Histogram** (short-term loudness over time, with the momentary
  window banded above it and everything past the delivery target in the over
  colour); a **Loudness Distribution** (how often the programme sat at each
  loudness, with the two percentiles LRA is the distance between, drawn from the
  same blocks the number is computed from); a **Spectrum Analyzer**; a
  **Spectrogram**; a
  **Phase Scope**; and a **Stereo Cloud** (per-band stereo position, which
  answers *which part* of a mix folds badly rather than only that it does).
- **Open Audio Analyzer opens on a working meter bridge**, with the frequency
  displays on a second tab, instead of six readings on an empty grid.

- **The canvas is arrangeable.** A 24-column by 16-row grid: drag a module by
  its title bar to move it, drag the corner grip to resize, alt-drag to
  duplicate, right-click or double-click empty space to add one, right-click a
  module for its options. Modules may not overlap and an illegal drop is
  refused rather than nudged elsewhere, with the target cells shown live while
  the pointer is down.
- **Tabs**, with rename, duplicate and delete, switchable with the number keys.
- **Undo and redo**, over every layout edit, from the keyboard or the tab strip.
- **A Number Box shows any of the sixteen measurements**, chosen per module
  from its menu.
- Inter and JetBrains Mono are **bundled** instead of requested from the system,
  so digit width and tracking are identical on macOS, Windows and Linux. Both
  are SIL OFL 1.1 and their licences ship alongside them.
- **Capture from real audio devices.** Inputs are enumerated and selectable
  from the source menu in the status bar. On Windows, WASAPI loopback meters
  system output with no setup; on macOS and Linux a virtual loopback device
  (BlackHole, a PipeWire monitor) appears in the same list — see the README.
- `OaaSource.push` and `oaa_engine_push()`: audio supplied synchronously by the
  caller, with no thread and no clock. It makes the engine a pure function of
  the samples it was given, which is what the conformance suite needs and what
  file analysis will be built on.
- **Lost audio is reported rather than hidden.** If analysis falls behind, the
  capture callback drops frames and the count is published; the app shows a
  warning saying the integrated reading can no longer be trusted. Integrated
  loudness averages every block since the reset, so dropped audio does not make
  it stale — it makes it an average of a different programme than the one that
  played.
- **Offline file analysis.** Drop a file on the analysis panel, or pick one, and
  it is measured end to end: WAV, AIFF, RF64, Wave64, FLAC and MP3. The run
  happens on a worker isolate so the live meters keep their frame budget, it
  reports progress, and it can be cancelled — cleanly, releasing the engine and
  the open file rather than leaking them.
- **A report panel**, showing the source, every programme-wide measurement, a
  short-term loudness graph with the integrated level marked, and the delivery
  verdict against the selected target.
- **Reports export as text, JSON and CSV.** Text is the human summary; JSON
  carries every measurement, the target and the verdict under stable field
  names; CSV is the loudness timeline, one row per point, for a spreadsheet or
  a plot. An unmeasured value is an em dash, a `null` and an empty cell
  respectively — never a zero, which is a legitimate reading for correlation
  and several dB quantities and so cannot double as "no data".
- **A `oaa` command-line analyser**, so a loudness check can be a step in a
  release pipeline instead of something somebody remembers to do. It runs the
  same engine and the same decoder as the app. `oaa --target streaming-14
  master.wav` **exits 2** when the file misses its delivery spec, 1 on a file it
  cannot read and 0 when all is well, which is what lets a build fail on a
  master that is 2 LU too loud.

- **Open Audio Analyzer remembers what you set up.** The frame rate, the
  delivery target, the skin, the signal source and the arrangement on the canvas
  all survive quitting. The window reopens on the layout it was closed on,
  listening to the device it was listening to.
- **Presets.** Save the arrangement under a name, open it again later, delete
  it. One JSON file per preset in a documented directory, so a preset can be
  sent to somebody, dropped in from a forum post or kept in version control —
  and one corrupt file costs one preset rather than the library. A preset
  optionally carries the delivery target and skin it was saved with; leaving
  either out means "follow whatever is selected", which is what makes a layout
  reusable across jobs.
- **A delivery-target editor.** Any spec Open Audio Analyzer does not ship — a
  label's house standard, a game platform's submission requirement — is now
  twenty seconds of typing rather than a feature request. User targets appear
  beside the built-ins everywhere, and a user file carrying a built-in's id
  replaces that built-in, including in presets that already name it. Deleting
  the file brings the original back.
- **Skins.** The palette is thirteen named roles in a JSON file. A skin may set
  as few as one of them and inherit the rest, so changing the accent colour is a
  three-line file. Ships with Precision Instrument and **Daylight**, a light
  palette for a room with a window in it. "Duplicate for editing" writes the
  active palette out in full as a starting point, and "Reload from disk" picks
  up an edit without a restart.
- **A settings panel**, reachable from the status bar: signal and capture
  device, refresh rate and delivery target, skins, and whether the last layout
  is restored at launch. It also names the directory everything is kept in.
- The remote display's name, port and frame rate are remembered. **Whether it
  is publishing is not**, deliberately: configuration is worth remembering, and
  the decision to open a port with no password on it is worth asking for every
  session — a laptop carried somewhere else must not start advertising itself
  because somebody enabled it once at home.
- **The macOS build is no longer sandboxed.** It was, which put your settings,
  presets, skins and delivery targets inside
  `~/Library/Containers/dev.openaudioanalyzer.oaa/Data/…` instead of
  `~/Library/Application Support/Open Audio Analyzer`, and stopped
  `OAA_CONFIG_DIR` from pointing anywhere outside that container. Configuration
  you cannot find is configuration you cannot edit, mail to somebody or keep in
  version control, which is most of the point of it being files. Open Audio
  Analyzer gives up Mac App Store eligibility, which was never planned;
  notarising the dmg does not need the sandbox. **If you ran an earlier build,
  your existing configuration is in the container path above — move it across,
  or it will look as though Open Audio Analyzer forgot everything.**
- The settings panel prints the configuration directory as selectable text
  rather than a path you would have to retype.
- The capture device is reopened **by name when its id no longer matches**.
  Device ids are not stable across reboots on any of the three platforms, so an
  id-only lookup silently drops you back to the test tone after a restart with
  no explanation.

- **Keyboard shortcuts, and a sheet that lists them.** Press `?` or `F1`, or the
  `?` in the status bar. Arrow keys nudge the selected module a cell and
  `Shift`+arrows resize it; `Ctrl`/`Cmd` with `N`, `D`, `Z`, `T`, `R`, `O`, `P`
  and `,` add a module, duplicate, undo, open a tab, restart the measurement,
  analyse a file, open presets and open settings. Open Audio Analyzer draws its
  own chrome and so has no menu bar to read a chord off, which is why the sheet
  exists.
- **`--config-dir` names where Open Audio Analyzer keeps settings, presets,
  delivery targets and skins**, and beats the `OAA_CONFIG_DIR` environment
  variable. On macOS it is the only one of the two that works on an installed
  `.app`: passing an environment variable means launching the binary inside the
  bundle, which changes how the system attributes the microphone request, so the
  variable and device capture could not be used in the same run.
- **`--open-panel=<name>` opens one panel once the window is up**, for
  `settings`, `presets`, `calibration`, `report` or `shortcuts`. Debug builds
  only; a release build says so rather than ignoring it.
- **Installers for all four desktop targets** — dmg, msix, AppImage and flatpak
  — plus the `oaa` analyser as a standalone binary, published on every tag.
- **A documentation site**, built from the Markdown in this repository and
  published from `main`. The keyboard page is generated from the same table the
  application binds, and a test fails if it has drifted.
- **An application icon**, at every size the four installers ask for.
- **The icon now covers iOS and Android too.** Both platforms were still
  shipping Flutter's default logo — the blue chevron on white — so the app
  installed on a phone or tablet under somebody else's mark. iOS gets the full
  layered icon described below; Android gets an adaptive icon, so the launcher
  masks it to whatever shape it uses and Android 13's themed home screen has a
  monochrome layer to tint instead of shrinking the icon inside a grey circle.
  There is a Play Store icon in `packaging/android/` for the console to be
  given by hand.
- **The macOS and iOS icon is layered, so the system lights it.** Both
  platforms now get an `AppIcon.icon` document — the graphite ground and the
  bars as separate layers — instead of a folder of pre-composited PNGs. macOS
  26 and iOS 26 render it with their own specular highlight and shadow, and
  derive the dark and tinted appearances from it; on a themed or dark home
  screen the icon now follows instead of staying light. Older systems are
  unaffected: the same document still produces a classic `.icns` back to macOS
  10.15 and flat icons back to iOS 13.

### ⚡ Changed

- **The icon's bars no longer climb in order.** They were 0.34, 0.55, 0.74,
  1.00 — which is the cellular signal glyph, drawn that way in the status bar
  of every phone the icon was about to appear on, and the shape is what the eye
  reads rather than the colour. They are now 0.62, 1.00, 0.44, 0.80: up, peak,
  valley, up, which is a meter. The bars also have slightly rounded corners,
  the tile's ground is a diagonal gradient from `hairline` to `background`
  instead of flat graphite, and the hairline border is gone — it was a
  one-pixel detail that iOS masked off, Android cropped, and 16 px could not
  draw. Every platform's artwork is regenerated from the same change.

- **The application is now called Open Audio Analyzer.** It was Bel. Nothing it
  measures changed — every reading is identical to the previous build — but
  the name it installs under, the directory it keeps your configuration in,
  the command-line binary and the protocol the tablet and the plugin speak
  all moved with it. The four below are the ones that can cost you something.
- **Your settings, presets, delivery targets and skins are not carried across.**
  Configuration now lives in `~/Library/Application Support/Open Audio Analyzer`
  on macOS, in `$XDG_CONFIG_HOME/oaa` or `~/.config/oaa` on Linux, and in the
  matching path on Windows. The old directory is left untouched and is never
  read; copy its contents over before the first launch to keep what you had.
- **This installs beside the previous version rather than over it.** The
  application identifier is now `dev.openaudioanalyzer.oaa`, so every installer
  and package manager treats this as a new application. Remove the old one by
  hand if you do not want both.
- **A tablet or a plugin from an earlier release will not connect.** The wire
  protocol is at version 2: the frame magic spells the new name, and a host
  advertises `_oaa._tcp` rather than `_bel._tcp`. A mismatched peer is refused
  at the handshake rather than drawing wrong numbers, which is the failure
  that matters — but both ends have to be updated together.
- **The command-line analyser is `oaa`, not `bel`.** Any script or CI step that
  calls it needs the new name; its arguments and its exit codes are unchanged.
- The status bar wordmark reads OAA, and the gap between it and the source
  picker is one step tighter. OAA sets about 3.4 px wider than the mark it
  replaced, which on its own was enough to run that row past its edge at
  1000 px with the longest delivery-target name.

- **Every number is set in Google Sans Code instead of JetBrains Mono.** The
  advance is 0.6 em in both faces, so nothing moves and no readout changes
  width; the digits are a little smaller on the body and rounder in the bowls.
  One character the old face carried is missing from the new one — `∞`, which a
  reading only shows if it is not finite, and nothing the engine produces is —
  so it now falls back to Inter, which Open Audio Analyzer already bundles,
  rather than to whatever the host offers. Both faces remain SIL OFL 1.1 and
  their licences still ship with every package.
- **Undo and redo in the tab strip carry a mirrored arrow beside the word.** The
  two words differ by one letter in the middle, and a mirrored pair says which
  way it goes before either has been read — but the arrow alone left the row's
  two most-used controls unnamed, so it now punctuates `UNDO` and `REDO` the way
  the plus punctuates `+ MODULE`. The arrows are drawn, like every other mark in
  Open Audio Analyzer, so they are the same on every platform and cost no
  dependency. The keyboard shortcuts are unchanged.
- **The delivery target in the status bar is built like the buttons beside it,
  one step quieter.** Same height and the same capitals, because it opens a menu
  on a click exactly as the four buttons to its right do and a control that can
  be pressed should look like one. Its border stays the fainter of the two
  hairlines, which is what still tells the thing that reports a setting from the
  four that do something. The target's own name is unchanged everywhere else:
  the menu, the settings panel and every report print it as it was typed.
- **A remote display's modules have no menu button.** The title bars drew one
  and it did nothing, because there is nothing on that screen a viewer is
  allowed to change. It is gone rather than disabled.
- **The stereo cloud's centre line is drawn over the frequency axis.** The three
  horizontal guides crossed in front of it, which broke the one line the module
  exists to mark into what looked like a dashed one.
- **A rule separates the tab strip's two kinds of action.** `UNDO` and `REDO`
  step back and forward through what has been done; `+ MODULE` does something
  new. They were four controls of the same size, colour and weight in one run.
- **A remote display's link bar has room to breathe, and its tabs are beside the
  host's name.** The bar is 48 px rather than 40, so the tab picker and
  Disconnect are not pressed against the rule under them, and the tabs now
  follow the name of the machine being watched instead of sitting in the far
  corner — which on a tablet is the most awkward place on the screen for the
  control the viewer touches most. Disconnect stays on the right, alone, where
  it is not hit by accident.
- **Both pluses in the tab strip are larger.** At the size the words use they
  read as specks rather than as controls. The one beside the tabs is the larger
  of the two, because it is the only symbol in the strip carrying an action with
  no word to help it; the one in `+ MODULE` is set between the two, visible
  without competing with the word it belongs to.
- **The keyboard sheet is one screen again.** Seventeen shortcuts in a single
  narrow column were taller than the panel, so the sheet scrolled and cut the
  line explaining that Ctrl and Cmd are interchangeable in half. It is now two
  columns on a wider panel — Canvas and Measurement on the left, Tabs and
  Configuration on the right — with the rows further apart and the whole list on
  screen at once, down to the smallest window Open Audio Analyzer supports.
  Below that it stacks back into one column rather than clipping. Measurement
  now comes before Tabs on the documentation site's keyboard page as well, which
  is the same ordering.
- **The remote panels are marked rather than only worded.** Sending and
  receiving were two rows of the same shape whose only difference was the
  sentence in them; each now carries a mark — a machine broadcasting, a screen
  on a stand — and a chevron on the rows that open a panel rather than choose in
  place. Every host a search finds wears the broadcast mark too, and it brightens
  under the pointer instead of sitting in the same grey as its address. A note
  that is a warning — the link has no password, this device cannot search the
  network, publishing failed — now has a warning mark in the margin beside it,
  so it is a different kind of line rather than a differently coloured one. The
  marks are drawn rather than typeset, so none of them can arrive as a tofu box
  on a platform whose fonts differ. Sending and receiving also sit further
  apart than the rows of a list do, since they are two directions to choose
  between rather than entries to pick from.
- **A machine's name, its port and the Apply that commits them are one line.**
  They were three stacked rows, so a two-field form read as three separate
  settings and the button that finishes it sat a row below either field. They
  now share a line, which the panel has room for.
- **A segmented control sets its choices in capitals**, like every button beside
  it. Source, refresh rate, the remote update rate and a display's tab picker
  were the only controls in the interface labelled in sentence case, which read
  as a line of prose in a box rather than as something to press. What a menu or
  a field holds — a device, a delivery target, a name somebody typed — is
  unchanged, because that is a value rather than the control's own word.
- **The Histogram's loudness line is always on screen.** It used to be drawn
  only over the columns the programme had reached, so an empty module — before
  the first audio, and for as long as you looked at it after a reset — had
  nothing in it at all, and a part-filled one had a line over part of its width.
  The line now rests on the floor of the scale and runs the full width of the
  plot, rising where the programme starts. Resting is not a reading: the floor
  is the bottom of the scale, nothing is filled beneath it, and it is drawn
  where measured silence would put it.
- **Nothing is a double click any more.** Renaming a tab, adding a module by
  clicking empty canvas, and zooming the window from the status bar were all
  double clicks; the first two are now a long press — which also gives a tablet
  a tab's rename, duplicate and delete for the first time — and the window is
  zoomed with the green window button, as it always could be. See 🐛 Fixed for
  why a double click was worth removing.
- **Moving a module dims the rest of the canvas, and the placement grid now has
  a border.** The grid is ruled inside a rounded border that sits one gutter
  outside the modules, with the same corner radius they have, and for as long as
  the pointer is down every module except the one in hand is washed toward the
  canvas colour. A drop target among a dozen meters that are all still moving
  was something you had to hunt for; the cells, the module being carried and
  where it will land are now the only things at full contrast. Nothing is
  measured differently — the meters underneath keep updating throughout.
- **The phase scope's trail no longer smears.** It was a picture faded and
  redrawn on every frame, so a moving dot was resampled once per frame and
  spread outwards; it is now the last forty frames of samples, each drawn at
  the brightness its age has earned. A dot fades where it was rather than
  blurring, and the decay is exact instead of compounding through the rounding
  of an 8-bit surface — the tail is fractionally longer for the same reason.
- **The stereo cloud is accumulated as numbers rather than as a picture**, in
  cells of two logical pixels, with each band's dot spread across the four
  cells it falls between. The shape, the fade and the brightness are the same;
  a close look finds dots on a two-pixel grid where they were previously at
  arbitrary positions.
- **A module's readings now grow with the module.** The bars, the arcs and the
  VU face have always been sized off the tile they are in; four modules sized
  their *numbers* off a constant instead, so the LUFS meter's LUFS-I and LRA,
  the Super Meter's centre readout, the Alert Meter's value and the Validator's
  measured column stayed the same size whether the module had a corner of a
  laptop screen or a quarter of a 27" one. The labels beside them — a scale's
  ticks, a column heading, PASS and FAIL — deliberately do not scale; they are
  the same size in every module on the canvas.
- **The smallest supported window is now 960x768, up from 720x480** (macOS; the
  other platforms set no minimum). The canvas is a fixed 24x16 cells at every
  window size, so at 480 px tall a two-row module had 12 px of body left after
  its title bar and margin — less than a digit. 768 is the height at which the
  smallest module in the default preset still has room for its number.
- **A module too small to draw in now says so instead of showing an empty
  panel.** The size a module needs is in pixels, not grid cells, so it was
  never something the cell minimums could enforce; each painter checked it
  privately and drew nothing when it failed. The thresholds are now declared on
  `ModuleKind` and the frame substitutes the "too small" placeholder, which is
  what it was always for.
- **The status bar drops items in a stated order as the window narrows**, one
  at a time and each at the width below which the rest stop fitting: first the
  sample-rate readout, then the OAA wordmark, then ANALYSE FILE, then REMOTE,
  then the `?` button. All four buttons keep their keyboard shortcuts, which
  are listed in the `?` sheet and in
  [docs/site/keyboard.md](docs/site/keyboard.md). What never drops is the
  source, the elapsed clock, the delivery target, SETTINGS and RESET. There was
  one gate before this, it was 20 px too generous, and nothing had measured it.
- **The settings panel has been reworked, and every other panel with it.**
  Sections are now ruled off from each other with a hairline instead of by
  whitespace alone, so Signal, Meters, Appearance and Session read as four
  groups rather than one column of grey; a row's explanation runs the full
  width of the panel underneath its control instead of wrapping in whatever
  space the control left over; and the loopback advice under Capture device is
  two lines rather than four. The same changes reach the preset browser, the
  delivery-target editor, the analysis report, the remote-display panel and the
  keyboard sheet, because all six are built from the same primitives.

- **REMOTE now asks which end of the link this machine is.** Pressing it opens
  a chooser — send these meters, or show another machine's — and each answer
  opens its own panel. Publishing used to be the whole of what the button
  offered: turning this screen into a display was a footer button on the
  publishing dialog marked "Use as display", which is the row a panel reserves
  for the ways out of it. The chooser also says whether this machine is already
  publishing and how many displays are attached, so that is answerable without
  opening anything further.

- **The remote display's connect screen is a panel like every other panel.** It
  was the one screen in Open Audio Analyzer that had never been near the design
  system — an unstyled list, a stock text field with a rounded outline and
  Material text buttons, on the hardware the feature exists for. Discovered
  hosts are panel rows now, the typed address is an Open Audio Analyzer field
  with Connect in the footer, and it is the same panel the desktop opens rather
  than a second implementation of it. The strip across the top of a live display
  gets the status bar's fill and hairline, with the tab picker and Disconnect as
  controls rather than as text. Disconnecting returns to the picker instead of
  to a dead screen.

- **Every boxed control in a panel is the same height.** Buttons, menus,
  segmented controls and text fields derived their heights independently and
  came out at 30, 32, 31.4 and 28.9 px, so no two standing side by side in a
  row ever quite lined up. They are all 32 px now.

- **A menu looks like a menu.** The capture-device and delivery-target pickers
  were bordered labels in caption grey — fainter than the buttons beside them,
  which reads as disabled — with nothing to say they opened anything. They now
  carry a caret, show their value in the same weight as the rest of the panel,
  highlight under the pointer, mark the current choice in the open menu, and
  can be reached and opened from the keyboard, which neither of them could
  before. The menu also no longer arrives with a Material drop shadow.

- **The selected skin is visible as selected.** Selection in a panel list was
  carried by a single step of grey on a 1 px border; it is now a raised fill as
  well.

- **The unfilled part of a meter is now visible.** `meter_track` sat at 1.10:1
  against the panel behind it on the dark skin and 1.22:1 on the light one —
  close enough to the surface that a bar showed its own fill and nothing else,
  and the Super Meter's three arcs could only be located by whichever one
  happened to be lit. Both shipped skins now hold it at roughly 1.6:1, and
  still about 2.5:1 below `meter_fill` so the reading stays the figure and the
  track stays the ground. **A user skin that sets `meter_track` keeps its own
  value**; a skin that inherits it gets the new one.

- **Modules have room to breathe, and the same amount of it on every side.**
  The inset between a module's border and its meter went from 8 px to 12 px,
  and the title bar's inset moved with it so the title still starts where the
  meter starts. Meters draw to the edges of what the frame hands them — a
  painter that adds a second inset of its own is a module that sits differently
  from the other eleven.

- **A dB scale no longer reserves more room than it uses.** The gutter beside a
  graticule was a flat 30 px whatever the labels said, so a meter with short
  labels sat visibly off-centre in its module — thirteen pixels of empty
  reserve on the scale side against nothing on the other. It is now measured
  from the labels themselves. Affects the LUFS meter, the digital meter, the
  spectrum analyser and the histogram.

- **The VU dial is sized to the module rather than to a fixed sweep.** The face
  opened 70° whatever shape the tile was, which in a wide tile drew the whole
  instrument across the middle half of the width and left the rest bare. The
  sweep now opens as far as the box allows, between 70° and 110°, and the dial
  is centred on what is actually drawn.

- **The frame rate is no longer in the status bar.** It was a second way to
  reach one setting, sitting in a row otherwise reserved for what changes while
  you work and what a reading has to be read against. It is chosen once for a
  machine; it lives in the settings panel and only there. The delivery target
  stays in the bar, because every `PASS` and `FAIL` on the canvas is a verdict
  against it.

- **A panel that scrolls now says so.** Settings is taller than the 760 px a
  panel is allowed and ended on a row the viewport happened to cut in half,
  with nothing to suggest there was more below it. A scrollbar appears when the
  content overflows and stays hidden when it does not.

- **The `REMOTE` button now looks like the rest of the status bar.** It was the
  one stock Material button in the row — borderless where its four neighbours
  are bordered, Material-sized rather than bar-sized, ink-rippled, and not
  reachable by keyboard. It now carries the same border, padding, type and
  focus ring as `ANALYSE FILE`, `SETTINGS` and `RESET`, and states what it is
  doing on hover. Publishing is shown by the label brightening rather than by
  the signal hue, which in this row means "in spec" and nothing else. The
  panel behind it is built from the same pieces as the other panels.

- **The macOS window has no title bar of its own.** The status bar now runs to
  the top edge of the window, and the close, minimise and zoom buttons sit
  inside it on the same row as the source and the elapsed clock. The strip of
  system grey above a bar of panel grey, and the window title printed in a font
  Open Audio Analyzer does not choose, are both gone. Dragging the status bar
  moves the window and double-clicking it zooms, as dragging and double-clicking
  the title bar did. Windows and Linux are unchanged.
- **A light skin no longer runs under dark window buttons on macOS.** The window
  follows the skin's `light` flag, so Daylight gets light chrome and the two
  stop disagreeing about which way up the room is.
- **The signal hue now means one thing on the canvas.** Teal previously marked
  both "in spec" and "selected", so a selected module was outlined in the same
  colour as a reading that had passed its target, a few pixels from the reading
  itself. Selection is now a brighter, heavier border; the active tab, the
  highlighted menu row, the resize grip, the listening indicator and the drop
  preview all moved to neutral values. Teal now appears on the canvas only when
  something is within its delivery target.
- The em dash that means "not measured" is drawn in a legible colour. It shared
  a value with scale ticks and disabled controls, at 2.81:1 against the panel
  against readings at 15:1 — the one mark in the interface that says a quantity
  was *not* measured was the hardest one to see.
- Selection, hover and focus borders are visible. `hairline_strong` was 1.47:1
  against the panel — a role whose whole purpose is to be seen, set to a value
  that could not be, which is why callers reached past it for the accent. It is
  now roughly 3:1 in both shipped skins. **A user skin that sets
  `hairline_strong` keeps its own value and is unaffected.**
- `RESET` now states its scope on hover: it restarts the measurement, and
  leaves the layout, target and skin alone.
- The meters cap themselves at 30 fps when the system asks for reduced motion,
  and the settings panel says so rather than showing a rate nothing is running
  at. Open Audio Analyzer has no decorative animation to switch off — what moves
  is the measurement — so a lower redraw rate is the only honest reading of that
  preference. No reading is withheld.
- The main view is an arrangeable canvas instead of a fixed wall showing every
  metric at once. It opens on six readings — LUFS-M, LUFS-S, LUFS-I, LRA, TP
  Max and Peak Max — and the rest of the canvas is yours.
- A module's default measurement now follows its kind rather than always being
  integrated loudness, so a freshly placed Alert Meter watches true peak — which
  is what an alert is for. A saved layout that omitted the key reads back
  differently for alert meters.
- The signal source is a persisted setting rather than something the status bar
  holds. Two controls can change it now — the bar and the settings panel — and
  both write to the same place, which is also what lets the next launch reopen
  it.
- The interface no longer has a single compile-time palette. Everything that
  draws takes its colours from the active skin.
- The delivery-target menu lists the user's own targets alongside the built-in
  ones.
- The DAW plugin ships as **VST3 and Audio Unit** rather than the CLAP the plan
  named. CLAP's SDK is the nicest of the three, but Ableton Live does not host
  CLAP, and a metering plugin that cannot be inserted in Live is one most
  people cannot use.

- **Keyboard shortcuts work wherever focus is.** They were installed inside the
  canvas and stopped working the moment focus left it — clicking the source
  picker was enough to silently disable undo. They now wrap the whole
  workspace.
- The tab strip's `+` sits beside the last tab and scrolls with the tabs,
  rather than being carried to the far end of the strip.

### 🐛 Fixed

- **A remote display recovers from a dropped link, instead of showing one frame
  of invented measurement and then never coming back.** A connection that died
  partway through a measurement left the head of that frame in the display's
  frame reader, which nothing cleared — so the retry reassembled the dead
  stream's bytes onto the live one. That splice is exactly the right length to
  decode, so the meters drew a detailed, confident reading nobody took, lost
  sync on whatever followed, and dropped the link again, carrying the leftovers
  into every attempt after that. A tablet that lost a single frame to a Wi-Fi
  hiccup stopped recovering until the app was restarted — Disconnect and
  reattach did not clear it either. Nothing about how Open Audio Analyzer
  measures has changed and no past reading needs re-checking: the desktop and
  the CLI were never on this path.
- **The status bar's controls are one height.** The delivery target read 25.4 px
  tall against 22 px for the four buttons beside it, because each shape derived
  its height from its own text style plus its own padding rather than being
  given one. The borders in the row now start and end on the same pixel.
- **A warning mark sits in the middle of the note it marks.** It was pinned to
  the top of the block, so beside the sending panel's two lines of orange it
  looked as though it belonged to the first line rather than to the warning.
- **A long capture session no longer dies with a bus error.** The sub-block
  ring the loudness measurements are built from carried a write cursor beside
  it, and the store into the ring trusted that cursor. One was found holding a
  float bit pattern after 36 minutes of capture, which turned an ordinary
  100 ms boundary into an 8-byte write 229 GB past the engine and killed the
  process. The row is now derived from the sub-block count where it is used, so
  the write lands inside the ring whatever the counter holds. Every reading is
  unchanged, bit for bit, and the EBU conformance vectors still pass. What put
  a float there has not been identified; this stops the engine turning it into
  a wild store.
- **A capture device is released when the engine fails to start.** If an
  allocation failed after the device had been started — sizing the analysis
  buffer, or the spectrum's transforms — the engine was freed while the
  real-time callback was still writing into the ring inside it, handing that
  callback a dangling pointer into a block the allocator was about to reuse.
  Startup now tears the device down on every failing path.
- **An iPad can now find hosts on the network.** It never could: iOS and iPadOS
  refuse an app the multicast socket Open Audio Analyzer browses with unless it
  carries an entitlement Apple grants per developer on request, so every send
  was rejected and nothing was ever delivered — on the hardware the remote
  display exists for. The tablet now searches through the system's own Bonjour
  responder, which needs no entitlement, and finds the same hosts by the same
  name. Typing an address still works and still always will.
- **A host on a network that hands out a domain is visible again.** Most routers
  give DHCP clients one, which makes the machine's name `studio-mac.fritz.box`
  rather than `studio-mac.local` — and Open Audio Analyzer advertised that whole
  string where DNS-SD allows a single label, so the announcement came out as six
  labels instead of four. Open Audio Analyzer's own browser read it anyway, so
  an Open Audio Analyzer desktop found an Open Audio Analyzer desktop and
  nothing looked wrong; every browser built on the system responder — an iPad,
  `dns-sd`, anything Apple — dropped the record, and the host answered every
  query on the wire while appearing to no one. The instance is now one label
  whatever the machine is called, and the name you read in the list is
  unchanged.
- **Open Audio Analyzer no longer advertises an address record for the machine's
  own name.** The name a Mac answers to belongs to the system responder, which
  defends it: an address record it did not publish, for a name it owns, is a
  conflict, and the loser of a conflict renames itself. On a machine with a
  second network interface the two sets differ, so the loser would have been the
  user's computer. Open Audio Analyzer publishes its own name for the service to
  point at.
- **A search that cannot run says why.** A device that could not search showed
  *Looking for hosts on this network…* indefinitely, which is exactly what a
  network with no hosts on it looks like. It now names the reason where there
  is one to name — a refused Local Network permission on macOS points at
  System Settings — and says plainly that it cannot search where there is not.
- **A laptop in a dock is listed at an address that answers.** A machine with a
  second network interface — an empty dock, a Thunderbolt bridge — announces
  every address it has, and the browser kept whichever arrived last. Half the
  time that was the interface's self-assigned 169.254 address, which nothing on
  the network can reach, so the host appeared in the list and the connection
  timed out. A routable address is now preferred, and a host that moves
  replaces its old address rather than adding to it.
- **A panel follows a change of skin while it is open.** Choosing one in
  Settings → Appearance repainted the canvas, the window chrome and the panel's
  own text fields and menus, but left the panel's surface, hairlines, labels and
  the dimming over the canvas in the previous skin until the panel was closed
  and reopened — so the one place a skin is chosen was the one place it could
  not be seen, and the panel was drawn in two skins at once meanwhile.
- **A two-finger trackpad gesture no longer drags things.** Right-clicking a
  module's title bar on a trackpad flashed the placement grid on screen, because
  a two-finger tap is how macOS sends that click and every drag in the
  application accepted a trackpad gesture as one: a two-finger scroll over a
  title bar moved the module, over the corner grip resized it, and over the
  status bar it started dragging the window. A drag now begins from a button
  press and from nothing else. Clicking and dragging on a trackpad is
  unaffected — that is a mouse as far as the system is concerned.
- **The top of a meter's scale is no longer cut in half.** The `0` on the LUFS
  meter was drawn as its own bottom half, and the same line of code clipped the
  spectrum analyser's top label and the first and last labels on the
  histogram's frequency axis. An end label now sits fully inside the meter; its
  gridline has not moved.
- **The `M` and `S` under the LUFS meter's bars are drawn at all.** They were
  centre-aligned in an unconstrained line box, which put each letter half a
  megapixel to the right of the meter — so the two bars had nothing naming
  them and the space for the names was still reserved beneath them.
- **The LUFS meter's two readings are no longer printed with their last digit
  missing.** They were sized off the module's height alone, so a tall narrow
  meter asked for digits wider than the column under the bar they belong to and
  the reading stopped drawing where it ran out of room: `-17.6` was shown as
  `-17.`, which reads as a different number rather than as a clipped one. Both
  now take the largest size that fits the column as well as the height, and are
  hidden — as they already were on a short module — when that size would be too
  small to read.
- **The super meter's ring names sit beside the arcs they name.** `M`, `S` and
  `I` led their arcs by a fixed angle, which is a fixed fraction of each
  radius, so the outer name stood nearly twice as far from its arc as the inner
  one did from its and the three read as a diagonal drifting off the gauge.
  They are now the same distance from every arc.
- **Buttons no longer take a third of a second to respond.** Every control in
  the status bar on macOS, every tab, and clicking empty canvas to clear the
  selection fired 300 ms after the click that pressed them. Each sat under a
  gesture that also recognised a double click, and Flutter's double-tap
  recogniser holds the gesture arena from the first tap until it times out —
  so the button's own tap could not be resolved until the wait for a second
  click had expired. The double clicks are gone (see ⚡ Changed) and the
  controls answer on release.
- **Open Audio Analyzer crashed after a few minutes with a spectrogram, phase
  scope or stereo cloud on the canvas, and grew without bound until it did.**
  One report showed the application holding 266 GB before macOS stopped it.
  Those three modules accumulated their history into an image taken with
  `toImageSync`, which retains the display list that drew it for as long as the
  image lives — so every frame's image pinned the frame before it, back to the
  first one, and disposing the handle released none of it. The application then
  died on the raster thread when that chain was finally dropped and its
  destructors recursed once per retained frame, 3,286 deep in the report that
  found this. All three now keep their history as data and redraw it, which
  costs memory proportional to the module's size rather than to how long Open
  Audio Analyzer has been open.
- **A spectrogram opened before any audio arrived began with a column of full
  scale, and the stereo cloud with a bright line down its centre.** Both were
  reading the zeroed arrays of a source that has not published yet, which as
  dB is 0 dBFS on every band. A source that has measured nothing now draws
  nothing.
- **The LUFS meter's two readouts sat under the wrong things.** They were laid
  out against the middle of the module, but the bars begin after the scale's
  gutter — so LUFS-I printed under the scale numbers and LRA under the middle
  of the momentary bar. Both now line up with the bars they sit below. No
  reading changed; the two numbers are the same numbers, in the right column.
- **Six Number Boxes rendered as empty panels on a small window.** On anything
  under about 700 px tall a two-row Number Box had less body than a digit is
  tall, and the painter's own size check meant it drew nothing rather than
  saying so. Every module now shows the "too small" placeholder instead, and
  the supported minimum window is large enough that the default preset never
  reaches it.
- **The status bar ran 121 px past the edge of the window** at the smallest
  size the window could be dragged to. In a debug build that is a striped
  overflow warning; in a release build the controls past the edge are simply
  not there.
- **The signal source overflowed its own place in the bar** whenever the name
  of the capture device came close to filling the room the bar had left for it
  — a striped warning across the source label in a debug build, and a name
  clipped without a mark in a release one. The name now shortens with an
  ellipsis to whatever the row can spare, as the delivery target beside it
  already did.
- **The Stereo Cloud looked broken on a mono source.** A built-in laptop
  microphone has one channel, per-band stereo position needs two, and the
  engine reports mono as dead centre — so every band plotted at the middle of
  the display and the module drew one bright vertical line and nothing else,
  which reads as a rendering fault rather than as a mono signal. It now says
  **MONO SOURCE** across the face and leaves the axis empty. No measurement
  changed; a stereo source draws exactly as before.

- **Selecting a capture device did nothing.** Only the source chosen at launch
  ever opened; every change made afterwards — from the status bar or from
  Settings, to a microphone, an interface, a loopback device, Silence or back
  to the test tone — was discarded. The choice was saved and reappeared as
  selected the next time you looked, so the meters looked like the failure:
  they went on showing the previous source, with its label, its channel count
  and its elapsed clock still running, exactly as though no input were
  reaching the machine. Each attempt also opened the device and held it with
  nothing reading it, which is why the system's recording indicator came on
  while the meters stayed on the test tone. Relaunching with the device already
  selected was the only way through, and is no longer needed.

- **Every panel's four corners were missing their border.** The surface is a
  rounded clip over a square border, so the clip removed the corner of the
  hairline along with everything else outside the arc: the border ran the flat
  edges and stopped dead at each tangent, leaving four bare arcs of panel fill
  fading into the barrier. The border now carries the same radius as the clip
  and runs continuously around the corner. Settings, the preset browser, the
  calibration editor, the report, the remote display panel and the shortcuts
  sheet are all built from that one surface, so all six are corrected — as is
  the startup notice, which had the same defect at a smaller radius.

- **The elapsed clock sat two pixels high in the status bar.** It is painted
  rather than built, and it was drawn from the top-left corner of a box taller
  than the line it holds, so every spare pixel fell below the digits and the
  clock rode above the optical centre of every label beside it. It now centres
  its line in its box, which is what a `Text` does with the space it is given.

- **Everything in the tab strip's action row sat a pixel below the tab names**
  — most visibly the `+` that adds a tab, which stands directly beside the last
  one. A tab reserves the height of the active-tab rule whether or not it is
  the active tab, and the buttons reserved nothing, so the two rows of text
  were centred in boxes of different heights. The `+` was low for a second
  reason as well: a lone plus is drawn on the font's math axis, below the
  middle of the band the words around it fill, and it is now raised onto their
  line.

- **The LUFS meter's two bars, and the digital meter's channels, shared one
  background.** The gap between bars was painted in the trough colour, so it
  only showed where one bar's fill had risen past the other's: two channels at
  the same level read as a single wide bar, and two at different levels as one
  bar with a step in it. Each bar now has its own trough and the gap shows the
  module behind it. The scale, the target band and the integrated rule still
  cross it — they belong to the meter, not to either bar.

- **The VU meter's face had four drawing defects.** The needle was drawn from
  behind its own pivot with a tail longer than the cap meant to hide it, so a
  second short needle stuck out of the bottom pointing the other way. At rest
  it lay along the −20 mark and struck that label through — and every reading
  on the lower half of the face had the needle across it, because the labels
  were inside the sweep. The six scale numbers were centred on a common radius
  rather than cleared from the arc by a common gap, so they scattered, with `0`
  hanging below its own tick. And the dial sat high and left in the tile with
  the `VU` badge adrift in the empty corner. The needle now runs outwards only,
  the labels sit outside the arc where nothing can cross them, each one clears
  the arc by the same gap whatever its angle, and the badge sits under the
  pivot where the needle cannot reach. **The ballistics and the scale are
  unchanged — the needle points at the same mark it did before.**

- **Four modules drew their contents in a corner instead of in the box.** A
  Number Box put its reading against the left edge, which on an unavailable
  reading left a single em dash alone in the corner of a four-cell tile,
  looking like a rendering fault rather than "not measured yet". An Alert Meter
  hung its block from the top edge of a module more than twice its height. The
  Super Meter centred itself as though it were a full circle when it opens 120°
  at the bottom, leaving a dead band a fifth of the module deep beneath it. The
  Validator stopped its rows at 34 px each and left the rest of the tile blank.

- **A one-row Number Box drew a title bar and nothing else.** A single grid row
  is about 55 px, and the title bar and the module's inset account for all of
  it, so the reading had no room and the painter returned without drawing —
  blank, rather than the "too small" a module says when it cannot be read. The
  minimum is two rows now, and a stored layout holding a one-row box is
  clamped up rather than rejected.

- **The delivery-target menu did not show which target was selected.** Both
  arms of the ternary that picks the row colour returned the same value, so
  every entry was drawn identically and the active target was indistinguishable
  from the five it was listed with.

- **The right-hand end of the status bar drifted away from the right edge.**
  The elapsed clock, the calibration and the four buttons sat
  progressively further from the window's right side the wider the window got,
  leaving a growing empty stretch of bar beside them. They are now flush with
  the edge at every width.

- **The remote display panel could not be opened.** Pressing `REMOTE` in the
  status bar threw "No OaaTheme in scope" and left the panel unbuilt, in
  release as well as debug — it was pushed with `showDialog`, so the
  `Navigator` built it above the palette the application provides. It is now
  pushed with `showOaaPanel` like the other five, and a test opens it through
  the button.

- **Open Audio Analyzer could not be built for iPadOS at all.** The engine was
  compiled as C on every platform, but miniaudio's Core Audio backend is
  Objective-C on iOS — it configures an `AVAudioSession`, which has no C
  interface — so the build ended in several hundred errors inside Apple's
  `Foundation` headers, none of which named a file in Open Audio Analyzer. The
  iOS build now compiles as Objective-C and links the frameworks miniaudio needs
  there. The tablet build is the remote display, and it now runs on an iPad.
- **The iPad build would have been terminated by iOS the first time an input
  was chosen.** `NSMicrophoneUsageDescription` was missing from the app's
  `Info.plist`, which is not an error the app can catch — the system kills a
  process that touches the microphone without one.

- **An iPad remembered nothing between launches** and opened with "no
  configuration directory". Open Audio Analyzer resolved its configuration from
  `HOME`, which iOS does not set — so every layout, skin and connection was lost
  when the app was closed. iPadOS now keeps its configuration in
  `Library/Application Support/Open Audio Analyzer` inside the app's own
  container, which Open Audio Analyzer locates through the temporary directory
  rather than the environment. An Android tablet still persists nothing, and
  still says so at launch.

- **A module's resize grip was drawn outside the module.** Both ticks ran to
  the corner of the module's slot, which is past the frame's rounded border —
  so they crossed the border and finished in the gutter between modules, and on
  a selected module they cut through the selection outline. They now sit inside
  the panel in both states; the area you can grab is unchanged.
- **Selecting a module broke its own outline in two places.** The rule under
  the title bar ran the full width of the frame and was painted after the
  border, so it printed the dim hairline colour over the bright selection
  border at each end. The rule now stops at the border's inner edge.

- **Nothing in a panel could be reached from the keyboard.** Every control Open
  Audio Analyzer paints itself — buttons, toggles, segmented controls, list
  rows, icon targets — was a bare gesture detector, so none of them took focus,
  none responded to Enter or Space, none drew a focus ring, and none was visible
  to a screen reader. Settings, presets and the delivery-target editor were
  mouse-only with nothing on screen to say so. All of them are now focusable,
  keyboard operable, and announced.

- **Opening the host picker a second time searched a browse that had already
  been shut down.** A tablet's search runs over one channel, and a channel keeps
  one subscription: opening a second picker while the first was still on screen
  — which happens for a frame every time one replaces another — ended the first
  one's browse, and the first one's teardown then ended the second's. The panel
  left on screen said "Looking for hosts on this network…" over nothing that was
  running, found no host however long it was left, and logged "No active stream
  to cancel" when it was closed. The search is now shared: one browse for the
  application, handed to whoever is looking, and stopped when the last of them
  closes.

- Changing the signal source could replace every meter on the canvas with a red
  error box reading "A MeterClock was used after being disposed". The old clock
  was torn down before the new one was installed, so any painter still mounted
  for that frame — which is all of them — tried to attach to a disposed
  notifier. Disposal now happens after the frame that replaces it.

- **Tabs were clipped off the end of the strip while it was visibly half
  empty.** The tab area and the gap before the action buttons were two flex
  children of equal weight, so the strip gave half its free width to the gap.
  Three tabs in an 800 px window were enough to lose one.
- **Renaming a tab from its context menu opened a field that would not accept
  typing.** The menu's route restored focus to the canvas after the field had
  claimed it. Double-clicking a tab was never affected, which is what made this
  hard to see: the two ways in behaved differently.
- **Every keyboard shortcut stopped working after a text field closed**, until
  something was clicked. Focus fell back to the navigator's scope, which sits
  above the bindings, and a key event travels up from the focused node — so
  there was nothing below it to reach.
- **Closing the host picker on a tablet while it was still searching threw.**
  Ending the Bonjour browse suspends on the channel, and the rest of the stop —
  which publishes an empty list of hosts — ran after the picker had already
  disposed the notifier it publishes to. It surfaced as "A
  ValueNotifier&lt;List&lt;DiscoveredHost&gt;&gt; was used after being disposed"
  in the log, most reliably on a hot restart. The search is now published as
  ended before anything is awaited, and teardown releases the browse without
  publishing at all.
- **A display leaving mid-frame threw in the host it was leaving.** Closing a
  socket that is still flushing a measurement is a `StateError` in Dart's own
  I/O — "StreamSink is bound to a stream" — and it was raised inside the
  socket's own close notification, where nothing could catch it. Every tablet
  that dropped off at the wrong moment logged what reads as a crash and left
  the connection it was there to give back.
- **Changing the skin, the layout or the delivery target could disconnect a
  display.** The new setting goes out the instant it changes, and a socket
  still flushing a measurement refuses to be written to — which the host could
  only read as "this display has gone", and act on. It was likelier the slower
  the display was. A setting now waits for the frame in front of it and then
  goes, in order.
- **Attaching to another machine flashed the host picker on the way in, and
  started a second search behind it.** The link said it was connecting one turn
  after it began, and a display shows the picker until it does — so a screen
  that had already been told where to attach spent a frame drawing a panel
  asking where to attach, and a picker searches the network as soon as it is
  built.
- **Closing the host picker while it was still opening its socket threw.**
  Binding is real I/O, and the search could be shut down while it was in
  flight: what came back then was written to a notifier that had been disposed,
  and the socket it arrived with was never closed. On macOS the window is as
  long as the Local Network prompt is on screen.
- **A panel row's explanation no longer runs into the control above it.** The
  caption sat two pixels under the row, and a row is as tall as whatever sits on
  its right — so under a bordered control it collided with the bottom edge
  rather than reading as a line of its own. The delivery target showed it worst:
  its note ended directly beneath the target menu and looked like part of it. It
  now clears the control, and still sits half as far from its own row as from
  the next one.
- The documentation site shows the current mark. Its header logo and favicon
  were a hand-copied version of the icon compiled into the site generator, so
  when the mark was redrawn they kept publishing the previous one on every
  page. The generator now reads `assets/brand/oaa-mark.svg` and fails when it
  is missing, so the site cannot hold a mark of its own again.
- The `oaa` CLI is published again. It was built with `dart compile exe`,
  which refuses a package whose dependencies have build hooks — `oaa_engine`
  has one — so no CLI reached a release at all. It is built with `dart build
  cli` now and ships as an archive of the executable and the engine beside it
  rather than as a single file; keep the two together. CI builds it the same
  way and runs the result, which nothing did before.
- The Windows package builds. Its manifest named the application
  `Open Audio Analyzer` where a package identifier is required, which the
  rename from Bel introduced and which fails validation with a line number and
  no mention of the name; the identifier is `Oaa` and the display name is
  unchanged.
- The Linux flatpak builds. Two things stopped it. Installing the runtime used
  a partial reference, which makes flatpak ask which of the matching ones is
  meant — a question `-y` does not answer and a CI runner cannot — so the job
  waited instead of failing. And the scalable icon was read through gdk-pixbuf
  by the AppStream step, which cannot decode an SVG unless librsvg has
  registered a loader; where it has not, a valid file is reported as an
  unrecognised format and the build fails with the package already assembled.
  The flatpak now ships the seven PNG sizes and no scalable icon, which is what
  a launcher uses either way.

### 🚧 Internal

- The install pages name the files a release actually publishes. Every
  installer is built as `Open Audio Analyzer-<version>-…` and GitHub replaces
  the spaces with periods when it attaches it, so the documented names — and
  the two shell commands printed for a reader to paste — matched nothing on the
  releases page. They are dot-separated now, and the difference is explained
  where it appears.
- Every identifier follows the name. The public C ABI is `oaa_*` and `OAA_*` in
  `engine/include/oaa/oaa.h`, the packages are `oaa_core`, `oaa_ui`,
  `oaa_engine` and `oaa_wire`, and the plugin's classes are `Oaa*`.
  `OAA_ABI_VERSION` stays at 4: the header's shape did not move, only its
  spelling.
- The release workflow reads `OAA_SIGNING_IDENTITY`, `OAA_NOTARY_PROFILE`,
  `OAA_WINDOWS_CERT`, `OAA_WINDOWS_CERT_PASS` and `OAA_WINDOWS_PUBLISHER`. The
  repository secrets have to be renamed to match, or every signed artefact
  quietly stops being signed.
- The repository, the documentation site and every download link moved to
  `open_audio_analyzer`.
- The cross-implementation wire golden is now `plugin/test/golden/wire_v2.bin`,
  regenerated from `oaa_wire_fixture`.
- The released sections below describe the application under its former name.
  They were renamed with the rest of the repository rather than left to
  contradict it; nothing else about them was rewritten.

- **Stopping the engine decides whether to join on the flag that tracks the
  thread.** It tested `should_run` — the flag stop itself clears — so anything
  that ever cleared it elsewhere would have turned destroying an engine into a
  free underneath a live analysis thread. It now tests whether a thread was
  started and not yet joined.
- **`PersistenceLayer` is gone, and with it the last `toImageSync` in the
  application.** `PointBuckets` replaces it: marks sorted by the colour they
  are drawn in, so a display of thirty thousand of them is a few dozen calls
  rather than thirty thousand. `test/history_modules_test.dart` fails if any of
  the three modules creates an image between frames again.
- **`packages/oaa_wire`** — the wire protocol, pure Dart and MIT, specified
  byte for byte in `docs/WIRE.md`. Three implementations speak it and none of
  them was written against another: the app's host, the app's display, and the
  plugin's C++ sender. `plugin/test/golden/wire_v2.bin` holds the Dart codec
  against bytes the C++ actually produced, which is the only test that would
  catch the two drifting apart — and the drift is silent, because every frame is
  a fixed length, so a field written into the wrong slot still parses.
- **`MeterSource`** — the interface a meter module reads a measurement out of,
  in `oaa_core`. `OaaEngine` implements it and so does the remote display's
  decoder, which is what lets the twelve modules run unchanged on a tablet with
  no engine in it. `oaa_engine` now depends on `oaa_core` for that one
  interface; the arrow still points away from `dart:ffi`.
- **`MeterClock` decides what is new by comparing generations** rather than by
  trusting what `refresh()` returned. With the remote host refreshing on its own
  timer there are two callers, and a one-shot "is this new" answer is consumed
  by whichever asks first — leaving the other to stop repainting, silently, only
  on the machines where somebody was using both screens at once.
- **`plugin/` is AGPL-3.0-or-later, not GPL-3.0.** JUCE 7 and 8 are
  AGPLv3-or-commercial; only JUCE 6 offered GPLv3, which is what the plan was
  written against. Open Audio Analyzer takes the AGPLv3 option, which changes
  the licence of the plugin binary alone: the engine stays MIT, and the app
  stays GPL-3.0-or-later because it never links JUCE — it talks to the plugin
  over a socket. GPLv3 section 13 expressly permits the combination. One piece
  of good news the plan did not anticipate: Steinberg has relicensed the VST3
  SDK to MIT, so JUCE is the only copyleft dependency and no separate SDK
  checkout is needed.
- `engine/CMakeLists.txt` builds `liboaa` as a static library for consumers that
  are not Dart. There are now two descriptions of the same compile, because a
  plugin CI runner has no Flutter SDK and a build hook cannot be handed to JUCE;
  `plugin/test/sources_match.sh` fails the build if they drift apart.
- The C++ and Dart implementations of the wire protocol are held against a
  committed golden that the plugin's own serialiser generates, rather than each
  end round-tripping against itself. A field transcribed into the wrong slot
  still parses — every frame is a fixed length — so the app would draw a
  spectrum out of the scope buffer and look entirely plausible doing it. The
  golden asserts NaN and negative infinity survive unchanged, both being bit
  patterns a careless serialiser normalises.
- JUCE 8.0.15 is pinned and fetched rather than vendored, so the repository does
  not grow by 110 MB to record a version number.
- miniaudio v0.11.25 vendored under `engine/third_party/` (public domain /
  MIT-0), with everything but the device layer compiled out.
- dr_wav 0.14.6, dr_flac 0.13.4 and dr_mp3 0.7.4 vendored under
  `engine/third_party/dr_libs/` (public domain / MIT-0), compiled in one
  translation unit separate from the device layer. `MA_NO_DECODING` in
  `oaa_device.c` is what stops miniaudio compiling its own bundled copies of
  the same three and colliding with them at link time — it was already
  load-bearing for measurement correctness and is now load-bearing for the
  build as well.
- MP3 is the last format tried when identifying a file, not the first. dr_mp3
  recognises a file by scanning for something that parses as a frame, and
  arbitrary binary data contains such sequences often enough that, given first
  refusal, it will open a FLAC file and decode noise from it.
- `OAA_ABI_VERSION` is 4. The change is additive — `oaa_snapshot` is byte for
  byte what it was at 3 — and adds only the `oaa_file_*` decoding calls.
- File paths reach the decoder as UTF-8 and are widened to UTF-16 on Windows.
  dr_libs' plain `_init_file` calls go through `fopen`, which reads the path in
  the process's ANSI code page; an umlaut in a user name is enough to make a
  file unopenable on one platform only, with an error that says nothing about
  encoding.
- Cancelling an analysis goes through a flag in native memory rather than by
  killing the worker isolate, which would leak the engine and the open decoder
  it was holding. A message cannot reach an isolate busy in a decode loop that
  never yields to its event queue; a pointer both isolates can read can.
- The conformance suite generates its own signals rather than reading WAV
  fixtures, so it runs on a headless runner with no network and no decoder.
- Loudness is asserted to be independent of both sample rate and push block
  size — properties the standard does not state but which catch two classes of
  error that 48 kHz single-block tests cannot.
- pffft vendored under `engine/third_party/` (FFTPACK licence, permissive), and
  the maths-constant feature macro added to the build hook's POSIX defines —
  `M_PI` is XSI rather than ISO C, and asking glibc for a POSIX level hides it.
  Linux-only compile failure, the same shape as the Phase 0 `clock_gettime` one.
- One set of transforms feeds the analyser, the spectrogram and the stereo
  cloud. Three modules running their own FFT over the same audio would cost
  three times as much and could disagree about where a peak is.
- Three primitives came out of writing the modules rather than being guessed at
  in advance: a shared dB scale and graticule, a paragraph cache that re-lays
  out only when a formatted string actually changes, and a buffer of marks
  sorted by the colour they are drawn in, which is how a display made of tens
  of thousands of them stays a few dozen draw calls.
- The accumulating modules advance on the engine's publish counter rather than
  on every paint, so a resize or a theme change cannot scroll a spectrogram
  through time that no audio passed through.
- The canvas placement rules — overlap, clamping, id allocation — are pure
  functions over `TabSpec` in `oaa_core`, so they are covered by tests that need
  no window, and so the remote display cannot come to a different conclusion
  about where a module goes than the app did.
- The canvas and workspace tests build their own sparse layouts instead of
  reading geometry off the default preset. What the app opens with is a product
  decision, and a drag test that measured itself against it failed the day the
  default improved.
- Dragging a module rebuilds nothing. The module stays where it is and one
  painter draws where it would land, so pointer movement cannot stall a canvas
  of live meters.
- Module painters now extend a `MeterPainter` base and the module frame's
  chrome is painted rather than decorated. `CustomPainter.hitTest` and
  `BoxDecoration` both absorb pointer events by default, which left every
  meter's face unclickable with nothing reported anywhere.
- `.github/workflows/ci.yml` now runs `dart test packages/oaa_wire` and
  `plugin/test/sources_match.sh`. Both were named as gates in `CLAUDE.md` and
  `README.md` for a phase before either was wired in, which is the worst state
  for a gate to be in: everybody believes it is running.
- `.github/workflows/release.yml` builds the four installers and the CLI on a
  tag and on demand. On demand matters — an installer built only at release
  time is one whose script has been broken for weeks by the time anyone finds
  out.
- `.github/workflows/docs.yml` builds the documentation site on every pull
  request and publishes it from `main`.
- `tool/docs.dart` generates the site with no dependencies, so the docs job is
  a Dart SDK and no Flutter. The page list is written out rather than globbed,
  so `docs/PLAN.md` cannot be published to users by accident.
- `packaging/icon/make_icons.dart` describes the mark once as geometry and
  renders every size the installers want. Exported by hand, thirty-odd files
  across four containers drift.
- The project has a logo, in `assets/brand/`: the icon's four bars with the
  tile taken away, and the name set beside them over two lines. It is the same
  mark as the application icon rather than a second one, and the wordmark is
  Inter SemiBold converted to outlines so the file needs no font installed.
  Three files — the lockup for dark backgrounds, the lockup for light ones, and
  the mark on its own. Nothing bundles them; they are for the README, the site
  and anywhere else the project is shown.
- `make_icons.dart` draws the mark in three shapes rather than one, because the
  desktops, iOS and Android each mask it differently, and writes iOS without an
  alpha channel — an icon that has one is refused by the App Store on upload
  rather than at build time.
- The canvas's refusal toast is a provider rather than private widget state, so
  the shortcut layer above the canvas reports "no room for that" through the
  same channel a refused drop does instead of growing a second one.
- The README leads with the application icon, a badge row, a table of contents
  and the documentation site, and it now enumerates the thirteen modules and
  what each one shows — a count it stated and never listed. Presentation only:
  nothing it says about what Open Audio Analyzer measures changed.

## [0.1.0] — 2026-08-15

First release. The architecture is proven end to end and the app runs; most
meters do not exist yet. See the [roadmap](README.md#roadmap).

### 📐 Measurement

- Peak, peak max, RMS, crest factor, inter-channel correlation and stereo
  balance are measured. Peak uses a 1.5 s hold and a 20 dB/s fall; RMS is
  smoothed with a 300 ms time constant.
- **Every loudness quantity is unmeasured and reads as a dash** — LUFS-M,
  LUFS-S, LUFS-I, LRA, true peak, TP max, DR-S, DR-I, PLR and PSR. They are
  `NaN` behind `OAA_FLAG_LOUDNESS_UNAVAILABLE`, never a zero that looks like a
  reading. K-weighting, R128 gating, LRA and true-peak oversampling arrive in
  the same release as the EBU conformance vectors that prove them.
- Open Audio Analyzer does not implement Decibel's proprietary `TrueDyn` and
  will not approximate it. `DR-S` and `DR-I` are defined in
  [docs/METRICS.md](docs/METRICS.md) instead, reproducibly.
- All dB readings clamp to a −144.0 floor rather than negative infinity, so that
  differences between them stay finite.

### ✨ Added

- A C11 measurement engine with a lock-free snapshot, published by a dedicated
  analysis thread and read once per frame over FFI with no allocation.
- A built-in 1 kHz test signal, so the engine is measurable on a machine with no
  audio hardware.
- The Precision Instrument design system: one spacing scale, one border weight,
  no shadows, tabular figures on every number.
- A domain model with a 24-column grid layout, delivery-target calibrations for
  streaming, podcast, EBU R 128, ATSC A/85 and CD, and forward-compatible preset
  serialisation that skips module kinds a build does not have.
- Number Box module and the application shell.

### 🐛 Fixed

- The analysis loop no longer runs progressively slower than real time on a
  loaded machine. `nanosleep` only guarantees *at least* the delay requested, so
  every block overshoots slightly under contention; the loop discarded that
  error on each iteration instead of absorbing it, and on an oversubscribed
  host it settled at about a third of real speed. Lateness up to 250 ms is now
  made up one block at a time, and only a longer stall — a laptop waking from
  sleep, a debugger — resynchronises.

### 🚧 Internal

- Native code builds through a Dart build hook on all five platforms. There is
  no `CMakeLists.txt`, podspec or `build.gradle` for it anywhere.
- POSIX feature-test macros are declared in the build hook. Without them
  `-std=c11` hides `clock_gettime` and `nanosleep`, which built cleanly on the
  development machine and failed on both POSIX CI runners.
- CI runs analysis, formatting, and the domain, widget and engine suites, with
  the engine built on Linux, macOS and Windows.
- Licensing is split: MIT for `engine/`, `oaa_engine` and `oaa_core`;
  GPL-3.0-or-later for the application, UI, CLI and plugin.

[unreleased]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.15.0...HEAD
[0.15.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/JonasGrunau/open_audio_analyzer/compare/5f8ef44...v0.2.0
[0.1.0]: https://github.com/JonasGrunau/open_audio_analyzer/commit/5f8ef44
