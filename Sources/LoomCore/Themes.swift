import Foundation

/// Selects the compositional contract used to turn a seed into notes.
/// Saved performances keep this value so improvements to new pieces never
/// rewrite an older performance's deterministic event stream.
public enum CompositionModelVersion: String, Codable, Sendable {
    case legacy
    case persistentThemes
}

enum ThemeIntervalProfile: String, CaseIterable, Sendable, Hashable {
    case stepwise
    case fourthLed
    case pendular
}

enum ThemeRhythmProfile: String, CaseIterable, Sendable, Hashable {
    case longBreath
    case delayedEntry
    case sparsePulse
}

enum ThemeDevelopment: String, CaseIterable, Sendable, Hashable {
    case fragment
    case augment
    case inversion
    case restatement

    var motifTransform: MotifTransform {
        switch self {
        case .fragment: return .fragment
        case .augment: return .augment
        case .inversion: return .invert
        case .restatement: return .transpose
        }
    }
}

enum ThemeEchoRole: String, CaseIterable, Sendable, Hashable {
    case bass
    case pulse
    case alternating
}

/// Seed-level choices that make one piece behave like itself throughout its
/// key journey. This is deliberately not a user-facing control surface.
struct PieceIdentity: Sendable {
    let themeBars: Int
    let intervalProfile: ThemeIntervalProfile
    let rhythmProfile: ThemeRhythmProfile
    let developmentOrder: [ThemeDevelopment]
    let echoRole: ThemeEchoRole

    init(masterSeed: UInt64, melodySeed: UInt64) {
        var rng = RNG(seed: hashSeed(masterSeed, melodySeed, 0x5049_444E)) // "PIDN"
        themeBars = rng.int(3) == 0 ? 8 : 4
        intervalProfile = ThemeIntervalProfile.allCases[rng.int(ThemeIntervalProfile.allCases.count)]
        rhythmProfile = ThemeRhythmProfile.allCases[rng.int(ThemeRhythmProfile.allCases.count)]
        echoRole = ThemeEchoRole.allCases[rng.int(ThemeEchoRole.allCases.count)]

        var remaining = ThemeDevelopment.allCases
        var order: [ThemeDevelopment] = []
        while !remaining.isEmpty { order.append(remaining.remove(at: rng.int(remaining.count))) }
        developmentOrder = order
    }

    func echoVoice(barInPair: Int) -> Voice {
        switch echoRole {
        case .bass: return .bass
        case .pulse: return .pulse
        case .alternating: return barInPair.isMultiple(of: 2) ? .bass : .pulse
        }
    }
}

enum PhrasePairRole: String, Sendable, Hashable {
    case statement
    case development
    case departure
    case reprise

    static func role(phraseIndex: Int) -> PhrasePairRole {
        switch (max(0, phraseIndex) / 2) % 4 {
        case 0: return .statement
        case 1: return .development
        case 2: return .departure
        default: return .reprise
        }
    }
}

struct ThemeBarPlan: Sendable {
    let cell: MotifCell
    let sourceIndex: Int
    let transform: MotifTransform?
    let role: PhrasePairRole
    let preservesClosingGesture: Bool
}

/// A complete 4- or 8-bar thought in scale-degree space. It is generated once
/// per seed, without harmony or live controls, then re-rooted when realized.
struct ThemeBlueprint: Sendable {
    let identity: PieceIdentity
    let cells: [MotifCell]
    private let seed: UInt64

