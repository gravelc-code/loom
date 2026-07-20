# loom — design document

*Working name; `loom` is a placeholder mark. Native macOS generative music instrument.*

---

## 1. Thesis

`loom` is a generative music instrument that produces a **complete, evolving arrangement** — drone, drums, bass, chords, pulse, and melody — from a small set of simple rules. It is not a step sequencer that loops a pattern and not a DAW. Its defining property is that **the music develops continuously over time**: it never settles, never exactly repeats, and has long-form shape rather than static texture.

The guiding tension is *simple under the hood, deep in the hands, emergent in the output*. Complexity lives in three places only: the interactions between simple primitives, the controls exposed to the user, and the passage of time. No single mechanism is complicated.

Three commitments carry the whole design:

- **Generate control, not sound.** `loom` emits MIDI to the user's own instruments (plus one optional built-in voice). This deletes the entire synthesis/DSP burden and lets the user supply timbre from whatever they already love.
- **Constraint is where musicality comes from.** Genuinely evolving, probabilistic generators are cheap; a thin constraint layer (key, scale, chord context, rhythmic grid) is what makes their output land as *abstract but complete* rather than as noise.
- **Time drives everything.** The control surface is not set once — it is modulated, arranged, and remembered so the piece evolves at every timescale.

---

## 2. What "generative" means here

This is the section the rest of the document serves. The failure mode to design against: a system where each loop differs slightly but the piece as a whole stands still. The fix is to make evolution happen at three distinct timescales, each with its own mechanism and its own user control over *how much* and *how fast*.

| Timescale | What changes | Mechanism | User controls the rate/character via |
|---|---|---|---|
| **Micro** (per step / per cycle) | Which hits fire, exact timing, velocity, ratchets | Per-step probability + correlated humanize | `humanize`, `ghost`, `ratchet`, `swing` |
| **Meso** (bars / phrases) | The generator parameters themselves — density, register, syncopation, harmonic rhythm | Modulation matrix (slow sources routed onto voice params) | `drift` (per voice), `evolution rate`, mod depth |
| **Macro** (minutes / whole piece) | Arrangement, tension arc, which voices play, progression, motif development | Conductor + motif memory | `section length`, `tension curve`, `motif recurrence`, `morph` |

Two additional properties make it read as *composed* rather than *noodled*:

- **Motivic memory and development.** Voices — melody especially — keep a short memory of recently generated material and prefer to recall and *transform* it (transpose to the current chord, invert, retrograde, augment, fragment) over generating fresh randomness. Recurrence with variation is what the ear hears as intention.
- **An honest long-form arc.** A conductor shapes density, activity, and harmonic motion over minutes, so the piece has intro / development / peak / breakdown character instead of a flat wash.

The design principle throughout: **give the user knobs over the rate and character of change itself**, not just over the current state. Meta-generative controls are the real instrument.

---

## 3. Architecture

Signal and logic flow, bottom to top. Each voice generator is a near-pure function of `(params(t), harmony(t), modulation(t), motifMemory, tick, rng)`. The point of the layered design is that **`params(t)` is itself a function of time**, produced by the modulation and conductor layers — that is the entire mechanism of "it changes over time."

```
                          ┌──────────────┐
                          │  CONDUCTOR   │  long-form arc, tension, sections,
                          │ (macro time) │  voice activity, harmonic rhythm
                          └──────┬───────┘
                                 │ scales density / depth / activity
   ┌───────────┐   ┌────────────▼────────────┐   ┌───────────────┐
   │  CLOCK    │──▶│   MODULATION MATRIX      │◀──│  METAL FIELD  │ sonified
   │ phase/bar │   │  LFOs · random walks ·   │   │  (CA / RD sim)│ simulation
   └─────┬─────┘   │  1/f drift · followers   │   └───────────────┘
         │         └────────────┬─────────────┘
         │                      │ routed onto voice params + humanize
         │         ┌────────────▼─────────────┐
         │         │   HARMONY ENGINE          │ key · scale · advancing
         │         │   (tonal law)             │ progression · voice-leading
         │         └────────────┬─────────────┘
         │                      │ current chord/scale context
   ┌─────▼──────────────────────▼──────────────────────────────┐
   │ VOICE GENERATORS  drone · drums · bass · chords · pulse · melody │
   │  each: generate(params(t), harmony(t), mod(t), memory, t)   │
   └─────────────────────────────┬──────────────────────────────┘
                                 │ raw events
              ┌──────────────────▼──────────────────┐
              │ CONSTRAINT PASS  snap to scale/chord, │
              │ hold grid, enforce range, de-collide  │
              └──────────────────┬──────────────────┘
              ┌──────────────────▼──────────────────┐
              │ HUMANIZE PASS  correlated micro-timing │
              │ + velocity from shared feel source     │
              └──────────────────┬──────────────────┘
              ┌──────────────────▼──────────────────┐
              │ OUTPUT  scheduled MIDI (per voice) +  │
              │ optional built-in voice               │
              └──────────────────────────────────────┘
```

