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

/* On a phone the control is `display: none` — the stylesheet's decision, and the
 * comment on that media query says why. Nothing here tests for it: a hidden
 * element cannot be hovered, focused, touched or clicked, so every listener
 * below is simply never reached, and a phone turned on its side wide enough to
 * be given the control back gets one that already works. A guard here would be
 * a second breakpoint to keep in step with the first, and a dead button after a
 * rotation. */
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

  /* Where each half of the control goes when it is pressed, and where the label
   * stops being visible.
   *
   * The mark travels to the middle of the picture. The label travels the other
   * way and passes *behind* the disc the mark has become — which is a longer
   * trip than it sounds, and used to be the whole trouble with this animation:
   * aimed at the middle like the mark, the label moved (mark + gap) / 2, about
   * thirty pixels, and a label five times the width of the disc that has moved
   * thirty pixels is still lying across the picture. It could only get out of
   * sight by shrinking and fading where it stood, which reads as a label that
   * dissolved rather than one that went somewhere. So it is aimed at the disc
   * instead: far enough that its trailing edge ends up inside the circle.
   *
   * What hides it on the way is a clip, not opacity. The label is cut off at
   * the disc's leading edge, so the eye sees it slide into the spinner and
   * disappear under it. That edge belongs to an element that is moving too, so
   * the cut has to move with it — which is why the clip is written into the
   * same keyframes as the travel rather than into a transition of its own: both
   * animations run the same three stops with the same curves, so the distance
   * between them is `--s*` scaled by whatever progress the curve is at, and the
   * cut sits exactly on the disc at every frame of it.
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
  const reaim = () => {
    if (!mark || !text) return;

    const cx = go.clientWidth / 2;
    const cy = go.clientHeight / 2;
    const r = Math.min(mark.offsetWidth, mark.offsetHeight) / 2;

    /* The mark: to the middle, along whichever axis it is off it. */
    const mdx = cx - (mark.offsetLeft + mark.offsetWidth / 2);
    const mdy = cy - (mark.offsetTop + mark.offsetHeight / 2);
    mark.style.setProperty('--dx', `${mdx}px`);
    mark.style.setProperty('--dy', `${mdy}px`);

    /* How far back from the disc's leading point its outline has already curved
     * in by the time it reaches the corner of the label. A cut at the leading
     * point itself is a straight line tangent to a circle: it would take the
     * label's top and bottom rows out nine pixels before the circle is anywhere
     * near them, and letters vanishing beside a disc rather than under it is the
     * same lie as fading, told more quietly. */
    const lip = (across) => r - Math.sqrt(Math.max(0, r * r - Math.min(r, across / 2) ** 2));

    /* Beside the mark above 560 px and under it below, so the travel and the cut
     * swap axes. Read off the layout rather than off a media query, because the
     * layout is what the measurements have to agree with. */
    const beside = text.offsetLeft >= mark.offsetLeft + mark.offsetWidth;

    /* `--c*` is where the cut starts, in the label's own box — negative while
     * the disc is still short of the label, which is what the `max(0px, …)` in
     * the keyframes is for. `--s*` is how far it sweeps: the gap the two halves
     * close between them, which by the end is the whole label. */
    let dx = 0;
    let dy = 0;
    let ct = 0;
    let cl = 0;
    let st = 0;
    let sl = 0;
    let sr = 0;

    if (beside) {
      const l = lip(text.offsetHeight);
      dx = cx + r - l - (text.offsetLeft + text.offsetWidth);
      cl = mark.offsetLeft + mark.offsetWidth - l - text.offsetLeft;
      sl = mdx - dx;
    } else {
      const l = lip(text.offsetWidth);
      dy = cy + r - l - (text.offsetTop + text.offsetHeight);
      ct = mark.offsetTop + mark.offsetHeight - l - text.offsetTop;
      st = mdy - dy;
      /* The one thing a disc cannot do to a label wider than itself is hide it.
       * Stacked, the label arrives at a circle a fifth of its width, so it is
       * drawn in from both ends as it rises and is down to the disc's own width
       * by the time it gets there. */
      sr = Math.max(0, (text.offsetWidth - mark.offsetWidth) / 2);
      sl = sr;
    }

    text.style.setProperty('--dx', `${dx}px`);
    text.style.setProperty('--dy', `${dy}px`);
    text.style.setProperty('--ct', `${ct}px`);
    text.style.setProperty('--cl', `${cl}px`);
    text.style.setProperty('--st', `${st}px`);
    text.style.setProperty('--sl', `${sl}px`);
    text.style.setProperty('--sr', `${sr}px`);
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
     * a control that says "Load the live analyzer" while it loads one. */
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