    init(masterSeed: UInt64, melodySeed: UInt64, identity: PieceIdentity) {
        self.identity = identity
        seed = hashSeed(masterSeed, melodySeed, 0x5448_454D) // "THEM"
        var rng = RNG(seed: seed)
        let peakBar = 1 + rng.int(max(1, identity.themeBars - 2))
        var currentDegree = 0
        var direction = rng.chance(0.5) ? 1 : -1
        var made: [MotifCell] = []

        for bar in 0..<identity.themeBars {
            let rhythm = Self.rhythm(for: identity.rhythmProfile, bar: bar, rng: &rng)
            var notes: [MotifCell.N] = []
            for noteIndex in rhythm.indices {
                if bar == 0 && noteIndex == 0 {
                    currentDegree = 0
                } else if noteIndex == 0 {
                    // Re-articulate the prior bar's last scale degree: even
                    // with a delayed onset, the line crosses the barline as
                    // one thought rather than restarting around degree zero.
                } else {
                    switch identity.intervalProfile {
                    case .stepwise:
                        currentDegree += rng.chance(0.54) ? direction : -direction
                        if rng.chance(0.24) { direction *= -1 }
                    case .fourthLed:
                        if bar == 0 && noteIndex == 1 {
                            currentDegree += direction * 3
                            direction *= -1
                        } else {
                            currentDegree += direction
                            if rng.chance(0.32) { direction *= -1 }
                        }
                    case .pendular:
                        let span = 1 + ((bar + noteIndex) % 3)
                        currentDegree = direction * span
                        direction *= -1
                    }
                }

                let isClimax = bar == peakBar && noteIndex == rhythm.count / 2
                currentDegree = isClimax ? 6 : max(-4, min(4, currentDegree))
                let onset = rhythm[noteIndex]
                let next = noteIndex + 1 < rhythm.count ? rhythm[noteIndex + 1] : 16
                let available = max(0.75, next - onset)
                let duration = min(available * 0.82,
                                   identity.rhythmProfile == .longBreath ? 5.5 : 3.5)
                let velocity = min(0.9, 0.48 + Double(max(0, currentDegree)) * 0.045
                                   + (isClimax ? 0.12 : 0))
                notes.append(.init(step: onset, degree: currentDegree,
                                   dur: duration, vel: velocity))
            }

            // The theme always releases through scale degree 1 to degree 0.
            // That closing fingerprint survives transposition and modulation.
            if bar == identity.themeBars - 1, notes.count >= 2 {
                notes[notes.count - 2].degree = 1
                notes[notes.count - 1].degree = 0
                currentDegree = 0
            }
            made.append(MotifCell(notes: notes, id: 100_000 + bar))
        }
        cells = made
    }

    func plan(for harmony: HarmonyContext) -> ThemeBarPlan? {
        guard harmony.barInPhrasePair >= 0,
              harmony.barInPhrasePair < cells.count else { return nil }
        return renderedPlan(sourceIndex: harmony.barInPhrasePair,
                            role: PhrasePairRole.role(phraseIndex: harmony.phraseIndex),
                            phraseIndex: harmony.phraseIndex)
    }

    /// Once the scheduled statement has finished, ensemble voices may keep
    /// echoing its most recent cell. They receive rhythm only, never pitches.
    func activeOrPreviousCell(for harmony: HarmonyContext) -> MotifCell {
        let index = min(max(0, harmony.barInPhrasePair), cells.count - 1)
        return renderedPlan(sourceIndex: index,
                            role: PhrasePairRole.role(phraseIndex: harmony.phraseIndex),
                            phraseIndex: harmony.phraseIndex).cell
    }

    private func renderedPlan(sourceIndex: Int, role: PhrasePairRole,
                              phraseIndex: Int) -> ThemeBarPlan {
        var index = sourceIndex % cells.count
        var transform: MotifTransform?
        switch role {
        case .statement:
            transform = nil
        case .development:
            transform = identity.developmentOrder[index % identity.developmentOrder.count]
                .motifTransform
        case .departure:
            // The departure quotes recognizable shards out of sequence.
            index = (index + 1 + Int(seed % UInt64(cells.count))) % cells.count
            transform = .fragment
        case .reprise:
            transform = .transpose
        }

        let source = cells[index]
        guard let transform else {
            return ThemeBarPlan(cell: source, sourceIndex: index,
                                transform: nil, role: role,
                                preservesClosingGesture: index == cells.count - 1)
        }
        var rng = RNG(seed: hashSeed(seed, UInt64(max(0, phraseIndex)),
                                     UInt64(index), 0x4445_564C)) // "DEVL"
        return ThemeBarPlan(cell: source.transformed(transform, rng: &rng),
                            sourceIndex: index, transform: transform, role: role,
                            preservesClosingGesture: index == cells.count - 1
                                && transform == .transpose)
    }

    private static func rhythm(for profile: ThemeRhythmProfile, bar: Int,
                               rng: inout RNG) -> [Double] {
        switch profile {
        case .longBreath:
            return bar.isMultiple(of: 2) ? [0, 6, 12] : [0, 5, 11]
        case .delayedEntry:
            return bar.isMultiple(of: 2) ? [3, 8, 13] : [2, 7, 12]
        case .sparsePulse:
            let offset = rng.chance(0.5) ? 0.0 : 2.0
            return [offset, 8 + offset / 2, 13]
        }
    }
}
