// Records the engine measuring a real track, for the site's demos to replay.
//
// SPDX-License-Identifier: GPL-3.0-or-later
//
//     npm run record
//     npm run record -- --start 92 --seconds 45
//
// ---------------------------------------------------------------------------
// What this produces, and where each piece goes
//
//   tools/analyzer-demo/web/programme.oaaz      what the engine measured
//   tools/analyzer-demo/web/programme.m4a       the same seconds, to listen to
//   tools/module-renderer/web/programme.oaa     the full recording
//   tools/module-renderer/web/programme.wav     the same seconds, to read
//
// Into each target's `web/` directory, because that is what `flutter build web`
// copies into the build — so the demo's two files travel with it into
// public/analyzer/ and there is no second place to remember to copy them to.
//
// The demo's recording leaves out the per-band stereo position: the stereo
// cloud is the only module that draws it and it is not on that canvas, so
// sending a browser 512 bytes a frame of something nothing looks at would be
// waste. The renderer's does carry it, and never leaves this machine.
//
// The renderer gets a WAV rather than the m4a for the same reason it gets the
// full recording: it is reading exact samples off a local disk, and the
// oscilloscope and the phase scope draw the waveform itself.
//
// ---------------------------------------------------------------------------
// The track
//
// Two tracks from *Citizens of the Empire* by Citizens Of The Empire, CC BY
// 3.0, fetched by `tool/fetch_test_audio.dart` in the repository root. **CC BY
// requires credit wherever this is published**, which is why the site carries
// it under the canvas and why this script refuses to run without the
// attribution file the fetch tool writes.
//
// It is the same audio the application is looked at with during development,
// which is the point: what the website shows is what somebody sees when they
// run this on real material, not a demo reel assembled to flatter it. That
// includes the parts that do not flatter it — the track masters at about
// -8 LUFS, so the delivery verdict against a -14 streaming target fails on
// loudness and on true peak, and the website shows that failing.
//
// ---------------------------------------------------------------------------
// Why AAC rather than the FLAC
//
// The measurements come from the FLAC and are already made by the time this
// encodes anything; the m4a is only what a reader hears. 35 MB of lossless to
// listen to a 45-second loop in a browser would be a strange thing to send.
//
// Two encoders, in preference order: `afconvert`, which ships with macOS and
// whose AAC is the better of the two at this bitrate, then `ffmpeg`. The
// fallback exists because the first version had only afconvert, and one macOS
// binary in the middle of this script put the entire recording path out of
// reach of anybody working on Linux — including this repository's own CI, which
// is why the demo's two files are committed.

import { execFileSync } from 'node:child_process';
import { createReadStream, createWriteStream, existsSync, mkdirSync, rmSync, statSync } from 'node:fs';
import { createGzip } from 'node:zlib';
import { pipeline } from 'node:stream/promises';
import { join, resolve } from 'node:path';

const ROOT = resolve(import.meta.dirname, '..');
const REPO = resolve(ROOT, '..');
const TRACK = join(REPO, 'test_audio/citizens-apathy.flac');
const ATTRIBUTION = join(REPO, 'test_audio/ATTRIBUTION.md');
const RECORDER = join(ROOT, 'tools/oaa_record');

/// Both are a Flutter target's `web/` directory, which is copied verbatim into
/// its build. The demo's two files are committed, because CI deploys the site
/// and cannot make them; the renderer's ten-odd MB are git-ignored and never
/// leave this machine.
const DEMO_OUT = join(ROOT, 'tools/analyzer-demo/web');
const RENDERER_OUT = join(ROOT, 'tools/module-renderer/web');

const argv = process.argv.slice(2);
const option = (name, fallback) => {
  const at = argv.indexOf(`--${name}`);
  if (at >= 0 && at + 1 < argv.length) return argv[at + 1];
  const inline = argv.find((a) => a.startsWith(`--${name}=`));
  return inline ? inline.slice(name.length + 3) : fallback;
};

