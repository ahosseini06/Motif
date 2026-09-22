# Motif — build plan

A lightweight native Mac app that catalogs a folder of footage and tags every clip with a
**description** and its **camera movement** (natural language + a numeric motion trajectory).

Status: **v0 built 2026-09-20** — see [README.md](README.md) for what exists, what was measured, and what is still
untested. This file is the design record; where the build deviated, README's "Deviations from the plan" says how.
Numbers marked *(est.)* were estimates at planning time; measured values are in the README.
Claude Code builds this. §8 is a dependency-ordered build sequence, not a calendar.
"v1" anywhere below means **v0** — the first build, which is the whole product described in §1.

---

## 1. Scope

### v0 does
- Create / open projects. A project points at one folder of video (scanned recursively).
- Tag every clip, on-device first, then one cheap API call:
  - `description` — what is in the shot.
  - `camera movement` — a sentence, a set of primitive chips (`pan right · slow`, `push-in`, `handheld`),
    and a numeric motion trajectory per segment.
- Show clips in a grid with tags under each clip; hover to play; click to select, with a detail
  inspector on the right and a full player.
- Resume after quit, survive unplugged drives, never re-process an unchanged file.

### v0 does not (but must not block)
- Search of any kind — text, semantic, or "find similar movement". The data for all three is stored in v0
  (description text, 1 fps proxy for embeddings, motion time series) so none needs reprocessing later.
- 3D keyframed movement queries, option-chip queries (§4.5 defines how they will work).
- NLE integration (FCPXML / Resolve / Premiere export), BRAW / R3D, gyro metadata, team sharing.
- Offline tagger, Batch-API lane, folder watching, notarised distribution + auto-update: all in §8 "after v0".
  v0 has the per-project "never upload" switch, which simply skips the description stage.
- v0 runs on Ali's machine, built from source. Cost without the batch lane is still ≈ $1.30 per 1,000 clips *(est.)*.

### Principles
1. **Measure camera motion, don't ask a VLM for it.** VLMs score ~60–68% on camera movement vs 93% human.
   Geometry runs locally and is handed to the VLM as a hint.
2. **One decode pass per clip** feeds everything (motion, proxy, sprite, poster).
3. **Originals are read-only and never uploaded.** Only a 360p ~1 fps silent proxy can leave the machine.
4. **Every shipped model has a commercial-use licence.** (§11)
5. **Fix the motion conventions before tagging anything** (§4) — changing them means reprocessing every project.

---

## 2. Architecture

```
 folder ──► Scanner ──► Fingerprint ──► Job queue (SQLite, resumable, priority = visible first)
                                             │
                     ┌───────────────────────┴───────────────────────┐
                     ▼                                               │
            ① Decode pass (AVAssetReader, HW decode + downscale)     │
               ├─ 8 fps 512px luma frames ──► ② Global motion        │
               ├─ sprite filmstrip + poster ──► cache                │
               └─ 360p ~1 fps silent proxy  ──► cache                │
                     ▼                                               │
            ② Global motion (Vision flow/homography + RANSAC)        │
                     ▼                                               │
            ③ Parallax stage — only if gated in (depth model)        │
                     ▼                                               │
            ④ Segmentation + primitive chips + summary vector        │
                     ▼                                               │
            ⑤ Describe: Gemini Flash-Lite (proxy + motion hint) ◄────┘  live lane / batch lane
                     ▼
                 catalog.sqlite  ──►  SwiftUI grid + inspector
```

Stages ①–④ are on-device and free. ⑤ is the only network call (≈ $0.15 per hour of footage, batch).

### Code layout

**Build system.** This machine has only the Command Line Tools — no Xcode (checked 2026-09-20; Swift 6.3.3 is
present). v0 is therefore pure SwiftPM: `swift build` + a `Scripts/bundle.sh` that assembles `Motif.app`
(Info.plist, icon, ad-hoc codesign). Core ML models are compiled at runtime with `MLModel.compileModel(at:)`, so
`coremlcompiler` isn't needed. Xcode becomes necessary only after v0: MLX's metallib (offline tagger), Developer ID
signing + notarisation, Instruments. Step 1 verifies SwiftUI macros (`@Observable`) and the test runner work under
CLT alone; if either doesn't, installing Xcode becomes a v0 prerequisite.