---

## 4. The evolving state model

Model the running system as `state(t)`, reproducible from a master seed plus time:

```
state(t) = {
  transport:  { tempo, tick, bar, phase }
  harmony:    { key, scale, currentChord, progression, harmonicRhythm }
  modulation: { source values sampled at t }
  conductor:  { section, tension, activity[voice] }
  voices:     { params[voice], memory[voice] }
}
```

- **Determinism.** All randomness comes from a seeded PRNG and all sources are parameterized by time, so `seed + t` reproduces the same evolving performance. Saving a seed saves a whole *piece*, not a snapshot — you can return to a performance and it keeps developing the same way.
- **`mutate`.** Advances or perturbs the seed. Re-rolls unlocked voices and nudges unlocked parameters within musical bounds.
- **Lock.** Freezes a voice's sub-seed and parameters while global time keeps evolving everything else. This is the core creative loop: freeze what you love, let the rest keep moving. (In the mock, the per-voice lock toggles and `mutate` demonstrate exactly this.)

---

## 5. Harmony engine (the tonal law)

A single shared module that governs every pitched voice, so however abstract the surface gets it stays in key and vertically coherent. This is half of "musically complete."

- **Static-ish law:** `key`, `scale` (modal set), root octave, allowed range.
- **Evolving law (important for development):** a **progression that advances over time**. Chords are chosen by a constrained function-Markov over the scale's diatonic chords (e.g. in A minor: i, iv, v, VI, III, VII…), advancing every *N* bars. `N` (harmonic rhythm) is itself modulatable and scaled by the conductor, so the harmony can speed up into a peak and relax in a breakdown. A static key with a moving progression is one of the largest, cheapest sources of forward motion.
- **Voice-leading:** resolve each voice's pitches to the nearest chord/scale tones to avoid random leaps between chords.
- **Output each bar:** `currentChord` (pitch classes), `scaleMask`, `tensionTones` — consumed by the constraint pass and the voice generators.

---

## 6. Voices

Six voices appear as compact channel strips; selecting one opens a stable inline inspector. Parameters use continuous controls only when intermediate values have a real audible meaning. Octaves, subdivisions, layer choices, voicing shapes and coarse probability modes are explicit switches or labelled segments. Only continuous destinations may be moved by modulation.

### 6.1 Drums (rhythm engine)
An authored 16-slot kit grammar establishes a dependable kick, snare and hat pocket before adding variation. Most movements are straight or half-time; broken time is a rare color. Backbone hits become certain at full kit presence, while the seed chooses only pickup notes, side-stick answers and one of several short fill gestures. Toms are reserved for fills rather than scattered through ordinary bars.

The output follows conventional General MIDI / Ableton kit notes: kick 36, side-stick 37, snare 38, clap 39, closed hat 42, floor tom 43, low tom 45 and open hat 46. Parameters: `amount`, `density`, `swing`, `ghost`, `ratchet`, `fills`, `poly`, `recur`, `dynamics`, `humanize`.

*Evolves by:* kit presence assembling hats → kick → snare → clap, optional hits returning on 2/4-bar conditions, short authored fills announcing boundaries, and density/swing breathing under slow modulation. At higher `grit`, deterministic 2/4/8-bar phrase fractures remove a kick, displace a pickup, flam a snare, burst a hat or answer with a compact tom descent; the listener can still learn the pocket before it bends. The lower two-thirds of `poly` retain conventional 4/4; only its deliberately experimental top end phases side-stick and tom ornaments.

### 6.2 Bass
Monophonic, root-and-movement. Follows the harmony engine with a `follow` parameter that blends between "lock to chord roots" and "walk freely within the scale."

Parameters: `density`, `octave`, `glide` (portamento probability/time), `accent`, `follow`, `decay`, `tone`, `sub`.

*Evolves by:* register drift (`octave` modulated), rhythmic density breathing, `follow` wandering so the line tightens and loosens against the harmony.

### 6.3 Chords
Polyphonic harmonic bed. Voices the current chord with controllable spread and inversion. It emits only swells and tied pad attacks; rhythmic comping belongs to the pulse port so the two roles can receive different instruments and effects in a DAW.

User controls: `presence`, combined `register`, close/open `voicing`, and `strum`. Release variation is seeded internally; harmonic color comes from tension, grit and the selected dialect rather than three competing controls.

*Evolves by:* register and voice-leading color drifting continuously while the user's discrete voicing choice remains stable.

### 6.4 Pulse
Monophonic rhythmic harmony. It holds one voice-led current-chord tone for a learnable two/four-bar cell rather than cycling an up/down arpeggio. Builds increase subdivision, the vacuum silences it, and a drop restores it on beat one. Higher `grit` can fracture timing or add one controlled ratchet, but never changes the pitch law.

