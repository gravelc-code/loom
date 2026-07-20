import Foundation

/// A kit player, not a random trigger cloud. Kick, snare and hats establish a
/// readable pocket first; seeded variation is confined to pickup notes,
/// side-stick answers and deliberate fills. The `poly` control can still pull
/// ornament tracks away from 4/4, but only near the top of its range.
public struct DrumGenerator {
    /// Target loop lengths at maximum `poly`. The musical backbone and both
    /// hats always remain on the 16-step bar grid.
    static let loopLengths: [DrumTrack: Int] = [
        .kick: 16, .snare: 16, .hat: 16, .hatOpen: 16, .clap: 16,
        .rim: 12, .perc: 15, .glitch: 13,
    ]

    /// 0…0.65 is a conventional one-bar kit. Above that, only side-stick and
    /// tom ornaments gradually acquire polymetric lengths. This keeps the
    /// default useful with a standard Ableton/GM kit while preserving an
    /// intentionally experimental end of the control.
    public static func effectiveLoopLength(_ track: DrumTrack, poly: Double) -> Int {
        let target = loopLengths[track] ?? 16
        guard target != 16, poly > 0.65 else { return 16 }
        let t = min(1, (poly - 0.65) / 0.35)
        return max(4, 16 + Int((Double(target - 16) * t).rounded()))
    }

    public enum GrooveStyle: String, CaseIterable, Codable, Hashable, Sendable {
        case straight, halftime, broken
    }

    /// Most movements choose a straight or half-time pocket. Broken time is
    /// now an occasional color rather than nearly a third of all pieces.
    public static func style(profileSeed: UInt64, override: GrooveStyle? = nil) -> GrooveStyle {
        if let override { return override }
        var rng = RNG(seed: hashSeed(profileSeed, 0x5354_594C))
        return [GrooveStyle.straight, .halftime, .broken][rng.pick([0.52, 0.38, 0.10])]
    }

    /// Structural hits are never trig-conditioned and become certain once a
    /// track is fully present. These are the meter the other voices can trust.
    static func backbone(track: DrumTrack, style: GrooveStyle) -> Set<Int> {
        switch (track, style) {
        case (.kick, .straight):  return [0, 8]
        case (.kick, .halftime):  return [0, 10]
        case (.kick, .broken):    return [0, 7, 10]
        case (.snare, .halftime): return [8]
        case (.snare, _):         return [4, 12]
        default:                  return []
        }
    }

    /// A small authored vocabulary. Seed chooses a variation; it does not
    /// assign an unrelated probability to every sixteenth note.
    static func profile(track: DrumTrack, len: Int, subSeed: UInt64,
                        style: GrooveStyle = .straight) -> [Double] {
        guard len > 0 else { return [] }
        var rng = RNG(seed: hashSeed(subSeed, 0x5052_4F46, UInt64(track.rawValue)))
        let variation = rng.int(3)
        var weights = [Double](repeating: 0, count: len)
        func put(_ step: Int, _ weight: Double) {
            let i = ((step % len) + len) % len
            weights[i] = max(weights[i], weight)
        }

        switch track {
        case .kick:
            switch style {
            case .straight:
                put(0, 1); put(8, 0.92)
                put(variation == 0 ? 6 : variation == 1 ? 11 : 14, 0.34)
            case .halftime:
                put(0, 1); put(10, 0.82); put(14, 0.28)
                if variation == 2 { put(6, 0.24) }
            case .broken:
                put(0, 1); put(7, 0.78); put(10, 0.68); put(14, 0.28)
            }

        case .snare:
            if style == .halftime { put(8, 1); put(7, 0.18); put(14, 0.16) }
            else {
                put(4, 1); put(12, 0.96); put(3, 0.16); put(11, 0.18)
                if style == .broken { put(7, 0.34); put(13, 0.28) }
            }

        case .hat:
            // Quarter notes are the floor; eighths carry the normal groove;
            // sixteenths are quiet energy-dependent decoration.
            for step in stride(from: 0, to: 16, by: 2) {
                put(step, step % 4 == 0 ? 1 : 0.78)
            }
            if style == .broken {
                for step in [3, 7, 11, 15] { put(step, 0.30) }
            } else if variation == 1 {
                for step in [3, 11] { put(step, 0.20) }
            }

        case .hatOpen:
            put(14, style == .halftime ? 0.62 : 0.76)
            if style != .halftime { put(6, style == .broken ? 0.50 : 0.34) }

        case .clap:
            if style == .halftime { put(8, 0.82) }
            else { put(4, 0.58); put(12, 0.78) }

        case .rim:
            // Side-stick answers occupy known offbeats, never arbitrary slots.
            if style == .halftime { put(6, 0.38); put(14, 0.48) }
            else { put(6, 0.30); put(14, 0.44) }

        default:
            // Toms are reserved for fills; extended-kit tracks are placed by
            // `extendedPercussion`. No authored per-step profile here.
            break
        }
        return weights
    }