```
Package.swift                   one SwiftPM package, Swift 6 strict concurrency
Scripts/bundle.sh               swift build -c release → Motif.app
  Sources/
    MotifCore/      models, GRDB schema + migrations, project package I/O, settings, keychain
    MotifIngest/    scanner, fingerprint, decode pass, colour normalisation, proxy/sprite writers
    MotifMotion/    flow/homography, decomposition, parallax stage, segmentation, chips, similarity (later)
    MotifTagger/    Gemini client (live + batch), prompt + schema, local VLM (after v0)
    MotifPipeline/  job queue, scheduler, concurrency + thermal policy
    motif-cli/      executable: run any stage on a folder, print vectors, benchmark, eval
    MotifApp/       executable: SwiftUI views, AppKit grid, player pool, design tokens
  Tests/
Eval/               synthetic scene generator, review-set labels (JSON), eval reports
docs/motion-spec.md the conventions in §4, versioned
```

`motif-cli` exists from day one and stays: it is the prototype, the benchmark, and the regression harness.

### Stack decisions

| Concern | Choice | Why |
|---|---|---|
| UI | SwiftUI shell + `NSCollectionView` grid | SwiftUI lazy grids stutter at thousands of video cells; AppKit grid is proven |
| Min OS | macOS 26, Apple Silicon only | new Swift Vision API; media engine; no Intel baggage |
| DB | SQLite via GRDB, WAL | predictable bulk upserts from background actors; FTS5 ready for search |
| Vectors | `BLOB` of Float32 + Accelerate brute force | <10 ms at 100k vectors *(est.)*; no sqlite-vec build pain |
| Decode | `AVAssetReader` + VideoToolbox scaling | HW decode for H.264 / HEVC 4:2:2 10-bit / ProRes / ProRes RAW |
| Motion | Apple Vision + own RANSAC | free, fast, no model to ship |
| Depth | Depth Anything V2 Small (official Core ML package) + residual-flow regression; DA3 Small only if needed (§5.4) | Apache-2.0, no conversion work |
| Describe | Gemini Flash-Lite, native video | cheapest credible video VLM; 70 tok/frame |
| Offline describe (after v0) | Qwen3-VL-4B 4-bit via `mlx-swift-lm` | Apache-2.0, Swift-native; needs Xcode |
| Build | SwiftPM + bundle script (v0); Developer ID + notarisation + Sparkle after v0 | no Xcode on this machine yet |

---

## 3. Project format & data model

A project is a package directory, `MyFilm.motif/`:

```
MyFilm.motif/
  catalog.sqlite
  cache/posters/<clipID>.heic
  cache/sprites/<clipID>.heic        filmstrip, ~48 tiles @ 240px, ~150–400 KB
  cache/proxies/<clipID>.mp4         360p ~1 fps, no audio — what gets uploaded, and later embedded
```

Portable, deletable, and the grid still works with the source drive unplugged. The source folder is held as a
security-scoped bookmark, re-resolved per volume.

### Schema (v1)

```sql
project   (id, name, created_at, source_bookmark BLOB, never_upload INT, motion_spec_version INT)

clip      (id, rel_path, fingerprint, size, mtime,
           duration_s, fps, width, height, codec, colour_tf, rotation, has_audio,
           captured_at, camera_make, camera_model, focal_mm,        -- when metadata has them
           status, error, online INT)

segment   (id, clip_id, idx, t_start, t_end,
           summary BLOB,          -- Float32[8]  pan,tilt,roll,zoom,truck,pedestal,dolly,shake
           trajectory BLOB,       -- Float32[T×7] @ 8 Hz, spec units
           confidence BLOB,       -- Float32[T]  inlier ratio
           translation_source,    -- none | parallax | pose
           stability,             -- locked_off | stabilised | handheld
           chips TEXT)            -- JSON: [{"p":"pan","dir":"right","speed":"slow"}, …]

tag       (clip_id, description, movement_text, shot_size, subject_relation,
           model, prompt_version, tokens_in, tokens_out, created_at)

job       (id, clip_id, stage, state, priority, attempts, batch_id, updated_at)

embedding (clip_id, model, vector BLOB)     -- empty in v1, reserved
```

