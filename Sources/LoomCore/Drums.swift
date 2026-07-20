import Foundation

/// A kit player built on **authored, documented grooves** (see `DrumPatterns`).
/// Each bar draws its hits from a real pattern whose kick+snare core is fixed;
/// the arrangement (presence / section) peels the optional layers in a musical
/// order and the density sliders scale how much of each survives. The drums are
/// a foundation the other voices can trust — supportive, never the lead.
public struct DrumGenerator {
    /// Target loop lengths at maximum `poly`, kept for the Orbit visualisation.
    /// Core generation now uses the 16-step authored patterns directly.
    static let loopLengths: [DrumTrack: Int] = [
        .kick: 16, .snare: 16, .hat: 16, .hatOpen: 16, .clap: 16,
        .rim: 12, .perc: 15, .glitch: 13,
    ]

    public static func effectiveLoopLength(_ track: DrumTrack, poly: Double) -> Int {
        let target = loopLengths[track] ?? 16
        guard target != 16, poly > 0.65 else { return 16 }
        let t = min(1, (poly - 0.65) / 0.35)
        return max(4, 16 + Int((Double(target - 16) * t).rounded()))
    }

    /// Legacy feel selector, retained for the snapshot's groove label and the
    /// existing override hook. Genres now carry their own feel; this maps to one.
    public enum GrooveStyle: String, CaseIterable, Codable, Hashable, Sendable {
        case straight, halftime, broken
    }

    public static func style(profileSeed: UInt64, override: GrooveStyle? = nil) -> GrooveStyle {
        if let override { return override }
        var rng = RNG(seed: hashSeed(profileSeed, 0x5354_594C))
        return [GrooveStyle.straight, .halftime, .broken][rng.pick([0.52, 0.38, 0.10])]
    }

    /// Kept public for future percussion modes / tests.
    static func euclideanMask(pulses: Int, steps: Int, rotation: Int) -> [Bool] {
        guard pulses > 0, steps > 0 else { return [Bool](repeating: false, count: max(0, steps)) }
        var mask = [Bool](repeating: false, count: steps)
        for i in 0..<min(pulses, steps) {
            mask[(i * steps / pulses + rotation) % steps] = true
        }
        return mask
    }