    /// At most one optional hit in a role receives a 2- or 4-bar condition.
    /// The backbeat and hat pulse are never conditional.
    static func conditions(track: DrumTrack, len: Int, profileSeed: UInt64,
                           style: GrooveStyle = .straight) -> [Int: (a: Int, b: Int)] {
        guard [.kick, .snare, .clap, .rim, .hatOpen].contains(track) else { return [:] }
        let structural = backbone(track: track, style: style)
        let weights = profile(track: track, len: len, subSeed: profileSeed, style: style)
        let candidates = weights.indices.filter { weights[$0] > 0 && !structural.contains($0) }
        guard !candidates.isEmpty else { return [:] }
        var rng = RNG(seed: hashSeed(profileSeed, 0x434F_4E44, UInt64(track.rawValue)))
        let slot = candidates[rng.int(candidates.count)]
        let cycle = rng.chance(0.35) ? 2 : 4
        return [slot: (rng.int(cycle), cycle)]
    }

    /// Kept public to the test target and useful for future percussion modes.
    static func euclideanMask(pulses: Int, steps: Int, rotation: Int) -> [Bool] {
        guard pulses > 0, steps > 0 else { return [Bool](repeating: false, count: max(0, steps)) }
        var mask = [Bool](repeating: false, count: steps)
        for i in 0..<min(pulses, steps) {
            mask[(i * steps / pulses + rotation) % steps] = true
        }
        return mask
    }

    /// Parts arrive in a legible order: hats, kick, snare, then clap. Toms do
    /// not idle in the groove; they enter only as phrases approach a boundary.
    static func trackLevel(_ track: DrumTrack, presence: Double) -> Double {
        switch track {
        // Hats enter close to the kick, not well before it — a long groove of
        // hats with no kick sounds wrong, so the hats-only window is tiny.
        case .hat:     return smoothstep01((presence - 0.26) / 0.20)
        case .hatOpen: return smoothstep01((presence - 0.34) / 0.25)
        case .kick:    return smoothstep01((presence - 0.30) / 0.22)
        case .snare:   return smoothstep01((presence - 0.47) / 0.24)
        case .clap:    return smoothstep01((presence - 0.64) / 0.22)
        case .rim:     return smoothstep01((presence - 0.22) / 0.34)
        // Extended-kit tracks are placed by `extendedPercussion`, not the core
        // loop, so they contribute no ladder level here.
        default:       return 0
        }
    }