`fingerprint` = size + mtime + SHA-256 of first and last 1 MB. Full-file hashing is too slow on camera cards.
Renamed / moved files re-attach by fingerprint instead of re-processing.
`prompt_version` and `motion_spec_version` make selective re-tagging possible.

---

## 4. Motion spec (write this first — `docs/motion-spec.md`)

### 4.1 Channels, signs, units

| # | Channel | Positive means | Unit |
|---|---|---|---|
| 0 | pan | camera rotates right | deg / s |
| 1 | tilt | camera rotates up | deg / s |
| 2 | roll | camera rotates clockwise (horizon turns counter-clockwise on screen) | deg / s |
| 3 | zoom | zooming in | ln(f₂ / f₁) / s |
| 4 | truck | camera moves right | scene-depths / s |
| 5 | pedestal | camera moves up | scene-depths / s |
| 6 | dolly | camera moves forward (push-in) | scene-depths / s |

- "scene-depths / s": translation divided by the median scene depth. Monocular video has no metric scale;
  this normalisation is scale-free and tracks how strong the move *looks*.
- Time is **source presentation time** (so 120 fps slow-motion footage reports motion as shot; the playback-rate
  factor is stored on the clip and applied at query time if needed).
- Trajectory sample rate: 8 Hz, fixed. Rotated clips (`preferredTransform`) are uprighted before analysis.

### 4.2 Summary vector — Float32[8]
Channels 0–6 = duration-weighted mean rate over the segment; channel 7 = **shake** = RMS of the >2 Hz
high-passed pan/tilt/roll rates (deg/s). Magnitude and direction are kept together here and separated at query time.

### 4.3 Stability class
From the rotation-rate spectrum: `locked_off` (≈ no energy), `stabilised` (low-frequency drift only — gimbal, slider,
drone), `handheld` (2–8 Hz energy). Thresholds tuned on the review set.

### 4.4 Primitive chips (deterministic, from the vector — not from the VLM)
`static`, `pan L/R`, `tilt U/D`, `roll CW/CCW`, `zoom in/out`, `push-in / pull-out`, `truck L/R`,
`pedestal U/D`, plus speed (`slow / medium / fast`, per-channel thresholds) and the stability class.
Compound names are rules over chips: `arc` = truck + opposing pan; `dolly-zoom` = dolly + opposing zoom;
`crane` = pedestal + tilt.
Subject-relative words — `tracking`, `following`, `reveal`, `orbit around subject` — come from the VLM (§6),
because they depend on the subject, not only on the camera.

### 4.5 Similarity (not built in v1 — designed now so the data supports it)
- **Chip query** ("pan-up" + "push-in"): sum unit template vectors → cosine similarity against normalised summaries.
  Signs are preserved. Speed is a separate optional filter on magnitude.
- **Keyframed 3D path query**: convert the virtual camera path to the same 7 channels (normalise translation by the
  virtual scene depth), resample both sides to 16 steps, compare with DTW over per-channel-standardised values.
- **Known ambiguity**: pan vs truck in distant, low-parallax scenes. Accepted: they also look alike on screen.
- The synthetic scene renderer built for evaluation (§9) is the same code that converts a keyframed path to channels.

---

## 5. On-device pipeline