Parameters: `amount`, `density`, `division`, `gate`, `octave`, `recur`, `ratchet`, `dynamics`, `humanize`.

### 6.5 Melody (lead) — the hardest one
Where "musically complete over time" is won or lost. Pure per-bar randomness sounds like noodling; this voice must *develop material*.

User controls: `presence`, `note rate`, `space`, combined `register`, `length`, plus segmented dynamics, motion, repetition, contour, glide and feel. Seeded duration variation remains internal.

*Development engine:* a ring buffer of recent melodic cells. Each phrase, a `motif recurrence` control chooses between **generate fresh** and **recall + transform** an earlier cell (transpose to current chord, invert, retrograde, rhythmic augment/diminish, fragment). High recurrence → thematic and song-like; low → through-composed and restless. The default line is deliberately withholding: one faint intermittent phase loop, frequent whole-bar rests and compact motif gestures. Sustained or exposed notes are current-chord tones; only brief, stepwise passing notes may leave the chord. This makes the pad and melody one harmonic thought rather than two independent generators occupying the same space.

---

## 7. Modulation matrix & generative core

The engine of meso-scale evolution. A bank of slow, normalized sources, routable to any voice parameter via a `source × destination × depth` matrix.

- **LFOs** at musical divisions (from a few bars up to phrase length), multiple shapes.
- **Bounded random walks** (drift-toward-target + noise, i.e. smoothed/Ornstein–Uhlenbeck-style) — natural, non-repeating wander that stays in bounds.
- **1/f (pink) drift** for organic long-term movement.
- **Activity followers** — envelope followers of overall density, enabling reactive behaviour (e.g. melody thins when drums intensify).
- **The Metal field** — a GPU cellular-automaton / reaction-diffusion simulation, sampled at probe points to yield scalar/vector streams. This is the "simple rules → emergent, deterministic, non-repeating structure" source, and it doubles as the visual signature (the `field` scope). Runs exactly like a generative-art shader; its output is just routed to music parameters instead of pixels.

**Correlated humanize.** One shared "feel" walk per voice fans out to both micro-timing and velocity with a fixed relationship, so they move *together*. This is the difference between abstract-and-alive and abstract-and-broken — humanize is never `rand()`.

---

## 8. Conductor (long-form arrangement)

The macro brain that gives the piece shape over minutes.

- A **tension** value in `[0,1]` driven by a seeded section grammar. Each seed chooses a guarded slow-burn, double-peak, episodic or deep-reset profile; all preserve prepared peaks and meaningful releases while changing the large-scale journey.
- A planned peak has a **two-bar build** that increases repetition and subdivision, then a **one-bar vacuum** that removes drums, bass and chords while tension stays high. The **drop** restores the whole kit on beat one with bass weight and shorter harmony. Its following **breakdown** is a genuine orchestration change: the low end releases, registers fall, and sparse harmony lengthens so the next ascent has somewhere to go.
- The autonomous schedule remains the default. Optional groove/dialect selectors and persisted four-bar cues can time-map the seeded form into its next peak, breakdown or section without turning the instrument into an editable DAW timeline.
- Tension scales: global density, per-voice **activity gates** (which voices are currently playing), modulation depth, `tension`-type parameters, and harmonic rhythm.
- `section length` sets the macro clock; `morph` crossfades between two saved states over a chosen number of bars, so you can compose evolution by defining endpoints and letting `loom` travel between them.

The conductor is what stops the output from being a beautiful but flat texture. It can run free or deterministically from the seed (so a seed reproduces a whole shaped piece).

---

## 9. Evolution controls (foreground, user-facing)

The controls that directly answer "it must change over time." These are meta-generative — they govern change itself.

- **Per-voice `drift`** — how far that voice's parameters are allowed to wander.
- **`evolution rate`** (global) — master speed of all slow modulation.
- **`motif recurrence`** — thematic vs through-composed, per pitched voice.
- **`section length` / `tension curve`** — the shape of the macro arc.
- **`morph`** — travel between two saved states.
- **`link`** — how correlated the voices' evolution is (move together vs independently).
- **Per-voice `lock`** — exempt a voice from all of the above.

---

## 10. Constraint & humanize passes

Applied after generation, before output.

- **Constraint:** snap pitches to `scaleMask`/`currentChord`; keep hits anchored to the grid even when micro-timing displaces them; clamp to per-voice range; resolve simultaneous-note collisions and voice overlaps.
- **Humanize:** apply correlated micro-timing + velocity from the shared feel source; optional per-voice groove template.

Together these guarantee vertical coherence (in-key, in-chord) while the conductor and motif memory guarantee horizontal coherence (development, arc). Both axes = "complete."