/// Where in the track to start, and how much to take.
///
/// Chosen by measuring, not by listening for a good bit. `oaa --format csv`
/// prints short-term loudness across the whole track, and this window is the
/// one that moves most: it opens at about -13.5 LUFS-S and climbs to -6 over
/// forty-five seconds, which is a crescendo rather than a section.
///
/// That matters because a metering demo is only as interesting as its
/// programme. Four candidate windows, measured the same way:
///
///     62 s    LUFS-I -8.0   LRA 7.2      <- this one
///     92 s    LUFS-I -6.1   LRA 1.0      the loud plateau: every meter pinned
///    190 s    LUFS-I -11.6  LRA 5.5
///    240 s    LUFS-I -8.0   LRA 4.2
///
/// The plateau at 92 s was the first choice and it was wrong: an LRA of 1.0
/// draws a flat histogram, a loudness distribution that is one spike, and a
/// loudness range readout that says the programme never moved.
const START = Number(option('start', '62'));

/// Forty-five seconds, which is most of the histogram's one-minute axis: a
/// trace that stops a third of the way across reads as a demo caught mid-load
/// rather than as a measurement. It is also the loop, so it has to be long
/// enough not to be obviously one.
const SECONDS = Number(option('seconds', '45'));

/// Recording frames per second of programme.
///
/// The engine publishes at about 47 Hz. Twenty is a little under half of that
/// and it is what the file size is: the two spectrum arrays are 1 kB a frame
/// before compression, so this is the number that decides whether the demo
/// costs 400 kB or a megabyte. Above about 15 the meters read as continuous —
/// the ballistics the eye is watching are slower than the publish rate.
const FPS = Number(option('fps', '20'));

/// AAC, at a rate that does not embarrass a page about audio measurement.
const BITRATE = Number(option('bitrate', '128000'));

// --- Checks -----------------------------------------------------------------

if (!existsSync(TRACK)) {
  console.error(
    `Missing ${TRACK}\n\n` +
      `  The track is not in the repository — it is 35 MB of somebody else's\n` +
      `  music. Fetch it from the repository root:\n\n` +
      `      dart run tool/fetch_test_audio.dart\n`,
  );
  process.exit(1);
}

if (!existsSync(ATTRIBUTION)) {
  console.error(
    `Missing ${ATTRIBUTION}\n\n` +
      `  This audio is CC BY 3.0 and the licence requires credit wherever it\n` +
      `  is published. The attribution file is written by the fetch tool and\n` +
      `  is what the site's credit is copied from; publishing without it is\n` +
      `  the one failure this check exists to prevent.\n`,
  );
  process.exit(1);
}

// --- Record -----------------------------------------------------------------

mkdirSync(DEMO_OUT, { recursive: true });
mkdirSync(RENDERER_OUT, { recursive: true });

const wav = join(RENDERER_OUT, 'programme.wav');
const webRecording = join(DEMO_OUT, 'programme.oaa');
const fullRecording = join(RENDERER_OUT, 'programme.oaa');

const common = [
  '--in', TRACK,
  '--start', String(START),
  '--seconds', String(SECONDS),
  '--fps', String(FPS),
];

const record = (args) =>
  execFileSync('dart', ['run', 'bin/record.dart', ...common, ...args], {
    cwd: RECORDER,
    stdio: ['ignore', 'inherit', 'inherit'],
  });

console.log(`Recording ${SECONDS}s from ${START}s, at ${FPS} fps…`);
record(['--out', webRecording, '--web']);
// The full one for the fourteen thumbnails, and the audio beside it: the
// oscilloscope and the phase scope draw the waveform, which is not in the
// recording — it is the audio, and both places that need it have the audio.
// Writing it from the same run is what makes it the same seconds.
record(['--out', fullRecording, '--wav', wav]);

// --- Compress ---------------------------------------------------------------