### 5.1 Scan & fingerprint
Enumerate the folder, keep anything `AVURLAsset` can open with a video track. Unsupported (BRAW, R3D, corrupt) get a
visible "unsupported" tile, not silence. Read duration, fps, dimensions, codec, transfer function, rotation, capture
date, camera make/model, focal length where present. FSEvents watches the folder for additions while the project is open.

### 5.2 Decode pass
- `AVAssetReader` + `AVAssetReaderTrackOutput`, requesting 8-bit 4:2:0 biplanar at reduced size so VideoToolbox does the
  scaling and 10→8-bit conversion. `VTRegisterProfessionalVideoWorkflowVideoDecoders()` at launch for ProRes RAW.
- From one pass: **8 fps @ 512 px** luma for motion; **sprite** tiles (48 evenly spaced @ 240 px); **poster** (frame at
  10% — avoids slates/black); **proxy** via `AVAssetWriter`, H.264 360p, no audio.
- Proxy frame rate is adaptive: `fps = clamp(24 / duration, 0.25, 4)`, so every clip sends ~16–48 frames. A 5 s clip
  isn't starved, a 10 min clip isn't expensive. Hard cap 64 frames.
- **Colour**: HLG/PQ → tone-map to Rec.709. Log footage (S-Log3, LogC, Apple Log, V-Log…) is usually unflagged:
  detect from camera metadata where present, else a low-contrast/lifted-blacks heuristic; apply the matching curve, or a
  generic contrast normalisation if unknown. Applies to proxy, sprite and poster. Motion analysis runs on a
  contrast-stretched luma either way.
- Edge cases to handle explicitly: VFR (iPhone), anamorphic pixel aspect, interlaced, <1 s clips (single segment, no
  segmentation), >10 min clips (motion analysed in windows), audio-only files, mid-file decode errors (keep what we got).
- Concurrency: 2–3 concurrent decodes *(est.; one ProRes engine on Pro chips — measure in Step 1)*.

### 5.3 Global motion
Two candidates, chosen by measurement in Step 1:

- **A — `TrackHomographicImageRegistrationRequest`** (Vision): one 3×3 warp per frame pair. Simplest.
  Risk: no control over outlier handling when a moving subject fills the frame.
- **B — Vision optical flow (`TrackOpticalFlowRequest`) sampled on a grid + own weighted RANSAC**, with person /
  saliency masks down-weighting foreground. More code, robust to big subjects, and gives the residual flow field
  needed for the parallax stage for free.

Likely outcome: B, with A as a fast path when the two agree.

**Decomposition.** Fit a 4-DOF similarity (tx, ty, rotation, scale) robustly, then a full homography.
With focal length `f` in pixels — from metadata when present, else a 50° horizontal-FOV prior, refined by the depth
stage when it runs: `pan = atan(tx / f)`, `tilt = atan(ty / f)`, `roll = rotation`, `zoom = ln(scale)`.
At this stage scale change is *provisionally* zoom; §5.4 splits zoom from dolly.
Per-pair confidence = RANSAC inlier ratio. Low-confidence spans (motion blur, flat walls, water, smoke) are
interpolated and flagged rather than trusted. Rates are smoothed with a short Savitzky–Golay filter before segmentation.

Wide / action-cam lenses bend the homography model; if metadata says GoPro/ultra-wide, analyse the central 60% crop.

### 5.4 Parallax stage (gated)
**Gate**: run only when |scale rate| exceeds threshold, or the residual flow after homography compensation has
structured energy (parallax). Locked-off and pure pan/tilt clips — often the majority — skip it.

Three implementations. Listed by expected accuracy; **built in reverse order** (3 first — it has no conversion risk;
see §8 Step 2), moving up only if the accuracy gate is missed:

1. **Depth Anything 3 Small → Core ML**: ~16 frames per segment at ~504 px → per-frame extrinsics + intrinsics + depth.
   Focal length changes ⇒ zoom; translation ⇒ dolly/truck/pedestal; median depth gives the normalisation.
   Risk: Core ML conversion of the multi-view attention.