---

## 11. Output

- **MIDI-first.** Each voice on its own channel/virtual port, to external instruments. Notes carry pitch, velocity, timing, duration; ratchets expand to multiple notes; optional MPE for glide/expression.
- **Switchable clock.** Loom can send 24-PPQN clock and own tempo, or receive clock/transport/SPP from Ableton. External-clock loss stops and silences the scheduler rather than freewheeling.
- **Scheduling.** Generate a **lookahead window** (e.g. one bar ahead) on a worker, schedule events with sample-accurate timestamps. Generation must never run on the audio render thread.
- **Optional built-in voice.** One minimal synth (or sampler) so `loom` makes sound standalone without external gear. Deliberately modest — the product is the generator.

---

## 12. UX & layout

Aesthetic direction: Teenage Engineering — near-monochrome, one committed accent, pictogram/lowercase labels, strict grid, reads as a physical object. See the interactive mock (`loom.html`) for the realized language.

**Progressive depth, not a wall of encoders.** The 1180×720 surface has four stable tiers: transport plus three performance encoders; orbit plus form/piano roll; six voice strips; and one fixed selected-voice inspector beside direction controls. Continuous parameters are compact sliders with live modulation markers. Discrete musical decisions are switches or segmented labels. Secondary file, seed and snapshot actions live in one utility menu.

**Make the evolution visible.** The mock currently *looks* static because nothing on screen moves except the playheads — and that's exactly the perceptual failure to fix. The UI must show development as it happens:

- Knob indicators visibly **creep** as modulation moves parameters (show the modulated value as a second, ghosted indicator).
- A moving **32-bar form strip** of real per-bar conductor state: section, tension, active voices, structural events and queued cues.
- A **"now / next chord"** readout from the harmony engine.
- A **motif-memory** strip showing recent cells and when they recur.
- Per-voice **activity meters**, high-separation piano-roll colors plus shapes,
  and the live `field` scope available on demand in the inspector.

If the user can *see* the parameters wandering and the arc unfolding, the instrument reads as alive even before they hear it.

---

## 13. Tech stack

- **Language / platform:** Swift, native macOS (Apple Silicon).
- **Audio/MIDI/clock:** AVAudioEngine or AudioKit for transport, MIDI I/O, scheduling, and the optional built-in voice.
- **Simulation core:** Metal compute shader for the CA / reaction-diffusion field (same pipeline you'd use for generative art; sample its texture for modulation streams).
- **Learned generation (optional, later):** CoreML for model-driven melody/harmony, run off the audio thread and fed through the same constraint pass.
- **Threading rule:** clock → generation (lookahead, worker) → scheduled MIDI. Keep the generative engine and Metal field off the render thread entirely; communicate via lock-free buffers.
- **Distribution:** single signed DMG, GPL-3.0.

---

## 14. Determinism & persistence

- A performance = `{ masterSeed, voiceParams, modMatrix, conductorConfig, harmonyConfig }`. Small and shareable.
- Because time-parameterized and seeded, a saved performance **replays and keeps evolving identically**.
- Presets store parameter/routing/config sets, not frozen patterns.
- Per-voice lock states persist so "frozen kick, evolving everything else" is a saveable state.

---

## 15. Non-goals

- Not a DAW; no arrangement timeline editing, no audio tracks.
- Not a synthesis/sound-design powerhouse; MIDI-first, one modest internal voice.
- No audio-rate DSP-heavy processing.
- Not a fixed-pattern step sequencer — a pattern that merely loops is explicitly the thing this is not.

---

## 16. Build phases

Sequenced so **evolution is proven first**, before breadth.

1. **Prove the evolution.** Clock + drums only, with per-step probability, correlated humanize, polymeter, and **one modulation source visibly driving `density`**. Success = the beat audibly *develops* over a couple of minutes, not just wiggles. If this doesn't feel alive, nothing downstream will.
2. **Harmony + pitched voices.** Harmony engine with advancing progression; bass and melody through the constraint pass. Add motif memory to melody.
3. **Depth + long-form.** Chords; the conductor and tension arc; the full modulation matrix and routing UI.
4. **Signature + polish.** Metal field as a mod source and visual; optional CoreML; the TE UI with visible-evolution affordances; DMG packaging.

---

## 17. Resolved product decisions

- MIDI remains the primary output; the built-in General MIDI monitor is a deliberately modest reference palette.
- The conductor is deterministic from the seed. Persisted, quantized direction cues remap the autonomous form without creating a DAW timeline.
- CoreML generation is deferred; deterministic musical constraints and motif development remain the foundation.
- Melody is monophonic and intentionally withholding. Rhythmic chord motion belongs to the separate, chord-locked pulse voice.
- Motif transforms and modulation routing stay curated behind musical controls until exposing another choice clearly improves performance rather than configuration.