// Gzipped here rather than left to the host: a static host will not reliably
// compress an application/octet-stream, and 1.2 MB arriving uncompressed
// because of a MIME type is not a failure anybody would notice.
//
// **The extension is `.oaaz`, not `.gz`, and that matters.** A server that sees
// `.gz` is entitled to serve it with `Content-Encoding: gzip` — and then the
// browser unpacks it on the way in, the demo unpacks it again, and the fetch
// fails with a type error that says nothing about the cause. Astro's own
// preview server does exactly that. The demo checks the magic number rather
// than trusting either the extension or the header, so it survives a host that
// does it anyway; this just stops most of them from trying.
//
// The renderer's copy is left plain — it is read off a local disk.
const packed = webRecording.replace(/\.oaa$/, '.oaaz');
await pipeline(
  createReadStream(webRecording),
  createGzip({ level: 9 }),
  createWriteStream(packed),
);
const gzipped = statSync(packed).size;
rmSync(webRecording);

// --- Encode -----------------------------------------------------------------

// The encoder reads a file, so the excerpt written for the renderer is also
// what it is pointed at. One decode, one set of samples, two outputs.
const m4a = join(DEMO_OUT, 'programme.m4a');
const encoder = encodeAac(wav, m4a);

/// AAC in an MP4 container, through whichever encoder the machine has.
///
/// Preference, not equivalence: Apple's AAC is the better encoder at 128 kbit/s
/// and the committed excerpt was made with it, so `afconvert` is tried first
/// wherever it exists. ffmpeg is what makes this script runnable anywhere else.
///
/// A missing binary is `ENOENT` and means "try the next one"; anything else is
/// an encoder that ran and failed, which is a real error and is reported as
/// one — swallowing it would leave a truncated m4a behind and say nothing.
function encodeAac(from, to) {
  const encoders = [
    {
      bin: 'afconvert',
      args: ['-f', 'm4af', '-d', 'aac', '-b', String(BITRATE), '-q', '127', '-s', '3', from, to],
    },
    {
      // `-movflags +faststart` moves the index to the front of the file, which
      // is what lets a browser start playing before the whole of it has
      // arrived. afconvert writes m4af that way already.
      bin: 'ffmpeg',
      args: ['-hide_banner', '-loglevel', 'error', '-y', '-i', from,
        '-c:a', 'aac', '-b:a', String(BITRATE), '-movflags', '+faststart', to],
    },
  ];

  const absent = [];
  for (const { bin, args } of encoders) {
    try {
      execFileSync(bin, args, { stdio: ['ignore', 'pipe', 'pipe'] });
      return bin;
    } catch (error) {
      if (error.code === 'ENOENT') {
        absent.push(bin);
        continue;
      }
      console.error(`${bin} failed to encode ${from}.`);
      console.error(error.stderr?.toString() ?? '');
      process.exit(1);
    }
  }

  console.error(
    `No AAC encoder: looked for ${absent.join(' and ')}. afconvert ships with\n` +
      `macOS; everywhere else, install ffmpeg — or encode ${from} to AAC in an\n` +
      `MP4 container by hand and save it as ${to}.`,
  );
  process.exit(1);
}


// --- Say what happened ------------------------------------------------------

const kb = (path) => `${(statSync(path).size / 1024).toFixed(0)} kB`;
console.log('');
const show = (path) => path.replace(`${ROOT}/`, '');
console.log(`  ${show(packed)}`.padEnd(46) + `${(gzipped / 1024).toFixed(0).padStart(5)} kB   fetched on play`);
console.log(`  ${show(m4a)}`.padEnd(46) + `${kb(m4a).padStart(8)}   fetched on play, ${encoder}`);
console.log(`  ${show(fullRecording)}`.padEnd(46) + `${kb(fullRecording).padStart(8)}   local, for the thumbnails`);
console.log(`  ${show(wav)}`.padEnd(46) + `${kb(wav).padStart(8)}   local, for the scope`);