2. **Same model via the MLX Swift port** (`mlx-swift-da3`). Risk: immature (few commits).
3. **Mono depth + residual-flow regression** — Depth Anything V2 Small (official Core ML package exists).
   After removing the rotation/zoom homography, residual flow from camera translation is proportional to inverse depth;
   under pure zoom it is ≈ 0. Least-squares solve for the translation direction against the disparity map.
   No pose network needed; this is classical and robust, and may simply be good enough.

Output: channels 4–6 populated, zoom corrected, `translation_source` recorded.

### 5.5 Segmentation & chips
Per-channel activity with hysteresis thresholds → merge gaps <0.5 s → drop segments <1 s → emit segments.
(PELT change-point detection only if the simple method under-segments on the review set.)
Compute summary, stability class, chips per segment. A clip's grid chips = its dominant segment(s) by duration.

### 5.6 Later on-device stages (not v1)
SigLIP 2 embeddings from the stored proxy; gyro via `telemetry-parser` (exact pan/tilt/roll/shake for GoPro, Sony, DJI,
BRAW, RED) overriding the visual estimate when present; hard-cut detection for files that contain edits.

---

## 6. Description stage (API)

### Request
- Model: Gemini Flash-Lite (current generation; model ID in config, not code). Native video part = the proxy.
  Inline when small, Files API otherwise. `thinking` minimal/off — verify it isn't billed by default.
- **Safety settings at least-restrictive.** Film footage contains violence, blood, nudity; a blocked response must not
  leave a clip untagged. On a block: retry once with frames only, then mark `description_blocked` (and use the local
  model once it exists).
- Prompt = fixed instructions + the measured motion as a hint, e.g.
  `segments: 0.0–3.2s pan right 4°/s, stabilised · 3.2–7.0s push-in slow + tilt up 1°/s`.
  The model is told the measurements are ground truth and that its job is phrasing plus subject-relative judgement.
- Structured output (JSON schema), kept short because **output tokens dominate the cost**:

```json
{
  "description":       "≤ 40 words: subject, action, setting, light",
  "movement_text":     "≤ 25 words, cinematographer's phrasing",
  "subject_relation":  "none | tracking | following | leading | orbit | reveal | reframing",
  "shot_size":         "ECU | CU | MCU | MS | MLS | LS | ELS | insert | aerial"
}
```

### Two lanes
- **Live lane** — clips currently visible or selected, standard API, results in seconds. Concurrency 4–8, exponential
  backoff on 429.
- **Batch lane (after v0)** — everything else, Batch API (50% off), submitted in chunks of ~200 clips, polled; results usually in
  minutes, guaranteed within 24 h. Batch IDs are persisted in `job` so a quit app resumes polling.
- If a clip scrolls into view while waiting in a batch, it is promoted to live; the duplicate batch result is discarded.

### Cost control
Before a run the UI states the estimate: `412 clips · 3 h 12 m · ≈ $0.48`. Token counts are recorded per clip, so the
estimate is calibrated from real usage. *(est.: ≈ $0.67 per 1,000 thirty-second clips on batch.)*

### API key — **open decision, §12**
v1 / private beta: bring-your-own Gemini key, stored in Keychain. Public release needs a thin proxy service
(auth, metering, billing) because a key cannot ship inside the app.

---

## 7. UI

**Windows**: Welcome (recent projects, New Project → name + folder picker) → Project window.

**Project window**
- Toolbar: project name, progress pill (`Analysing 212 / 890 · describing 40 / 890`), thumbnail-size slider,
  sort (name, date shot, duration, movement), pause/resume.
- **Grid** (`NSCollectionView`): poster; under it, the description (2 lines), then movement chips. A small **motion glyph**
  on the poster (arrow / push / rotate icon derived from the summary vector) makes movement scannable without reading.
  Clips appear as soon as they are scanned and fill in progressively: poster → chips → description.
- **Hover**: immediately scrub the sprite by pointer x-position (no decode, works offline); after ~200 ms dwell a pooled
  `AVPlayer` starts muted playback from the original. Pool of 2 players, never one per cell. If the source drive is
  offline, hover stays on the sprite.