    /// Generate one 4/4 bar in sixteenth-note steps.
    public static func generate(bar: Int, params: ParamSet, subSeed: UInt64,
                                profileSeed: UInt64, feel: Feel, fill: Double,
                                tension: Double, presence: Double,
                                nextPresence: Double, anchors: [Int],
                                accentDownbeat: Bool = false,
                                friction: Double = 0,
                                styleOverride: GrooveStyle? = nil,
                                section: Section = .develop,
                                event: SectionEvent? = nil,
                                buildProgress: Double = 0,
                                dialect: HarmonicDialect = .ambient) -> [NoteEvent] {
        let density = params["density"]     // hats lane
        let punch = params["punch"]         // big drums lane: kick / snare core
        let perc = params["perc"]           // percs / effects lane
        let swing = params["swing"]
        let ghost = params["ghost"]
        let ratchet = params["ratchet"]
        let humanize = params["humanize"]
        let fills = params["fills"]
        let dynamics = params["dynamics"]
        let kit = params["kit"]             // 0 = core kit only; 1 = full 16-pad rack

        let genre = DrumGenre.resolve(control: params["genre"], dialect: dialect,
                                      seed: profileSeed, legacy: styleOverride)
        let pattern = DrumPatternLibrary.pattern(genre: genre, seed: profileSeed)
        let effectiveSwing = pattern.swingsHats
            ? (genre.isHalftime ? min(1, swing + 0.18) : swing)
            : swing * 0.35

        let falling = nextPresence < presence - 0.01
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

        // In the valley, silence underpins better than a percussion cloud. A
        // seeded side-stick answer supplies at most one landmark, or two when
        // announcing the kit's arrival.
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

        // ── The arrangement: which layers play, and how strongly. ────────────
        let L = DrumLayers.compute(presence: presence)
        guard L.coreOn else { return events }

        // Density lanes: each reaches zero at slider 0 (lane eliminated) and is
        // barely there at low values. They multiply the arrangement gates, so a
        // layer needs both room in the form and a non-zero slider to sound.
        let skinsAmt = min(1, punch * 1.5)
        let hatsAmt  = min(1, density * 1.5)
        let percAmt  = min(1, perc * 1.4)
        let ghostAmt = min(1, ghost * 1.4)

        // Core kick + snare — the untouchable identity. Eliminated only when the
        // skins lane is at zero; otherwise always present, its loudness scaled by
        // the arrangement so it fades in with the form rather than snapping on.
        if skinsAmt > 0.001 {
            for hit in pattern.core {
                if hit.track == .snare && L.snareGate < 0.05 { continue }
                var v = Double(hit.vel) * globalVelocity * (0.55 + 0.45 * skinsAmt)
                if hit.track == .snare { v *= (0.6 + 0.4 * L.snareGate) }
                else { v *= (0.22 + 0.78 * L.coreGate) }  // kick fades in with the form
                if anchors.contains(Int(hit.step)) { v *= 1.06 }
                v *= Dynamics.scaled(1.05, amount: dynamics)
                appendHit(track: hit.track, step: hit.step, velocity: Int(v))
            }
        }

        // Optional authored layers: keep the top-K most-important hits, where K
        // grows with `gate × amount`. Stable per bar (no re-roll), slider-scaled.
        func emit(_ hits: [DrumHit], gate: Double, amount: Double,
                  swing: Bool, choke: Bool = false, ratchetable: Bool = false) {
            let strength = gate * amount
            guard strength > 0.001, !hits.isEmpty else { return }
            var k = Int((Double(hits.count) * strength).rounded())
            if k == 0 && strength > 0.12 { k = 1 }   // barely-there floor
            guard k > 0 else { return }
            for hit in hits.prefix(k) {
                let v = Double(hit.vel) * globalVelocity * (0.5 + 0.5 * strength)
                let off = swing && Int(hit.step) % 4 == 2 ? effectiveSwing * 0.55 : 0
                if choke {
                    events.removeAll {
                        $0.note == DrumTrack.hat.note && Int($0.startStep) == Int(hit.step)
                    }
                }
                if ratchetable {
                    var rr = RNG(seed: hashSeed(subSeed, 0x5241_5443, UInt64(Int(hit.step))))
                    if rr.chance(ratchet * (0.03 + fill * 0.25)) {
                        let count = fill > 0.7 && rr.chance(0.4) ? 3 : 2
                        for i in 0..<count {
                            appendHit(track: hit.track,
                                      step: hit.step + Double(i) / Double(count),
                                      velocity: Int(v) - i * 6,
                                      duration: 0.6 / Double(count), swingOffset: off)
                        }
                        continue
                    }
                }
                appendHit(track: hit.track, step: hit.step, velocity: Int(max(1, v)),
                          duration: hit.track == .hatOpen || choke ? 1.8 : 0.8,
                          swingOffset: off)
            }
        }

        // Hats: the arrangement caps the finest tier; the slider peels within it.
        let hatsEligible = pattern.hats.filter { $0.tier <= L.hatTierCap }
        emit(hatsEligible, gate: L.eighthGate, amount: hatsAmt,
             swing: pattern.swingsHats, ratchetable: true)
        emit(pattern.ghosts, gate: L.ghostGate, amount: ghostAmt, swing: true)
        emit(pattern.openHats, gate: L.openHatGate, amount: hatsAmt,
             swing: pattern.swingsHats, choke: true)
        emit(pattern.perc, gate: L.percGate, amount: percAmt, swing: pattern.swingsHats)

        // Section fills — short authored gestures at phrase ends. A seed chooses
        // the gesture, the fill knob chooses how much survives. (No EDM snare
        // rush: ambient/downtempo evolves by texture, not by a run-up.)
        let entering = presence < 0.35 && nextPresence >= 0.35
        let fillAmount = entering ? max(fill, 0.45) : fill
        if fillAmount > 0.4 && (presence >= 0.5 || entering) {
            var fillRNG = RNG(seed: hashSeed(subSeed, 0x4649_4C4C, UInt64(bar)))
            let gestures: [[(Int, DrumTrack)]] = [
                [(12, .snare), (14, .snare), (15, .snare)],
                [(10, .perc), (12, .glitch), (14, .snare), (15, .snare)],
                [(12, .snare), (13, .perc), (14, .glitch), (15, .snare)],
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

        // Phrase-scale fractures under the global grit macro. Zero leaves the
        // clean standard-kit grammar untouched.
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
                    events.removeAll { $0.startStep >= 8 && $0.startStep < 12
                        && $0.note != DrumTrack.snare.note }
                case 1:
                    if let index = events.indices.last(where: {
                        events[$0].note == DrumTrack.kick.note && events[$0].startStep > 0
                    }) {
                        let direction = editRNG.chance(0.5) ? -1.0 : 1.0
                        events[index].startStep = min(15, max(1, events[index].startStep + direction))
                        events[index].velocity = min(118, events[index].velocity + 8)
                    }
                case 2:
                    events.removeAll { $0.note == DrumTrack.hat.note && $0.startStep >= 12 }
                    let count = friction > 0.65 ? 6 : 4
                    for index in 0..<count {
                        let step = 12.0 + Double(index) * 4.0 / Double(count)
                        appendHit(track: .hat, step: step,
                                  velocity: 76 - index * 5, duration: 0.42)
                    }
                case 3:
                    let target = genre.isHalftime ? 8.0 : 12.0
                    events.removeAll { $0.note == DrumTrack.snare.note
                        && abs($0.startStep - target) < 0.6 }
                    appendHit(track: .snare, step: target - 0.38, velocity: 40, duration: 0.28)
                    appendHit(track: .snare, step: target, velocity: 106)
                    appendHit(track: .snare, step: target + 0.24, velocity: 54, duration: 0.3)
                default:
                    let fillNotes = Set([DrumTrack.snare.note, DrumTrack.rim.note,
                                         DrumTrack.perc.note, DrumTrack.glitch.note])
                    events.removeAll { fillNotes.contains($0.note) && $0.startStep >= 12 }
                    appendHit(track: .perc, step: 12, velocity: 78)
                    appendHit(track: .glitch, step: 13.5, velocity: 86)
                    appendHit(track: .snare, step: 15, velocity: 104)
                }
            }
        }

