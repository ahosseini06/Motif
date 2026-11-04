# Motif

A native Mac app that catalogs a folder of footage and tags every clip with a **description** and its
**camera movement** — a sentence, deterministic chips (`pan right · slow`, `push-in`, `handheld`), and a numeric
motion trajectory per segment. Camera motion is measured on-device; one cheap Gemini call per clip writes the prose.

Design record: [PLAN.md](PLAN.md). Motion conventions: [docs/motion-spec.md](docs/motion-spec.md).

## Run it

Needs macOS 26 on Apple Silicon and the Swift toolchain (Command Line Tools are enough — no Xcode).

```bash
Scripts/bundle.sh              # → build/Motif.app   (add --install to copy it to /Applications)
open build/Motif.app
```

1. **New Project** → choose the footage folder. Analysis starts immediately; the first project downloads the depth
   model (~50 MB, Depth Anything V2 Small, Apache-2.0) into `~/Library/Application Support/Motif/Models`.
2. **Settings (⌘,)** → paste your own Gemini API key → *Save & Test*. Descriptions start as soon as the key verifies.
   See [Bring your own key](#bring-your-own-key).
3. Hover a clip to play it, click for the inspector, space to play/pause, arrows to move, click a segment to loop it,
   drag on the motion graph to scrub. *⋯ → On-Device Only* stops a project from ever uploading.

Projects are `.motif` packages (default `~/Movies/Motif/`): catalog + posters + hover filmstrips + the 360p proxies,
so they stay browsable with the footage drive unplugged. Footage is only ever read.

## Bring your own key

Motif has no account, no server and no key of its own. Camera movement is measured entirely on this Mac; only the
description step calls an API, and it calls it with **your** key, billed to **your** Google account.

- **Get a key** at <https://aistudio.google.com/apikey> (Settings has a *Get a key…* link). Paste it into
  Settings (⌘,) → *Save & Test*, which sends one eight-token request to prove the key and the model ID work before
  any footage goes out.
- **Where it's stored**: your login Keychain, under the service `ai.motif.app`. It is read once per launch and never
  written anywhere else — not into the project package, not into preferences, not into logs. *Remove Key* deletes it.
- **Or don't store it**: `GEMINI_API_KEY` in the environment wins over the Keychain, which is how the CLI and CI run.
- **Free or paid**: a free key works for trying Motif, with much lower rate limits and Google reserving the right to
  train on what you send. For client footage use a paid-tier key, which they don't train on.
- **Cost**: one request per clip carrying a silent 360p proxy (≈ 24 frames) plus the measured motion. Measured at
  **$0.012 for 17 clips ≈ $0.70 per 1,000**. The project's progress pill shows tokens and running cost.
- **Model**: `gemini-3.5-flash-lite` by default, editable in Settings — any `generateContent` model that accepts video
  and a JSON schema will do, so a key with different access just needs a different name typed in.
- **No key, or a key with a problem**: everything else still works. Clips are catalogued, motion is measured, chips,
  segments, movement search and the shot designer all run on-device; only the written description and description
  search wait for a key. A wrong key, an unreachable model or a spent quota stops the description stage after the
  first clip and says why in a banner — the remaining clips stay *pending*, never *failed*, and go out as soon as the
  key is fixed. Nothing re-sends what has already been described.
- **Nothing at all leaves the Mac** for a project switched to *⋯ → On-Device Only*.
- **The Keychain prompt**: an ad-hoc signed build has a new code identity after every rebuild, so macOS asks once more
  to allow access to the stored key. *Always Allow* holds until the next rebuild; a notarised build (below) ends it.

## Sharing it

`Scripts/package.sh` builds `build/Motif-<version>.dmg` (≈ 5 MB): the app, an Applications shortcut, and install notes.

- **As is (ad-hoc signed)** it runs on any Apple Silicon Mac with macOS 26, but macOS blocks the first launch because Apple
  hasn't notarised it. Each person approves it once: System Settings → Privacy & Security → *Open Anyway*
  (or `xattr -dr com.apple.quarantine /Applications/Motif.app`). The notes in the image say so.
- **Notarised** it opens with a plain double-click. That needs an Apple Developer Program membership ($99 / year): install a
  *Developer ID Application* certificate, run `xcrun notarytool store-credentials motif …` once, then
  `MOTIF_SIGN_IDENTITY="Developer ID Application: …" MOTIF_NOTARY_PROFILE=motif Scripts/package.sh`. The Command Line Tools
  include `notarytool` and `stapler`; Xcode isn't required. A stable signature also ends the Keychain prompt after each rebuild.

Everyone brings their own Gemini key (Settings, ⌘,). There is no auto-update: send a new image.

## Search

Two fields above the grid, asked separately and combinable (a clip must satisfy both):

- **Describe the shot** — semantic search over the descriptions, fully on-device with Apple's NaturalLanguage embeddings:
  soft word matching (each query word against its closest word in the description, so "dog" finds "retriever"), the sentence
  embedding, and exact words. On a 12-description test set, 11 of 12 queries put the right clip first.
- **Camera movement** — typed ("slow push in, handheld", "whip pan left", "crane up"), picked from preset chips, or both.
  It all becomes one motion-vector query scored against every segment's measured vector: direction-sensitive, every
  requested move must be present, other motion dilutes the match, and speed / stability / subject-relation refine it.
  Words the phrase table doesn't know are matched semantically against the movement sentence. A clip where only part
  matches shows the matched time range, and selecting it loops that part.

Vectors are stored in the `embedding` table and computed as descriptions arrive (and back-filled when an older project opens).
`motif-cli search <project.motif> --desc "…" --move "…"` runs the same search and prints how the movement text was parsed.

## Shot designer — search by a camera move you draw

*Design a Shot* (next to the search fields) opens a page where you keyframe a 3D camera and then find the footage that moves like it.

- Pick a **duration**, then work in two views of the same reference set: **Set**, a 3/4 overview showing the camera rig, its frustum
  and its path; and **Camera**, what the lens sees, with everything outside the 16:9 frame dimmed (Blender's passepartout) so you
  can see what a move is about to bring in.
- **Auto-key** is on: move the playhead, move the camera, and that is a keyframe. There is no apply step.
  Camera view — drag to look, scroll to dolly, ⌥-drag to truck / pedestal, ⇧-drag to roll, ⌘-scroll or pinch to zoom.
  Set view — drag the camera across the floor, ⌥-drag to raise it, drag anywhere else to orbit the overview.
  Every parameter also has a plain control (nudge buttons, lens and roll sliders) underneath.
- Timeline: scrub, drag diamonds to retime, ←/→ between keyframes, K to key, ⌫ to delete, space to loop playback, ⌘Z to undo.
  Changing the duration stretches the move. *Ease in / out* ramps the ends the way an operator would.
- **Start from** templates (push-in, pan, orbit, crane up, dolly zoom…) are just keyframes to adjust.
- **Reads as** and the motion graph show, live, what the drawn move measures as — in the same chips and channels Motif gives footage.
- **Save** keeps the shot in a library shared by every project (`~/Library/Application Support/Motif/Shots`);
  **Find Similar Shots** ranks the project's clips. Saved shots can also be searched straight from the *Design a Shot* menu.

How the match works: the path is sampled at 8 Hz into the same seven channels as analysed footage (translation divided by the
reference set's median depth, so it is scale-free like the clips'), then compared against sliding windows of every clip's
trajectory at 0.5–2× the drawn duration — cosine similarity over the whole time sequence for direction and shape, scaled by how
close the magnitudes are. A clip where only part matches shows that range and loops it when selected. It combines with the
description and movement fields. `motif-cli shot-test <project.motif>` draws ten known moves and checks each finds its own clip.

The camera pans about the world's vertical, like a tripod head — so panning while tilted rolls the image slightly, exactly as it
does in real footage.

## Into the editor

Drag a thumbnail out of Motif and onto a timeline or bin in Premiere, Resolve or Final Cut. What travels is the original media
file — exactly what a drag from Finder carries — so no plugin or export step is involved. ⌘-click and ⇧-click select more
(⌘A for everything shown), and dragging any selected clip takes them all, in grid order. So: search, select the hits, drag.
Right-click offers Reveal in Finder, Copy (paste into an editor or Finder) and Copy File Path.

A file drag carries whole clips; the matched in/out range of a movement search doesn't travel with it (that needs an
editor-specific interchange such as FCPXML).

## CLI

`build/Motif.app/Contents/MacOS/motif-cli` (or `.build/release/motif-cli`):

| Command | |
|---|---|
| `selftest` | solver recovery with 30% outliers, optical-flow sign + scale, chip rules |
| `synth Eval/synth` | render 29 SceneKit clips with exactly known camera paths |
| `eval Eval/synth [--verbose]` | score the motion pipeline against that ground truth |
| `analyze <file\|dir> [--verbose] [--no-depth]` | print segments, chips, vectors |
| `bench <file\|dir>` | × realtime |
| `ingest <folder> <project.motif> [--describe] [--fake]` | build or resume a project headlessly |
| `describe <project.motif>` | run the description stage (`GEMINI_API_KEY`) and print tokens + cost |

There is no `swift test`: neither XCTest nor Swift Testing ships with the Command Line Tools. `selftest` + `eval` are the tests.

## What was measured (M5 Pro, release build)

- **Synthetic ground truth: 26 / 29 clips pass, direction 29 / 29 correct, median rate error 2.6%** on pan / tilt / roll / zoom.
  Covers every primitive both ways, fast and slow pans, push-in + tilt, arc, handheld, a large moving subject, and
  locked-off shots with a knock at the end (record-button press) — stability class is checked as well as motion.
- The three failures:
  - `dolly_zoom` — detected and labelled correctly; zoom rate reads 20% low.
  - `pushin_subject` — push-in while a subject covering ~30% of frame crosses it reads as *zoom in*.
    (The subject is a box; on real footage people are masked out of the fit with Vision person segmentation, which the synthetic scene can't exercise.)
  - `truck_neg` — chip is right (*truck left*); raw rates show false pan late in the clip where one near object fills the frame.
- **Speed: ≈ 5× realtime per clip** on 1080p H.264 including posters, filmstrips and proxies; ≈ 6× with the default two
  clips in parallel. Optical flow (~30 ms per pair at 8 Hz) is the floor, not decode.
- Four real handheld clips: plausible (`static`, brief `pan left · slow`), and that run is what motivated the minimum-sweep rule.
- Re-running on an unchanged folder does no work; a killed run resumes.

## Tested on real use, and not yet

- **Gemini: verified on a real project (17 clips, 197 s).** All described by `gemini-3.5-flash-lite`, none failed or blocked;
  29,371 tokens in / 1,262 out = $0.012, i.e. **≈ $0.70 per 1,000 clips**. Descriptions are concrete and the model follows the
  measured motion it is given. Still untested: the fallback that drops a rejected tuning field, the safety-block path, rate limits at scale.
- **Real filmmaking footage**: log / HDR, ProRes, 4K HEVC 10-bit, anamorphic, VFR, rotated phone clips, long takes, real
  push-ins and zooms. Thresholds in `MotionSpec` are tuned on synthetic scenes and four phone clips — expect to adjust them.
- Hover playback, keyboard navigation and the offline-drive state were built but only the static UI was verified from screenshots.
- Large projects (1,000+ clips): grid is a SwiftUI `LazyVGrid`, image caches are cost-bounded, but it hasn't been loaded that hard.

## Deviations from the plan

- One library target (`MotifKit`) with folders instead of five modules; Swift 5 language mode (AVFoundation / Vision /
  SceneKit aren't Sendable-clean enough for strict concurrency to pay off yet).
- Light theme in the manner of Linear (near-white surfaces, hairline borders, one indigo accent, bordered label pills) rather
  than the dark-first look in PLAN §7 — all tokens are in `Theme` (`Sources/MotifApp/Support/Support.swift`).
- Grid is SwiftUI `LazyVGrid`, not `NSCollectionView` — swap if it stutters at scale.
- Hover = play (as asked), after a 160 ms dwell, from one shared muted player. The filmstrip scrubs under the pointer until
  playback is ready, and is all you get when the drive is offline.
- Flat-footage normalisation is applied to the **proxy only**; thumbnails stay faithful to the file.
- A safety-blocked clip is marked *blocked* (retry from ⋯ → Rescan); the planned frames-only retry isn't built.
- No pre-run cost prompt — processing starts on open; running token count and cost are in the progress pill's popover.
- Added, not in the plan: minimum-sweep rule, depth-offset resolution, fast-pan zoom correction, flow self-calibration
  (all in the motion spec), a text filter over names / descriptions / chips, `--snapshot` for scripted UI checks.
- Proxies are ~1 MB per clip, not the estimated 0.3 MB (H.264 at ~1 fps is nearly all keyframes). Token cost is unaffected.

## Licence

Motif is MIT-licensed — see [LICENSE](LICENSE).

What it depends on, and under what terms:

| | |
|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT — the only third-party source dependency |
| [Depth Anything V2 Small](https://huggingface.co/apple/coreml-depth-anything-v2-small) (Apple's Core ML package) | Apache-2.0 — downloaded on first use, not vendored |
| AVFoundation, Vision, SceneKit, NaturalLanguage, Metal | Apple system frameworks |
| Gemini | your own API key, your own account — see [Bring your own key](#bring-your-own-key) |

Weights that **must not** be shipped with this app, because their licences forbid commercial or redistributed use:
Apple FastVLM, MobileCLIP2, CameraBench, and Depth Anything 3 Large / Giant (CC-BY-NC). The motion pipeline
deliberately needs none of them.
