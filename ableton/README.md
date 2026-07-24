# loom → Ableton: automation made effortless

loom streams continuous **CC automation lanes** on every voice port — a filter that
opens across a build, a reverb that swells in the breakdowns, a riser into each
section, the conductor's tension arc. Turning those into *moving Ableton parameters*
used to mean hunting CC numbers and hand-MIDI-learning each one. These assets do the
mapping once, so you don't.

Two ways in, pick either:

### A. Load-and-go — `loom.als`
1. Open **loom.app** and pick `ableton master` **or** `loom master` for the clock.
2. Open **`loom.als`** in Ableton Live 12.
3. Press play. Six voices sound on stock devices, and the automation already breathes —
   filter, reverb send, riser, drone swell — **zero mapping**.

Swap in your own instruments any time; the loom device stays mapped, you just re-point
its outputs at your device's parameters (one click each).

### B. Map to your own rig — stock **Expression Control** (no Max)
loom's **Tension** lane rides **CC1**, which Live's stock **Expression Control** device reads as
"Modwheel." Drop it on a loom-fed track, source = Modwheel, **Map** → a filter cutoff and a reverb
send, add **Rise/Fall** smoothing — and the whole mix breathes with the piece. For the section-aware
lanes (Filter CC74, Space CC27, Build CC25) map by number (native ⌘M, or a free CC-number device).

> **To actually build the template, follow [`BUILD-TEMPLATE.md`](./BUILD-TEMPLATE.md)** — a
> ~20-minute, no-Max, click-by-click recipe. The rest of this file is the reference spec.

---

## The lane map

Every musical port carries the **global** lanes and its own **Expression**; `loom drone`
adds the **Drone swell**. Machine-readable copy: [`loom-lanes.json`](./loom-lanes.json).
Source of truth: `Sources/LoomCore/Control.swift`.

| Lane | CC | Polarity | What it does | Natural target |
|------|----|----------|--------------|----------------|
| **Tension** | 1 | uni | Global conductor arc over minutes | master filter / intensity |
| **Filter** | 74 | uni | Opens on a build, snaps wide at the drop, closes in a breakdown | filter cutoff |
| **Build** | 25 | uni | Riser: rises through the build, snaps to 0 at the drop | riser / noise sweep |
| **Drop** | 26 | uni | Downlifter: falls over the drop / out of a peak | impact / downlifter FX |
| **Space** | 27 | uni | Reverb-wash: swells in vacuums, pulls back when dense | reverb send |
| **Field** | 20 | bi | Reaction-diffusion texture | slow texture mod |
| **LFO** | 21 | bi | LFO 1 | periodic mod |
| **Walk** | 22 | bi | Random walk | drifting mod |
| **Activity** | 23 | bi | Overall density follower | delay/reverb mix, dynamics |
| **Expression** | 11 | uni | Per-voice musical arc (differs per port) | volume / a macro |
| **Drone swell** | 24 | uni | Triangle over the drone span (drone port only) | filter / timbre / send |

Also expressive (already standard MIDI, no mapping needed): **CC5/CC65 portamento** and
**channel pressure** on melody & bass glides — honor them in the synth's glide/pressure settings.

> Lanes are 7-bit and sampled 8×/bar. The device **slews** them into continuous signals, so
> filter sweeps don't zipper — that smoothing is the difference between "a stepped CC" and
> "the patch breathing." Prefer the device (or a slew) over raw CC mapping.

---

## Optional future enhancement — a custom `loom.amxd` device

Not needed for the recipe above (stock Expression Control covers the hero lanes). This is a
nice-to-have *if* we later want every lane labeled and slew-smoothed in one purpose-built device
— it would require authoring in Max. A **MIDI-effect** Max for Live device (so it sees the
incoming CC from the track's loom input):

- **Input:** live MIDI; read CC values, match against the lane table above.
- **Slots:** ~6 modulation slots. Each slot has:
  - a **lane menu** (Tension, Filter, Build, Drop, Space, Field, LFO, Walk, Activity, Expression, Drone swell),
  - **Smooth** (slew, ms — default ~80–150 ms; higher for filter/space, lower for LFO),
  - **Depth** (0–100%) and **Polarity/Invert**; bipolar lanes (Field/LFO/Walk/Activity) center at 0,
  - a **Map** button → an **M4L Modulation** output (`Modulation` mode by default; `Mod` toggle to Remote if a param needs absolute control).
- **Mode toggle** (optional): *This voice* (uses CC11 Expression + the track's targets) vs *Global*
  (Tension/Filter/Build/Drop/Space/Activity) — so one instance drives session-wide targets and the
  per-track instances handle voice-local expression, instead of six copies of the global lanes fighting.
- **MIDI pass-through:** on (notes flow to the instrument downstream).

Keep the labels and CC numbers in sync with `loom-lanes.json`.

## Build spec — `loom.als` (template)

- **6 MIDI tracks**, inputs pre-set to the pinned loom ports (they survive relaunch):
  | Track | Input | Stock device | loom Modulator mapping |
  |-------|-------|--------------|------------------------|
  | drone | `loom drone` | dark evolving pad | Drone swell→cutoff, Tension→cutoff |
  | drums | `loom drums` | Drum Rack (kick 36 · snare 38 · hats 42/46) | Activity→room/reverb send |
  | bass | `loom bass` | mono bass (glide on; honors CC5/65) | Expression→volume |
  | chords | `loom chords` | warm poly pad | Filter→cutoff, Expression→volume |
  | pulse | `loom pulse` | plucky/rhythmic synth | Filter→cutoff |
  | melody | `loom melody` | lead (glide + pressure→vibrato/level) | Expression→volume |
- **Return track:** a reverb; **Space (CC27)** → its send (a "global" loom Modulator instance).
- **Master/global:** **Tension** or **Build** → a global filter and/or a riser channel; **Drop** → an impact FX.
- **Clock:** default **loom master** — in Live, EXT on, sync input = `loom clock`. Alternative:
  **Ableton master** — pick `ableton master` in loom, enable Sync on Ableton's `loom sync in` output,
  drive from Ableton's transport.

## Notes for whoever authors these
Built in **Max 8 + Ableton Live 12 (Suite / Max for Live)**. `.amxd` and `.als` are binary DAW
assets — they can't be produced or verified from loom's Swift toolchain, only in Ableton. Once they
land in this folder, the app's onboarding gains a "Get the Ableton template" affordance and the
release ships a `loom-ableton.zip`.

**Status:** lane manifest ([`loom-lanes.json`](./loom-lanes.json)), this reference spec, and the
no-Max build recipe ([`BUILD-TEMPLATE.md`](./BUILD-TEMPLATE.md)) are here. `loom.als` is built by
following the recipe (stock devices only); a custom `loom.amxd` is an optional future extra.
