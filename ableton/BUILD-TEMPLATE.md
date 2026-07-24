# Build `loom.als` — the lean, no-Max recipe

The goal: open loom.app, open this Live Set, press play → six voices sound on stock
devices and the **whole mix breathes with the piece**, with no MIDI-mapping left for the
end user. You only build this once. **No Max patching** — we use Live's own stock
**Expression Control** device (ships with Suite) for the automation.

Time: ~15–20 minutes. You need loom.app **running** the whole time (so its MIDI ports exist).

---

## Part 0 — Preferences (once)
1. Launch **loom.app** and press play once so the ports are live.
2. Live → **Settings → Link/MIDI**. In the **MIDI Ports** list, for each input
   `loom drone / drums / bass / chords / pulse / melody`: turn **Track = On**.
   (Leave Remote off — we're not using native MIDI-map for the lean build.)
3. For `loom clock` input: **Sync = On** (optional, for transport — see Part 4).

## Part 1 — Six voices, six sounds
Create **6 MIDI tracks** (⌘⇧T ×6). For each, in the track's **MIDI From** chooser pick the
matching loom port, set **Monitor = In**, and drop a stock instrument:

| Track | MIDI From | Stock device (suggestion) |
|-------|-----------|---------------------------|
| drone | `loom drone` | Wavetable/Operator — a slow dark pad |
| drums | `loom drums` | **Drum Rack** (kick=36, snare=38, hats=42/46) |
| bass | `loom bass` | Operator mono bass, **Glide on** (honors CC5/65) |
| chords | `loom chords` | warm poly pad |
| pulse | `loom pulse` | plucky/short synth |
| melody | `loom melody` | a lead |

Press play in loom → you should hear all six. (Monitor = In means the tracks sound without
arming.) Add a **Return track** with a **Reverb** and give the drone/chords some send — we'll
automate that send next.

## Part 2 — The automation (the part that makes it breathe)
This is the whole trick: loom's **Tension** lane rides **CC1 (mod wheel)**, and Expression
Control reads CC1 as **"Modwheel."** One device drives the whole mix from the tension arc.

1. On the **drone** track (it receives `loom drone`, which carries CC1), open the browser,
   search **"Expression Control"**, and drag it onto the track so it sits **before** the pad
   in the chain.
2. In Expression Control, on the first **Mod Source** tab set the source to **Modwheel**.
3. Click that tab's **Map** button, then click a target. Do two of these (use two tabs, both
   set to Modwheel, one target each):
   - **Map 1 → a master/group filter cutoff.** Put an **Auto Filter** on the Master (or on a
     group holding all six tracks) and map to its **Frequency**.
   - **Map 2 → the Reverb return's Send/dry-wet** (the reverb swells as tension rises).
4. For each map, set **Min/Max** so the sweep sits in a musical range (e.g. filter Min ≈ 400 Hz,
   Max ≈ open), and raise **Rise** and **Fall** (smoothing) to ~200–400 ms so the movement is
   silky, not stepped.

Press play in loom and let it climb through a build — the filter should open and the reverb
swell across the section, then settle in the breakdown. That's the effect, from one device.

*(Optional, same idea, per voice: add an Expression Control on any voice track, source =
**Expression** (CC11) → the instrument's volume or a macro; on **melody**, source =
**Pressure** → vibrato/level. Smooth with Rise/Fall.)*

## Part 3 — Go deeper later (optional, the section-aware lanes)
loom also sends **Filter CC74**, **Space/reverb CC27**, **Build CC25**, **Drop CC26** — richer,
section-aware envelopes. These aren't in Expression Control's named source list, so they need a
by-number mapping:
- **Native way (stock, slightly fiddly):** Live → MIDI Map mode (⌘M), click the target, let loom
  send. Because loom streams several CCs at once, check the **MIDI Mappings** panel to see which
  CC it grabbed; if it's not the one you want, delete and retry. Fine for a one-time build of 2–3
  targets.
- **Cleaner way (still no Max authoring):** load a free "type-the-CC-number" mapper from
  maxforlive.com (e.g. a CC-mapper/modulator device), set CC 74 / 27, and Map. See the device
  links in the plan.

Don't block the template on these — Part 2 already delivers most of the effect.

## Part 4 — Clock (optional but nice)
- **loom master (recommended):** in loom pick `loom master`; in Live set the transport to **EXT**
  and enable **Sync** on the `loom clock` input. Now play/stop in loom drives Live, so tempo-synced
  FX (delays, LFOs) lock to the piece.
- **Ableton master:** pick `ableton master` in loom, enable **Sync** on Live's `loom sync in`
  output, and drive from Live's transport as usual.

## Part 5 — Save & test
1. **File → Save Live Set As…** → `loom.als` (drop it in this `ableton/` folder).
2. The acid test: quit Live, relaunch, open `loom.als`, open loom.app, press play. Ports reconnect
   (loom pins stable IDs), sounds play, and the filter/reverb breathe — **zero mapping** for whoever
   opens it next.

## Troubleshooting
- **No sound:** track **Monitor = In**? correct **MIDI From** port? loom actually playing?
- **No movement on the filter:** Expression Control on a track that receives a loom port (CC1 rides
  every voice port)? source = **Modwheel**? Map active and pointing at the right param? Min≠Max?
- **Ports missing in Live:** loom.app must be running before you open the MIDI-From list; re-open it.

## References
- [Max for Live devices (Expression Control) — Live 12 manual](https://www.ableton.com/en/live-manual/12/max-for-live-devices/)
- [Using MIDI CC in Live](https://help.ableton.com/hc/en-us/articles/360010389480-Using-MIDI-CC-in-Live)
- [maxforlive.com — CC mapper devices](https://maxforlive.com/library/index.php?by=any&q=cc+mapper)
