# Motif motion spec — version 2

Everything Motif stores about camera movement follows these conventions. Changing any of them means
bumping `MotionSpec.version` and re-analysing every project.

## Camera frame
`x` right, `y` **down**, `z` forward (the OpenCV convention). Image coordinates are pixels measured from the
image centre, `y` down. `f` is the focal length in pixels of the analysis frame.

## Channels

| # | Channel | Positive means | Unit | Solver variable |
|---|---|---|---|---|
| 0 | pan | camera rotates right | deg / s | ωy |
| 1 | tilt | camera rotates up | deg / s | ωx |
| 2 | roll | camera rotates clockwise seen from behind (horizon turns counter-clockwise on screen) | deg / s | ωz |
| 3 | zoom | zooming in | ln(f₂ / f₁) / s | s |
| 4 | truck | camera moves right | scene-depths / s | Tx |
| 5 | pedestal | camera moves up | scene-depths / s | −Ty |
| 6 | dolly | camera moves forward (push-in) | scene-depths / s | Tz |

- **scene-depths / s**: translation divided by the median scene depth. Monocular video has no metric scale; this is
  scale-free and tracks how strong the move looks on screen. `0.10` dolly = closes 10% of the distance to the
  median scene point each second.
- Time is source presentation time. Rotated clips are uprighted before analysis.
- Trajectory sample rate: **8 Hz**. Sample `i` describes the motion between analysis frames `i` and `i+1` and is
  timestamped at their midpoint.

## Flow model
For a static scene point at image position `(x, y)` with inverse depth `1/Z`, the image motion between two frames is
(Longuet-Higgins, instantaneous form, plus a zoom term):

```
u = xy/f·ωx − (f + x²/f)·ωy + y·ωz + x·s + (−f·Tx + x·Tz)/Z
v = (f + y²/f)·ωx − xy/f·ωy − x·ωz + y·s + (−f·Ty + y·Tz)/Z
```

It is linear in the seven unknowns once `1/Z` is known up to scale. Relative inverse depth comes from a monocular
depth model and is normalised so its median is 1 — which makes the solved `T` directly "scene-depths per frame pair".
Rotation + zoom alone (first four unknowns) is solved for every pair; the translation terms are solved only when the
rotation-only fit leaves structured residual or reports scale change (the "parallax gate"), and accepted only if they
explain the flow materially better.

**Depth offset.** Monocular inverse depth is only known up to an affine map, `d = α·q + β`, and the farthest surface
usually reads as zero (β < 0). Inside one frame pair the β part of the translational flow is indistinguishable from
rotation / zoom, so a pure truck shows a little false pan, a pure push-in a little false zoom, and the translation itself
reads 1/α too small. The solver picks β in [−5, 0] to explain away as much rotation / zoom as the translation direction
allows, then rescales the translation by (1 − β). The clamp is what keeps real combinations intact: an arc (truck with
opposing pan) and a dolly-zoom (dolly with opposing zoom) would need β > 0.

**Fast pans.** The model is first-order in rotation; a large pan or tilt per pair leaves a second-order stretch equal to
a zoom of ≈ θ², which is subtracted.

**Optical-flow scale.** Vision reports displacement in the pixels of its internal network resolution (≈ 0.37× at 640 px
wide), a factor that depends on frame size but not content. It is measured once per frame size with a known synthetic shift.

Without parallax (flat or very distant scene) pan/truck and zoom/dolly are not separable from one view; the solver's
ridge prior then attributes the motion to rotation / zoom, and `translationSource` stays `none`.

## Focal length
From metadata when present (35 mm-equivalent), else a 50° horizontal field-of-view prior. A wrong `f` scales
pan/tilt rates roughly proportionally; it does not flip signs.

## Per-segment summary — Float32[8]
Channels 0–6: mean smoothed rate over the segment. Channel 7, **shake** (deg/s): the steady level of the pan/tilt/roll
rates after removing a 0.6 s moving average — the square root of the **60th percentile** of per-sample shake energy,
ignoring the first and last 0.5 s of the clip. For continuous shake that equals the RMS; a single knock (record button,
bumped tripod) affecting under ~40% of the segment doesn't register. *(Version 1 used a plain RMS, which let a knock at
the end turn a locked-off shot into `handheld`.)* Projects tagged under an older version re-measure on open; descriptions are kept.

## Stability class
`locked_off` (shake < 0.15), `stabilised` (< 0.6), `handheld` (≥ 0.6). Thresholds in `MotionSpec`.

## Chips
Deterministic, from the summary: a channel produces a chip when its mean rate exceeds the channel threshold **and** the
move sweeps at least `MotionSpec.minSweep` in total within the segment (3° of pan or tilt, 2.5° of roll, 5% of zoom,
0.03 scene-depths) — less than that is wobble or a reframe; speed is
`slow / medium / fast` by per-channel bands. Compound names: `arc` (truck + opposing pan), `dolly zoom`
(dolly + opposing zoom), `crane` (pedestal + tilt). Subject-relative terms (tracking, following, reveal…) are never
derived here; they come from the description model.