        // Wider kit: the `kit` control colours the groove with the rest of the
        // 16-pad rack — but only as a single, sparse accent per bar, never a run.
        // Kick, snare and closed hat are the only things that repeat; everything
        // else here decorates one moment and gets out of the way.
        if kit > 0.02 && presence >= 0.3 && percAmt > 0.001 {
            var krng = RNG(seed: hashSeed(subSeed, 0x4B49_5442, UInt64(patternBar))) // "KITB"
            let gv = globalVelocity
            func perch(_ t: DrumTrack, _ step: Double, _ v: Double, _ dur: Double = 0.4) {
                appendHit(track: t, step: step, velocity: Int(max(6, v * gv)), duration: dur)
            }
            // Occasional, not every bar: one tasteful hit that decorates.
            if krng.chance(min(0.5, (0.08 + kit * 0.22) * percAmt)) {
                switch krng.int(4) {
                case 0:  // a single shaker on an offbeat
                    perch(.shaker, Double([2, 6, 10, 14][krng.int(4)]), 26 + krng.range(-6, 10), 0.3)
                case 1:  // a single ride-bell accent on a beat (wide kits only)
                    if kit >= 0.4 { perch(.ride, Double([4, 8, 12][krng.int(3)]), 42 + krng.range(-8, 14), 0.5) }
                    else { perch(.shaker, 10, 24 + krng.range(-6, 8), 0.3) }
                case 2:  // a one-shot stab on a syncopation
                    perch(krng.chance(0.5) ? .oneShot : .oneShotHi,
                          Double([3, 7, 11, 15][krng.int(4)]), 44 + krng.range(-10, 18), 0.5)
                default: // a side-stick / rim accent answering the backbeat
                    perch(.rim, Double([6, 14][krng.int(2)]), 40 + krng.range(-6, 12), 0.3)
                }
            }
        }

        // A gentle phrase-downbeat lift — a slightly firmer kick and a soft open
        // hat opening. No EDM crash-and-slam; the beat simply settles onto the
        // new phrase.
        if accentDownbeat {
            if let index = events.firstIndex(where: {
                $0.note == DrumTrack.kick.note && $0.startStep == 0
            }) {
                events[index].velocity = max(events[index].velocity, 96)
            } else {
                appendHit(track: .kick, step: 0, velocity: 96)
            }
            if kit >= 0.3 && !events.contains(where: {
                $0.note == DrumTrack.hatOpen.note && $0.startStep == 0
            }) {
                events.removeAll { $0.note == DrumTrack.hat.note && Int($0.startStep) == 0 }
                appendHit(track: .hatOpen, step: 0, velocity: 72, duration: 2)
            }
        }
        return events
    }
}