- **Click** → select; **inspector** on the right: player with scrubber, description, movement text, per-segment list
  (click a segment to loop it), **motion graph** — seven thin channel traces over time with segment bands, which is both
  the debugging view and the signature visual of the app — then file facts (codec, resolution, fps, camera, lens,
  date, path, Reveal in Finder).
- **Space / double-click** → large player. Arrow keys move selection. Everything keyboard-reachable.
- States: empty project, scanning, drive offline (badge, still browsable), unsupported file, stage failed (retry),
  "never upload" project (descriptions show a quiet "on-device only" placeholder).
- Settings: API key, per-project never-upload, processing on battery (default: pause depth stage), cache size + clear.

**Look**: dark-first, neutral greys so footage colour isn't biased, one accent, SF Pro + SF Mono for numbers, native
materials and toolbar. Light: no Electron, no bundled models in the base download (depth model and offline VLM download
on first use, revision-pinned and checksummed, into Application Support, excluded from backup).

---

## 8. Build sequence (v0)

Claude Code builds this, so the order is set by dependency and risk, not by calendar. Each step ends in something
runnable and is committed separately. Steps 2–3 and 4 are independent once Step 1 lands and can be built in parallel
(separate worktrees / subagents). The only waits are on the inputs listed under "Needed from Ali".