    /// Generate one 4/4 bar in sixteenth-note steps.
    public static func generate(bar: Int, params: ParamSet, subSeed: UInt64,
                                profileSeed: UInt64, feel: Feel, fill: Double,
                                tension: Double, presence: Double,
                                nextPresence: Double, anchors: [Int],
                                accentDownbeat: Bool = false,
                                friction: Double = 0,
                                styleOverride: GrooveStyle? = nil) -> [NoteEvent] {
        let density = params["density"]     // hats lane
        let punch = params["punch"]         // big drums: kick / snare / clap decoration
        let perc = params["perc"]           // percs / effects lane
        let swing = params["swing"]
        let ghost = params["ghost"]
        let ratchet = params["ratchet"]
        let humanize = params["humanize"]
        let fills = params["fills"]
        let poly = params["poly"]
        let dynamics = params["dynamics"]
        let kit = params["kit"]   // 0 = core kit only; 1 = the full 16-pad rack
        let grooveStyle = style(profileSeed: profileSeed, override: styleOverride)
        let effectiveSwing = grooveStyle == .halftime ? min(1, swing + 0.18) : swing
        let falling = nextPresence < presence - 0.01
        let rising = min(1, max(0, (nextPresence - presence) * 4))
        // Preserve real headroom between the low side-stick texture and a
        // peak kit. The wider ramp matters now that form profiles can spend
        // different proportions of a peak on hats versus backbeat hits.
        let globalVelocity = Dynamics.scaled(0.74 + tension * 0.42, amount: dynamics)
            * (0.70 + 0.30 * presence) * (falling ? 0.90 : 1)

        var lengthRNG = RNG(seed: hashSeed(subSeed, 0x5245_434C))
        let recurrenceBars = [2, 4, 8][lengthRNG.int(3)]
        var recurrenceRNG = RNG(seed: hashSeed(subSeed, 0x5245_4355, UInt64(bar)))
        let patternBar = recurrenceRNG.chance(params["recur"]) ? bar % recurrenceBars : bar

        var events: [NoteEvent] = []
        func appendHit(track: DrumTrack, step: Double, velocity: Int,
                       duration: Double = 0.8, swingOffset: Double = 0) {
            var event = NoteEvent(voice: .drums, note: track.note,
                                  velocity: min(127, max(1, velocity)),
                                  startStep: step, durationSteps: duration,
                                  timingOffset: swingOffset)
            feel.apply(to: &event,
                       absoluteStep: Double(bar * stepsPerBar) + step,
                       amount: humanize)
            events.append(event)
        }

        // In the valley, silence is more useful than a cloud of unnamed
        // percussion. A seeded side-stick answer supplies at most one clear
        // landmark, or two when announcing the kit's arrival.
        if presence < 0.25 {
            var textureRNG = RNG(seed: hashSeed(subSeed, 0x5445_5854, UInt64(patternBar)))
            let entering = nextPresence >= 0.35
            if entering {
                appendHit(track: .rim, step: 12, velocity: 35)
                appendHit(track: .rim, step: 14, velocity: 43,
                          swingOffset: effectiveSwing * 0.45)
            } else if (bar + textureRNG.int(4)) % 2 == 0
                        && textureRNG.chance(0.18 + density * 0.24 + tension * 0.12) {
                let step = textureRNG.chance(0.5) ? 6 : 14
                appendHit(track: .rim, step: Double(step),
                          velocity: Int(textureRNG.range(24, 42)),
                          swingOffset: effectiveSwing * 0.45)
            }
            return events
        }

        let activeTracks: [DrumTrack] = [.kick, .snare, .hat, .hatOpen, .clap, .rim]
        for track in activeTracks {
            let level = trackLevel(track, presence: presence)
            guard level > 0 else { continue }
            let len = effectiveLoopLength(track, poly: poly)
            let weights = profile(track: track, len: len, subSeed: profileSeed,
                                  style: grooveStyle)
            let conditioned = conditions(track: track, len: len, profileSeed: profileSeed,
                                         style: grooveStyle)
            let structural = backbone(track: track, style: grooveStyle)

            for step in 0..<stepsPerBar {
                let patternStep = patternBar * stepsPerBar + step
                let slot = patternStep % len
                let weight = weights[slot]
                guard weight > 0 else { continue }
                var rng = RNG(seed: hashSeed(subSeed, 0x4452, UInt64(track.rawValue),
                                             UInt64(patternStep)))
                let isBackbone = structural.contains(step)
                let isQuarterHat = track == .hat && step % 4 == 0
                let isEighthHat = track == .hat && step % 2 == 0
                let isGhostSnare = track == .snare && weight < 0.4 && !isBackbone

                // Each density lane is a smooth multiplier that reaches zero at
                // slider 0 and is barely there at low values (calibrated like
                // presence): `skins` (punch) ramps the kick/snare/clap, `hats`
                // (density) ramps the timekeepers. Structural hits use a quick
                // ramp so a moderate setting is already solid.
                let skinsAmt = min(1, punch * 1.5)
                let hatsAmt = min(1, density * 1.5)
                var probability: Double
                if isBackbone {
                    probability = (level >= 0.98 ? 1 : level) * skinsAmt
                } else if isQuarterHat {
                    probability = (level >= 0.98 ? 1 : level) * hatsAmt
                } else if isEighthHat {
                    probability = density * 0.92 * level
                } else if isGhostSnare {
                    probability = ghost * punch * 0.5 * level
                } else if track == .hat {
                    probability = weight * density * 0.55 * level
                } else if track == .hatOpen {
                    probability = weight * density * 0.82 * level
                } else if track == .clap {
                    probability = weight * punch * 0.72 * level
                } else if track == .rim {
                    probability = weight * (0.12 + ghost * 0.38 + rising * 0.20) * level
                } else {
                    // Kick / snare optional decoration beyond the fixed backbone.
                    probability = weight * punch * level
                }
                if (track == .kick || track == .snare) && anchors.contains(step) {
                    probability = min(1, probability * 1.08)
                }
                if let condition = conditioned[slot], bar % condition.b != condition.a {
                    probability = 0
                }
                guard rng.chance(min(1, probability)) else { continue }

                var velocity: Double
                switch track {
                case .kick:
                    velocity = isBackbone ? 104 : 78
                case .snare:
                    velocity = isBackbone ? 103 : (isGhostSnare ? 34 : 72)
                case .hat:
                    velocity = isQuarterHat ? 72 : (isEighthHat ? 61 : 44)
                case .hatOpen:
                    velocity = 78
                case .clap:
                    velocity = 70
                case .rim:
                    velocity = 47
                default:
                    velocity = 70
                }
                // A part entering below its ladder rung whispers before it
                // reaches full weight; a rare early hit must not jump out.
                // Timekeepers (hats) get a much wider velocity spread so they
                // breathe with life instead of machine-gunning at one level.
                let jitter = (track == .hat || track == .hatOpen)
                    ? rng.range(-14, 10) : rng.range(-4, 4)
                velocity = (velocity + jitter) * globalVelocity
                    * (0.35 + 0.65 * level)
                if isBackbone { velocity *= Dynamics.scaled(1.08, amount: dynamics) }

                // Swing the timekeepers and quiet pickups, not the kick
                // backbone; the kick remains the timing reference.
                let swingEligible = track == .hat || track == .hatOpen || track == .rim
                    || (track == .snare && !isBackbone)
                let swingOffset = step % 4 == 2 && swingEligible ? effectiveSwing * 0.55 : 0
                let rollChance = ratchet * (0.025 + fill * 0.28 + tension * 0.04)
                let mayRoll = track == .hat || (track == .snare && fill > 0.55)
                if mayRoll && rng.chance(rollChance) {
                    let count = fill > 0.75 && rng.chance(0.4) ? 3 : 2
                    for index in 0..<count {
                        appendHit(track: track,
                                  step: Double(step) + Double(index) / Double(count),
                                  velocity: Int(velocity) - index * 6,
                                  duration: 0.7 / Double(count),
                                  swingOffset: swingOffset)
                    }
                } else {
                    // An open hat replaces, rather than doubles, a closed hat
                    // already written on the same grid point.
                    if track == .hatOpen {
                        events.removeAll {
                            $0.note == DrumTrack.hat.note && Int($0.startStep) == step
                        }
                    }
                    appendHit(track: track, step: Double(step), velocity: Int(velocity),
                              duration: track == .hatOpen ? 1.8 : 0.8,
                              swingOffset: swingOffset)
                }
            }
        }

        // Section fills are short authored gestures. A seed chooses the
        // gesture, while the fill knob chooses how much of it survives.
        let entering = presence < 0.35 && nextPresence >= 0.35
        let fillAmount = entering ? max(fill, 0.45) : fill
        if fillAmount > 0.4 && (presence >= 0.5 || entering) {
            var fillRNG = RNG(seed: hashSeed(subSeed, 0x4649_4C4C, UInt64(bar)))
            let gestures: [[(Int, DrumTrack)]] = [
                [(12, .snare), (14, .snare), (15, .snare)],
                [(10, .perc), (12, .glitch), (14, .snare), (15, .snare)],
                [(12, .snare), (13, .perc), (14, .glitch), (15, .snare)],
                // Descending tom fill across the full tom range (47→45→43→41).
                [(11, .tomHi), (12, .perc), (13, .glitch), (14, .tomLo), (15, .snare)],
                [(12, .tomHi), (13, .perc), (14, .tomLo), (15, .snare)],
            ]
            let gesture = entering ? [(12, DrumTrack.rim), (14, .rim)]
                                   : gestures[fillRNG.int(gestures.count)]
            let firstStep = gesture.first?.0 ?? 12
            let fillNotes = Set([DrumTrack.snare.note, DrumTrack.rim.note,
                                 DrumTrack.perc.note, DrumTrack.glitch.note])
            events.removeAll { fillNotes.contains($0.note) && $0.startStep >= Double(firstStep) }
            for (index, item) in gesture.enumerated() {
                let keep = index == 0 || fillRNG.chance(0.40 + fills * 0.60)
                guard keep else { continue }
                let progress = Double(index) / Double(max(1, gesture.count - 1))
                let velocity = entering ? 38 + index * 8
                    : Int(64 + progress * (30 + dynamics * 16) + fillRNG.range(-3, 3))
                appendHit(track: item.1, step: Double(item.0), velocity: velocity)
            }
        }

        // Phrase-scale fractures. A groove establishes itself for several
        // bars before one deliberate edit bends it. `friction` (the global
        // grit macro) controls frequency and severity; zero leaves the clean
        // standard-kit grammar untouched.
        if friction > 0.05, presence >= 0.55 {
            let phase = ((bar % 8) + 8) % 8
            let boundary = phase == 3 || phase == 7
                || (friction > 0.72 && phase == 5)
            var editRNG = RNG(seed: hashSeed(profileSeed, 0x4652_4143,
                                             UInt64(max(0, bar / 2))))
            let chance = min(0.95, 0.20 + friction * 0.72 + tension * 0.10)
            if boundary && editRNG.chance(chance) {
                switch editRNG.int(5) {
                case 0:
                    // Negative space: beat three vanishes, making the final
                    // beat and next downbeat feel much larger.
                    events.removeAll { $0.startStep >= 8 && $0.startStep < 12
                        && $0.note != DrumTrack.snare.note }

                case 1:
                    // Displace the second kick, never the anchoring downbeat.
                    if let index = events.indices.last(where: {
                        events[$0].note == DrumTrack.kick.note && events[$0].startStep > 0
                    }) {
                        let direction = editRNG.chance(0.5) ? -1.0 : 1.0
                        events[index].startStep = min(15, max(1, events[index].startStep + direction))
                        events[index].velocity = min(118, events[index].velocity + 8)
                    }

                case 2:
                    // Compress the final beat into a short closed-hat burst.
                    events.removeAll { $0.note == DrumTrack.hat.note && $0.startStep >= 12 }
                    let count = friction > 0.65 ? 6 : 4
                    for index in 0..<count {
                        let step = 12.0 + Double(index) * 4.0 / Double(count)
                        appendHit(track: .hat, step: step,
                                  velocity: 76 - index * 5,
                                  duration: 0.42)
                    }

                case 3:
                    // A backbeat flam: quiet anticipation, main hit, short
                    // after-image. It reads as one gesture, not three dice.
                    let target = grooveStyle == .halftime ? 8.0 : 12.0
                    events.removeAll { $0.note == DrumTrack.snare.note
                        && abs($0.startStep - target) < 0.6 }
                    appendHit(track: .snare, step: target - 0.38, velocity: 40,
                              duration: 0.28)
                    appendHit(track: .snare, step: target, velocity: 106)
                    appendHit(track: .snare, step: target + 0.24, velocity: 54,
                              duration: 0.3)

                default:
                    // A compact descending tom answer, reserved for the end
                    // of the phrase so it retains meaning as a fill.
                    let fillNotes = Set([DrumTrack.snare.note, DrumTrack.rim.note,
                                         DrumTrack.perc.note, DrumTrack.glitch.note])
                    events.removeAll { fillNotes.contains($0.note) && $0.startStep >= 12 }
                    appendHit(track: .perc, step: 12, velocity: 78)
                    appendHit(track: .glitch, step: 13.5, velocity: 86)
                    appendHit(track: .snare, step: 15, velocity: 104)
                }
            }
        }

        // Wider kit: the `kit` control layers in the rest of the 16-pad rack —
        // a shaker texture first, then the top row (ride, one-shots) as the
        // piece opens up. kit == 0 leaves the core grammar above untouched. All
        // seeded, and gated by presence/tension so it fits the tune.
        if kit > 0.02 && presence >= 0.3 {
            var krng = RNG(seed: hashSeed(subSeed, 0x4B49_5442, UInt64(patternBar))) // "KITB"

            // Shaker (pad 44): a quiet texture, the first extra in. Sparse and
            // velocity-varied so it reads as a live shaker, not a metronome.
            // Sixteenths only when the kit is wide AND there is real energy.
            if kit >= 0.12 {
                let stepBy = (kit > 0.72 && perc + tension > 1.15) ? 1 : 2
                let amount = min(1, (kit - 0.12) / 0.5)
                for step in stride(from: 0, to: 16, by: stepBy) {
                    let off = step % 4 != 0
                    // Lean onto the offbeats and mostly stay off the on-beat
                    // eighths, so it reads as a shaker feel rather than a steady
                    // eighth-note run. The perc lane reaches zero at slider 0.
                    let p = (off ? 0.34 : 0.07) * amount * min(1, perc * 1.4)
                    guard krng.chance(p) else { continue }
                    let sw = step % 2 == 1 ? effectiveSwing * 0.5 : 0
                    // Offbeat lean plus real jitter — never a flat line.
                    let base = (off ? 32.0 : 22.0) + krng.range(-9, 13)
                    let v = Int(max(7, base * globalVelocity * (0.55 + 0.45 * min(1, kit))))
                    appendHit(track: .shaker, step: Double(step), velocity: v,
                              duration: 0.3, swingOffset: sw)
                }
            }

            // Ride (pad 51): at a peak the kit opens up — ride the eighths,
            // accent the beats, and let it replace the closed hat. Seeded so it
            // is not every peak bar.
            if kit >= 0.4, tension >= 0.62, presence >= 0.72,
               krng.chance(0.45 + kit * 0.4) {
                events.removeAll { $0.note == DrumTrack.hat.note }
                for step in stride(from: 0, to: 16, by: 2) {
                    let beat = step % 4 == 0
                    appendHit(track: .ride, step: Double(step),
                              velocity: Int((beat ? 66 : 48) * globalVelocity),
                              duration: 0.5,
                              swingOffset: step % 4 == 2 ? effectiveSwing * 0.55 : 0)
                }
            }

            // Percussion figures: a different authored gesture each time it
            // fires — varied pads, placement and dynamics — so a wide kit keeps
            // developing instead of repeating one shaker line. Seeded per bar.
            if kit >= 0.35, presence >= 0.5 {
                // Seed on the pattern bar so a déjà-vu loop repeats its figures.
                var frng = RNG(seed: hashSeed(subSeed, 0x5046_4947, UInt64(patternBar))) // "PFIG"
                let gv = globalVelocity
                func perch(_ t: DrumTrack, _ step: Double, _ v: Double, _ dur: Double = 0.4) {
                    appendHit(track: t, step: step, velocity: Int(max(6, v * gv)), duration: dur)
                }
                // Rule-respecting variety only: cymbal / one-shot / rim / accent
                // pads. Toms stay reserved for fills — no scattered congas.
                if frng.chance(min(0.8, (0.10 + kit * 0.28) * min(1, perc * 1.4))) {
                    switch frng.int(5) {
                    case 0:
                        // One or two top-pad stabs on syncopations.
                        let slots = [3, 7, 10, 11, 14, 15]
                        for _ in 0..<(1 + frng.int(2)) {
                            perch(frng.chance(0.5) ? .oneShot : .oneShotHi,
                                  Double(slots[frng.int(slots.count)]),
                                  46 + frng.range(-12, 22), 0.5)
                        }
                    case 1:
                        // Shaker sixteenth flourish into the next downbeat.
                        for i in 0..<4 {
                            perch(.shaker, 12.0 + Double(i), 24 + Double(i) * 6 + frng.range(-6, 8), 0.22)
                        }
                    case 2:
                        // Rim clave (3-2 or 2-3 son) — side-stick, quiet.
                        for s in (frng.chance(0.5) ? [0, 3, 6, 10, 12] : [2, 4, 8, 11, 14])
                        where frng.chance(0.75) {
                            perch(.rim, Double(s), 40 + frng.range(-6, 12), 0.3)
                        }
                    case 3:
                        // An accent-pad answer on a backbeat offbeat.
                        perch(.accent, frng.chance(0.5) ? 6 : 14, 52 + frng.range(-8, 16), 0.35)
                    default:
                        // Off-kilter top-pad ostinato — a 3-against-4 lean.
                        for k in 0..<3 {
                            let s = k * 3 + frng.int(2)
                            if s < 16 { perch(.oneShotHi, Double(s), 40 + frng.range(-10, 16), 0.35) }
                        }
                    }
                }
            }
        }

        // Cadence/phrase downbeat: one decisive kick and cymbal opening. The
        // open hat replaces a closed hat so a normal choke group behaves too.
        if accentDownbeat {
            if let index = events.firstIndex(where: {
                $0.note == DrumTrack.kick.note && $0.startStep == 0
            }) {
                events[index].velocity = max(events[index].velocity, 116)
            } else {
                appendHit(track: .kick, step: 0, velocity: 116)
            }
            events.removeAll { $0.note == DrumTrack.hat.note && Int($0.startStep) == 0 }
            if !events.contains(where: {
                $0.note == DrumTrack.hatOpen.note && $0.startStep == 0
            }) {
                appendHit(track: .hatOpen, step: 0, velocity: 92, duration: 2)
            }
            // A wider kit crashes the arrival (top-row cymbal).
            if kit >= 0.3 {
                appendHit(track: .crash, step: 0, velocity: 102, duration: 3)
            }
        }
        return events
    }
}
