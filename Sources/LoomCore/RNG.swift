import Foundation

/// SplitMix64 — used to expand a seed into stream seeds.
@inlinable public func splitmix64(_ x: inout UInt64) -> UInt64 {
    x &+= 0x9E3779B97F4A7C15
    var z = x
    z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
    z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
    return z ^ (z >> 31)
}

/// Combine values into a derived seed. Used so every (voice, bar, purpose)
/// gets its own deterministic stream from the master seed.
@inlinable public func hashSeed(_ parts: UInt64...) -> UInt64 {
    var h: UInt64 = 0x243F6A8885A308D3
    for p in parts {
        var s = h ^ p
        h = splitmix64(&s)
    }
    return h
}

/// xoshiro256** — fast, high-quality, deterministic PRNG.
public struct RNG: RandomNumberGenerator {
    var s: (UInt64, UInt64, UInt64, UInt64)

    public init(seed: UInt64) {
        var sm = seed
        s = (splitmix64(&sm), splitmix64(&sm), splitmix64(&sm), splitmix64(&sm))
    }

    @inlinable static func rotl(_ x: UInt64, _ k: UInt64) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }

    public mutating func next() -> UInt64 {
        let result = RNG.rotl(s.1 &* 5, 7) &* 9
        let t = s.1 << 17
        s.2 ^= s.0
        s.3 ^= s.1
        s.1 ^= s.2
        s.0 ^= s.3
        s.2 ^= t
        s.3 = RNG.rotl(s.3, 45)
        return result
    }

    /// Uniform in [0, 1).
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9007199254740992.0)
    }

    /// Uniform in [lo, hi).
    public mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + unit() * (hi - lo)
    }

    /// Bernoulli trial.
    public mutating func chance(_ p: Double) -> Bool {
        unit() < p
    }

    /// Uniform integer in 0..<n (n > 0).
    public mutating func int(_ n: Int) -> Int {
        Int(next() % UInt64(n))
    }

    /// Weighted pick; weights need not be normalized.
    public mutating func pick(_ weights: [Double]) -> Int {
        let total = weights.reduce(0, +)
        guard total > 0 else { return 0 }
        var r = unit() * total
        for (i, w) in weights.enumerated() {
            r -= w
            if r < 0 { return i }
        }
        return weights.count - 1
    }
}

/// Deterministic, randomly accessible 1D value noise in [-1, 1].
/// Smoothly interpolated seeded lattice noise — this is how "bounded random
/// walk" and "1/f drift" sources are realized so that any point in time can
/// be evaluated without stepping from t = 0 (which is what makes a saved
/// seed replay an entire evolving performance).
public struct ValueNoise {
    let seed: UInt64

    public init(seed: UInt64) { self.seed = seed }

    func lattice(_ i: Int64) -> Double {
        var s = hashSeed(seed, UInt64(bitPattern: i))
        let v = splitmix64(&s)
        return Double(v >> 11) * (2.0 / 9007199254740992.0) - 1.0
    }

    /// Smooth noise at time t (one lattice unit per unit of t).
    public func value(_ t: Double) -> Double {
        let i = Int64(t.rounded(.down))
        let f = t - Double(i)
        let u = f * f * (3 - 2 * f) // smoothstep
        return lattice(i) * (1 - u) + lattice(i + 1) * u
    }

    /// Fractal (pink-ish, 1/f) noise: several octaves of value noise.
    public func fractal(_ t: Double, octaves: Int = 4) -> Double {
        var sum = 0.0, amp = 1.0, freq = 1.0, norm = 0.0
        for o in 0..<octaves {
            let n = ValueNoise(seed: hashSeed(seed, UInt64(o) &+ 101))
            sum += n.value(t * freq) * amp
            norm += amp
            amp *= 0.5
            freq *= 2.0
        }
        return sum / norm
    }
}