### Needed from Ali
| Input | Blocks | Note |
|---|---|---|
| A folder of real clips (any 20+; more cameras = better) | end of Step 1 | synthetic scenes cover everything until then |
| Gemini API key (paid tier, so footage isn't used for training) | Step 5 only | Steps 1–4 and 6 need no network |
| ~20 min eyeballing the review set (Step 3) | threshold tuning | replaces hand-labelling 100 clips |
| Taste call on the UI after Step 6 | final polish | screenshots provided |
| Xcode install | nothing in v0 (unless Step 1 finds CLT insufficient) | needed right after v0 for signing + MLX |

### Step 1 — Skeleton + motion core, CLI
- `Package.swift`, module layout, `Scripts/bundle.sh`; confirm SwiftUI + tests build under Command Line Tools.
- `docs/motion-spec.md` (§4) committed before any analysis code.
- Decode pass (`AVAssetReader`, downscaled luma @ 8 fps) → global motion, approach B (Vision optical flow + own
  weighted RANSAC + person/saliency mask) with approach A as a cross-check → decomposition → smoothing →
  segmentation → chips + summary vector.
- **Synthetic ground truth instead of hand labels**: SceneKit scenes rendered offscreen to `.mov` with known camera
  paths — every primitive in both directions, compounds (arc, dolly-zoom, crane), handheld noise, a large moving
  foreground subject, low texture, motion blur. Exact per-channel error, generated and scored by `motif-cli eval`.
- `motif-cli analyze <folder>` prints chips + vectors and writes a motion-graph PNG per clip; `motif-cli bench`
  reports × realtime per stage and codec.
- **Gate**: on synthetic scenes — direction sign 100% on clean primitives, ≥ 95% with a moving subject; rate error
  ≤ 15%. On Ali's folder — no crashes, ≥ 5× realtime on 4K HEVC. Failing this changes the plan before any UI exists.

### Step 2 — Parallax stage (zoom vs dolly, translation channels)
- Order flipped from §5.4 for speed: start with **implementation 3** (Depth Anything V2 Small, official Core ML
  package, runtime-compiled + residual-flow regression). No model conversion, no MLX, no Xcode.
- Gate it in only on scale change or structured residual flow. Synthetic dolly / zoom / dolly-zoom / truck scenes
  give exact truth.
- **Gate**: zoom-vs-dolly confusion ≤ 15% on synthetic, and sane on real clips Ali knows to be zooms or push-ins.
  Only if it misses: try DA3 Small (§5.4 impl. 1), which does need conversion work.

### Step 3 — Review set + threshold tuning
- `motif-cli review <folder>` writes one HTML page: each clip's poster, chips, motion graph. Ali marks wrong ones
  (a checkbox + a note); that becomes `Eval/review-set.json`, the real-footage regression set from then on.
- Tune speed thresholds, hysteresis, stability classes against it. Re-run synthetic eval to make sure nothing regressed.

### Step 4 — Catalog + ingest pipeline (parallel with 2–3)
- `.motif` package, GRDB schema + migrations, security-scoped bookmark, scanner, fingerprint, metadata.
- Persistent job queue: stages as states, priorities (visible first), resume after quit, per-stage concurrency limits.
- Decode pass extended to write poster, sprite filmstrip, and the adaptive-fps 360p silent proxy; HLG/PQ tone-map and
  the log-footage heuristic (§5.2).
- Unsupported / corrupt files recorded, not dropped.
- **Gate**: `motif-cli ingest <folder>` builds a complete project package headlessly; kill it mid-run and it resumes;
  re-running on an unchanged folder does zero work.

### Step 5 — Description stage
- Gemini client, native video part (inline or Files API by size), structured JSON output, thinking off, least-restrictive
  safety settings, frames-only retry on a block, backoff on 429, concurrency 4–8. **Live lane only in v0.**
- Prompt v1 with the measured motion as ground-truth hint; key in Keychain; never-upload switch; token accounting and
  the pre-run cost estimate.
- Tagger sits behind a protocol with a recorded-response fake, so the pipeline tests run without a key or network.
- **Gate**: on the review set — the hint removes left/right and zoom/dolly errors in `movement_text`; descriptions name
  concrete subjects in ≤ 40 words; measured cost per clip is recorded in this file, replacing the estimate.

### Step 6 — The app
- Welcome window (recents, New Project → name + folder) → project window.
- `NSCollectionView` grid: poster, 2-line description, chips, motion glyph; progressive fill as stages complete;
  progress pill; size slider; sort.
- Hover: sprite scrub by pointer x immediately → pooled `AVPlayer` (2 players) muted playback after ~200 ms dwell.
- Click → inspector: player + scrubber, description, movement text, segment list with click-to-loop, **motion graph**,
  file facts, Reveal in Finder. Space / double-click → large player. Arrow-key navigation.
- States: empty, scanning, drive offline, unsupported, stage failed + retry, never-upload. Settings: key, never-upload,
  battery policy, cache.
- Verified by launching the bundled app and driving it (screenshots at each state), not only by compiling.
- **Gate**: open a 1,000-clip folder — grid populates progressively, scroll stays smooth, quit and relaunch resumes,
  memory stays bounded (number recorded).

### Step 7 — Real-footage hardening
- Run whole real projects end to end; fix what breaks: VFR, rotation, anamorphic, interlaced, <1 s and >10 min clips,
  slow / external / network drives, moved and renamed files, the log curves of the cameras actually in use,
  ultra-wide crop rule.
- **Gate — v0 done**: a real project of Ali's ingests start to finish with no manual intervention, and he would rather
  browse it in Motif than in Finder.

### After v0, roughly in value order
1. **Movement similarity** — chip query, then keyframed 3D path (§4.5). The differentiator; no competitor has it, and
   the synthetic-scene renderer from Step 1 is already the path→channels converter.
2. Text + semantic search (FTS5 over descriptions; SigLIP 2 over the stored proxies).
3. Batch-API lane (halves API cost; matters at tens of thousands of clips), folder watching (FSEvents).
4. Offline tagger: Qwen3-VL-4B 4-bit via `mlx-swift-lm` — needs Xcode — for never-upload projects, offline use,
   and safety-blocked clips.
5. Distribution: Xcode project or xcodebuild wrapper, Developer ID, hardened runtime, notarisation, Sparkle, opt-in
   crash reports; then the hosted key proxy + billing a public release requires.
6. Export to NLEs (FCPXML keywords / Resolve metadata CSV / Premiere markers); gyro metadata; BRAW / R3D.
7. DA3 pose model if the classical parallax stage proves to be the accuracy ceiling; fine-tuned Qwen3-VL-8B for
   movement language, trained with ViPE-generated ground truth on a rented CUDA box.

---

## 9. Evaluation & testing

- **Synthetic** (exact truth): SceneKit renders → per-channel error, sign tests, robustness to a large moving subject,
  to blur, to low texture. Runs in CI.
- **Review set** (real footage, §8 Step 3): clips Ali has confirmed or corrected; reports per-primitive precision/recall, a confusion matrix
  (the zoom/dolly and pan/truck cells are the ones to watch), and segment-boundary tolerance ±0.5 s.
  Every threshold change is justified by this report.
- **Description quality**: 50-clip blind A/B when changing prompt or model; criteria = factually right, names the
  subject, useful to find the shot again, ≤ 40 words.
- **Unit**: decomposition maths, segmentation, fingerprinting, migrations, batch-state machine (with a fake Gemini server).
- **Performance budget** (`motif-cli bench`, tracked per commit): × realtime per stage, peak memory, grid scroll fps.

---

## 10. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Moving subject dominates frame → false camera motion | high | approach B with person/saliency masks; confidence flagging; synthetic moving-subject scenes |
| Zoom vs dolly still confused | medium | three parallax implementations; lens metadata when present; record `translation_source` so the UI can say "zoom or push-in" honestly at low confidence |
| DA3 → Core ML conversion fails | medium | fallbacks 2 and 3 in §5.4; fallback 3 has no exotic ops |
| Unflagged log footage degrades descriptions / flow | medium | normalisation heuristic; contrast-stretched luma for motion; per-project manual override |
| Gemini blocks legitimate film content | medium | least-restrictive safety settings; frames-only retry; local model (after v0) |
| Gemini pricing / model deprecation (Flash pricing already scheduled to change end of 2026) | certain, eventually | model ID + prices in remote-updatable config; tagger is behind a protocol; offline model is the floor |
| Batch latency feels slow | low | live lane for anything visible |
| Rolling shutter / ultra-wide distortion | medium | central crop for action cams; accept lower confidence |
| NDA'd footage leaving the machine | product risk | never-upload switch from day one; only a 360p 1 fps silent proxy is ever sent; say so plainly in the UI |
| Thousands of cells × video = memory blowup | medium | sprites not players; 2-player pool; `NSCache` with cost limits |

---

## 11. Licences (all commercial-OK; re-verify each on its model card at integration)

| Component | Licence |
|---|---|
| Apple Vision, AVFoundation, VideoToolbox, Core ML | OS frameworks |
| Depth Anything 3 **Small / Base** | Apache-2.0 — **not** Large/Giant (CC-BY-NC) |
| Depth Anything V2 **Small** (fallback) | Apache-2.0 — verify; larger V2 variants are non-commercial |
| Qwen3-VL-4B | Apache-2.0 |
| SigLIP 2 (later) | Apache-2.0 — verify |
| GRDB, Sparkle, mlx-swift-lm | MIT |
| telemetry-parser (later) | MIT / Apache-2.0 |
| **Do not ship**: Apple FastVLM, MobileCLIP2 (research-only); CameraBench weights (unclear "other" licence) | |

---

## 12. Decisions

Taken for v0 (say so if any is wrong):
- **API key**: Ali's own Gemini key in Keychain. A hosted proxy + billing is a public-release concern.
- **Distribution**: none — built from source on this machine. Developer ID + Sparkle after v0.
- **Proxies**: kept in the project package (~0.3 MB per clip *(est.)*) — enables embeddings and re-tagging without the source drive.

Still open:
1. **Test footage** — which folder(s). Ideally spanning the cameras in real use; that decides which log curves Step 7 handles.
2. **Install Xcode now or after v0** — not needed for v0 unless Step 1 finds the Command Line Tools insufficient.
