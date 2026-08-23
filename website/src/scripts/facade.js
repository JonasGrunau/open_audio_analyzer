/* The still in front of the live analyzer, and the swap to the real thing.
 *
 * The front page is 60-odd kB and a photograph. The application compiled for the
 * web is a couple of megabytes plus a renderer fetched from Google's CDN, which
 * is a fair price for the thing itself and not one to charge somebody reading a
 * paragraph — so it is not referenced at all until a reader asks for it.
 *
 * Why an iframe rather than mounting Flutter into this page: it installs
 * document-level keyboard, scroll and focus handling that fights an ordinary
 * document, and its own route can be given the COOP/COEP headers the threaded
 * renderer wants without imposing them on the whole site.
 */

const facade = document.querySelector('[data-facade]');
const go = facade?.querySelector('[data-facade-go]');

if (facade && go) {
  const mark = go.querySelector('[data-facade-mark]');
  const text = go.querySelector('[data-facade-text]');
  const label = go.querySelector('[data-facade-label]');
  const status = facade.querySelector('[data-facade-status]');
  const still = window.matchMedia('(prefers-reduced-motion: reduce)');

  /* Warm it on intent, not on sight.
   *
   * Prefetching when the section merely scrolls into view would spend two
   * megabytes on every reader who passes it, which is the cost this control
   * exists to avoid. A hover, a focus or a finger landing is a different signal:
   * by the time the press completes, the fetch is usually already under way.
   */
  let warmed = false;
  const warm = () => {
    if (warmed) return;
    warmed = true;
    for (const href of ['/analyzer/flutter_bootstrap.js', '/analyzer/main.dart.js']) {
      const link = document.createElement('link');
      link.rel = 'prefetch';
      link.href = href;
      document.head.append(link);
    }
  };

  go.addEventListener('pointerenter', warm, { once: true });
  go.addEventListener('focus', warm, { once: true });
  go.addEventListener('touchstart', warm, { once: true, passive: true });

  /* How far this half of the control is from the middle of it.
   *
   * The two keyframe sets in index.astro read the answer off the element as
   * `--dx` / `--dy`: the mark travels to the middle of the picture and the
   * label travels the other way, into the disc the mark has become.
   *
   * Measured from `offsetLeft` and not from `getBoundingClientRect`, because a
   * bounding box is the box *after* the transform. Once the animation is
   * running and holding its final frame, a rect would report the element where
   * it has arrived, so re-measuring it on a resize would aim the next travel
   * from there and send it off the picture. `offsetLeft` is layout, which the
   * transform does not touch. The button is the offset parent — it is the only
   * positioned ancestor — and it has no border, so its client box and its
   * children's offsets are in the same coordinates.
   */
  const aim = (el) => {
    if (!el) return;
    el.style.setProperty('--dx', `${go.clientWidth / 2 - (el.offsetLeft + el.offsetWidth / 2)}px`);
    el.style.setProperty('--dy', `${go.clientHeight / 2 - (el.offsetTop + el.offsetHeight / 2)}px`);
  };
  const reaim = () => {
    aim(mark);
    aim(text);
  };

  go.addEventListener('click', () => {
    const frame = document.createElement('iframe');
    /* The file, not the directory.
     *
     * This site is `trailingSlash: 'never'`, which follows from
     * `build.format: 'file'` — so `/analyzer/` is a 404 with a helpful message
     * about trailing slashes, and `/analyzer` is not a page Astro knows either.
     * Naming index.html sidesteps the question on the dev server, in `preview`
     * and on Workers alike; the build carries `--base-href /analyzer/`, so its
     * own assets still resolve from the right place. */
    frame.src = '/analyzer/index.html';
    /* Named, because a frame with no accessible name is announced as "frame". */
    frame.title = 'Open Audio Analyzer, replaying the engine measuring a real track';
    frame.loading = 'eager';
    /* Enough to run, and nothing else: no top navigation, no downloads, no
     * form submission. Same-origin so it can load its own assets. */
    frame.setAttribute('sandbox', 'allow-scripts allow-same-origin');

    /* Sized here rather than in the stylesheet.
     *
     * Astro scopes a component's CSS by adding an attribute to the elements it
     * compiled, and this element is created at runtime — so a `.facade iframe`
     * rule silently does not apply to it. Left at an iframe's default 300x150,
     * Flutter laid the canvas out at 300x150 and every module on it correctly
     * reported itself too small to draw, which is a very convincing bug.
     */
    frame.style.width = '100%';
    frame.style.height = '100%';
    frame.style.border = '0';
    frame.style.display = 'block';

    /* The still stays underneath until the frame has something to show, so the
     * press does not turn the panel blank while two megabytes arrive. */
    frame.style.position = 'absolute';
    frame.style.inset = '0';
    frame.style.opacity = '0';
    frame.style.transition = 'opacity 320ms ease';

    go.disabled = true;
    go.setAttribute('aria-busy', 'true');
    if (status) status.textContent = 'Loading the analyzer…';

    /* Somebody who has asked the system for less motion is asking for this in
     * particular: a label sliding across a photograph and a ring rotating for
     * as long as two megabytes take. They get the old control instead, saying
     * in words what the spinner would have said. The site's stylesheet flattens
     * every animation to nothing anyway — this is what keeps that from leaving
     * a control that says "Open the live analyzer" while it opens one. */
    if (still.matches) {
      if (label) label.textContent = 'Loading the analyzer…';
    } else {
      reaim();
      go.classList.add('is-loading');
      /* A rotated tablet mid-load is a plausible three seconds. The travel is
       * measured in pixels, so it has to be re-measured when the picture
       * changes width; the animation holds its last frame and picks up the new
       * distance on the spot. */
      window.addEventListener('resize', reaim, { passive: true });
    }

    facade.append(frame);

    /* Reveal on the first *painted* frame, not on `load`.
     *
     * `load` fires when the document is parsed, which is seconds before
     * CanvasKit has been fetched and anything drawn — fading there replaced a
     * photograph of the meters with an empty panel, and the blank document
     * underneath flashed white on the way. The demo sets `oaaFirstFrame` from a
     * post-frame callback; it is same-origin, so we can simply ask it.
     */
    const pressed = Date.now();
    /* Long enough for the converge to land and the spinner to turn once. A
     * warm cache can paint the first frame before the label has finished
     * leaving, and cutting the animation off halfway looks like a fault rather
     * than like speed. */
    const settled = still.matches ? 0 : 1000;

    let revealed = false;
    const reveal = () => {
      if (revealed) return;
      const early = pressed + settled - Date.now();
      if (early > 0) {
        setTimeout(reveal, early);
        return;
      }
      revealed = true;
      window.removeEventListener('resize', reaim);
      frame.style.opacity = '1';
      /* The button goes only once the frame is up: it covers the canvas while
       * that happens, and removing it earlier would let a press through to
       * something not ready for it. The spinner fades with it, in the same
       * 320 ms the frame takes to arrive. */
      go.classList.add('is-done');
      go.removeAttribute('aria-busy');
      if (status) status.textContent = 'The analyzer is running.';
      setTimeout(() => go.remove(), 320);
    };

    const deadline = Date.now() + 30_000;
    const poll = () => {
      let painted = false;
      try {
        painted = frame.contentWindow?.oaaFirstFrame === true;
      } catch {
        /* Should not happen at same origin, but a cross-origin frame must not
         * leave the reader looking at a disabled button for ever. */
        painted = true;
      }
      if (painted || Date.now() > deadline) reveal();
      else setTimeout(poll, 100);
    };
    frame.addEventListener('load', poll, { once: true });
  });
}
