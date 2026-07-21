# loom

**Update — July 2026:** loom now shows a live **harmony wheel** beneath the
orbit — a circle of fifths that shades the sounding key's scale, lights the
current chord's tones, marks the tonic and ghost-marks the home key as the
piece journeys between keys. The tonal map to go with the orbit's rhythmic one.

Native macOS generative MIDI instrument with a dark-ambient core. A sustained
drone anchors everything; slow, incommensurate loops drift over a curated
harmonic dialect; chords swell with common tones tied through the changes;
a chord-locked pulse supplies motion without becoming another melody; bass,
melody and (at peaks) drums play off a shared rhythmic skeleton. The
melody leaves whole bars of air, treats the sounding chord as gravity and uses
non-chord tones only as brief passing motion. The music develops continuously,
with two-bar themes, long-form reprises and occasional context-aware disruptions that keep repetition alive. Each voice
streams out its own virtual MIDI port for a DAW, while the built-in reference
monitor makes it possible to hear a sketch immediately. See
`loom-design-doc.md` for the full design.

## Download

A signed-for-local-use `loom.app` (Apple Silicon, macOS 14+) is attached to the
[latest release](https://github.com/gravelc-code/loom/releases/latest). It is
ad-hoc signed, so on first launch right-click the app and choose **Open** (or run
`xattr -dr com.apple.quarantine loom.app`). To build from source instead, see below.

## Build & run

Requires macOS 14+ and a full Xcode install (SwiftUI macros aren't in the
bare Command Line Tools). If `xcode-select -p` already points at Xcode, plain
`swift run` works; otherwise prefix with `DEVELOPER_DIR`:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer swift run LoomApp
```

If the repo lives inside Dropbox/iCloud, add a scratch path outside it so
codesigning doesn't trip on file-provider extended attributes:

```sh
swift run --scratch-path ~/.cache/loom-build LoomApp
```

Tests and a headless determinism check:

```sh
swift test --scratch-path ~/.cache/loom-build
swift run --scratch-path ~/.cache/loom-build LoomApp --check
```

## Using it

- **space / ▶** — play. **⏮** — rewind to bar 0 (same seed → identical piece).
  The warning button is a MIDI panic / all-notes-off.
- The compact surface reserves encoders for the three performance macros:
  **push**, **grit** and **evolve**. Continuous voice parameters use truthful
  sliders; octaves, subdivisions, voicing shapes and probability modes use
  switches or labelled segments instead of fake precision.
- Select one of the six colored voice strips to open its fixed detail
  inspector. **drift** is `static`, `gentle` or `free`; live modulation is
  shown as a second marker on continuous controls.
- **lock** (padlock, per voice) — freeze a voice's seed and params while
  everything else keeps evolving. **M**, **S** and the speaker button mute,
  solo and audition a voice. **shuffle** re-rolls unlocked voices; **die**
  starts a new seeded piece. Click the short seed token to edit all 64 bits;
  save/load/export, snapshots and mutation live in the adjacent utility menu.
- The performance macros put **push** (ensemble energy), **grit** (chromatic
  friction, phrase-scale drum fractures and disruption), **segue** (how
  pronounced the textural transitions between sections are — the slow filter,
  reverb-wash and section-bridge swell), **evolve**, **motif**
  and **section** within reach while playing. The sparkle button asks for a
  contextual surprise now.
- The engine bay adds **link** (voices move together ↔ independently) and
  **wander** (literal progression ↔ lawful substitutions). The interest
  readout explains what the engine currently considers too predictable.
- The **direction + form** workbench is autonomous when its selectors read `auto`. You can
  explicitly choose a groove or harmonic dialect, switch which app owns the
  MIDI clock, or queue a build/drop, breakdown or next-section cue. Cues land
  on four-bar boundaries and become part of rewind/save/export.
- **motif memory** — capture A/B snapshots, recall either performance, or
  morph every continuous control to B over eight bars. Undo covers mutate,
  reseed, load, recall and morph.
- The utility menu saves/loads a complete `.loom` performance and renders a
  deterministic 128-bar, six-voice `.mid` file for editing in a DAW.
- The moving **32-bar form strip** shows the actual seeded plan: tension,
  section changes, voice entries, builds, vacuums, drops, breakdowns and queued
  cues. Seeds choose a guarded slow-burn, double-peak, episodic or deep-reset
  grammar, so the arrangement changes without becoming random.
- The piano roll identifies every MIDI port with both a high-separation color
  and a distinct note shape. Its legend selects the matching voice inspector.
- Beneath the orbit, a **harmony wheel** (circle of fifths) shades the sounding
  key's scale, lights the current chord's tones and ghost-marks the home key,
  so the seed's key journeys are legible at a glance.
- The reaction-diffusion **field** remains available behind the workbench's
  field button rather than permanently consuming the main surface.

## Output

Seven virtual CoreMIDI sources (six voices plus clock), and one optional clock
destination — no channel filtering needed:

| port          | carries                                            |
|---------------|----------------------------------------------------|
| `loom drone`  | the sustained foundation: root/5th/octave held for minutes, re-attacked per harmonic span |
| `loom drums`  | General MIDI/Ableton kit: kick 36, side-stick 37, snare 38, clap 39, closed hat 42, floor tom 43, low tom 45, open hat 46 |
| `loom bass`   | monophonic bass                                    |
| `loom chords` | voice-led chord voicings / low-tension swells      |
| `loom pulse`  | monophonic, chord-locked rhythmic movement         |
| `loom melody` | lead line + phase-drift loop layer                 |
| `loom clock`  | MIDI clock (24 PPQN) + start/stop for tempo sync   |
| `loom sync in`| destination for Ableton clock/start/stop/SPP        |

Every voice port also carries CC lanes driven by the modulation engine — map
them to synth macros and the patch breathes with the piece: **CC 1** tension,
**CC 11** expression, **CC 20** field probe, **CC 21** LFO 1, **CC 22** random
walk, **CC 23** activity follower, and the textural transition lanes — **CC 74**
filter-sweep (opens gradually with the tension arc, closes through quiet
passages), **CC 25** section-bridge swell (a slow rise into each section
boundary), **CC 26** downlift (a gentle fall as a peak dissolves into a
breakdown) and **CC 27** reverb-wash (swells in the sparse breakdowns and
intros, pulls back when the mix fills). These are ambient, not EDM — everything
glides. Map them to a filter cutoff, a pad / reverse-reverb swell, a downlifter
and a reverb send and the sections breathe into one another. The `segue` macro
scales how pronounced they are. The drone port adds **CC 24**, a slow triangle
swell over each drone span.
Melody and bass
also emit channel pressure and portamento controls when a generated note
glides.

For immediate sound, enable the speaker in Loom's header; it uses a darkened,
reverberant General MIDI reference palette and is intended for sketching, not
as the final sound design. In Ableton, enable *Track* on the six voice sources
and create one MIDI track per Loom voice. For **Loom master**, enable *Sync* on
the `loom clock` input and set Ableton to EXT. For **Ableton master**, select
`ableton master` in Loom, enable *Sync* on Ableton's `loom sync in` output and
use Ableton's transport normally. Drop a Drum Rack on the drums track and a
big dark pad on the drone track. Port identities persist across relaunches,
so routings stick.

## Architecture

```
Sources/LoomCore   engine: RNG/noise, dialect-filtered progression bank +
                   phrase harmony, consonant pitch pool, drone
                   spans, conductor (tension arc + focus voice), ensemble
                   context (shared anchors/gaps, motif sharing, question →
                   answer), modulation matrix, reaction-diffusion field,
                   six voice generators (drone, voice-led/swelling chords,
                   chord-locked pulse, loop-layer + motif melody,
                   root-stating bass, texture/kit drums), two-bar motif
                   archive, interest/disruption layer,
                   expression lanes, constraint + humanize
Sources/LoomApp    SwiftUI surface, per-voice CoreMIDI ports + bidirectional clock,
                   scheduler (clock → lookahead generation on a worker →
                   timestamped MIDI), reference monitor, performance files,
                   A/B morphing and Standard MIDI File export
Tests/             determinism, tonal law, phrase/cadence structure, voice
                   leading, evolution, arc, lock/mute/solo, motifs, dialects,
                   disruptions and expression lanes
```

Everything is deterministic from `seed + t`: a saved seed replays an entire
evolving performance, not a snapshot.

## License

GPL-3.0
