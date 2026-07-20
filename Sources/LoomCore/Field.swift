import Foundation

/// The field: a Gray-Scott reaction-diffusion simulation — simple local
/// rules, emergent non-repeating global structure. It is stepped a fixed
/// number of iterations per bar on the generation thread (deterministic when
/// replayed from bar 0 with the same seed) and sampled at probe points to
/// yield modulation streams. It doubles as the visual signature (the `field`
/// scope in the UI reads `grid` directly).
///
/// The design doc calls for a Metal compute shader; at 48×48 with a handful
/// of iterations per bar the CPU version is microscopic work and keeps the
/// engine dependency-free. The sampling interface is the contract — a Metal
/// implementation can replace this struct without touching anything else.
public final class Field {
    public static let size = 48
    /// Concentration of chemical V (the pattern-forming one), row-major.
    public private(set) var grid: [Float]
    private var u: [Float]
    private var v: [Float]
    private let seed: UInt64

    // Gray-Scott parameters in the "solitons / worms" regime.
    private let feed: Float = 0.037
    private let kill: Float = 0.06
    private let du: Float = 0.21
    private let dv: Float = 0.105

    public init(seed: UInt64) {
        self.seed = seed
        let n = Field.size * Field.size
        u = [Float](repeating: 1, count: n)
        v = [Float](repeating: 0, count: n)
        grid = v
        reset()
    }

    public func reset() {
        let n = Field.size * Field.size
        u = [Float](repeating: 1, count: n)
        v = [Float](repeating: 0, count: n)
        var rng = RNG(seed: hashSeed(seed, 0x4649_454C_44))
        // Seed a few random blobs of V.
        for _ in 0..<8 {
            let cx = rng.int(Field.size), cy = rng.int(Field.size)
            for dy in -2...2 {
                for dx in -2...2 {
                    let x = (cx + dx + Field.size) % Field.size
                    let y = (cy + dy + Field.size) % Field.size
                    v[y * Field.size + x] = 0.9
                    u[y * Field.size + x] = 0.3
                }
            }
        }
        // Warm up so probes see structure immediately.
        step(iterations: 200)
    }

    public func step(iterations: Int) {
        let s = Field.size
        var nu = u, nv = v
        for _ in 0..<iterations {
            for y in 0..<s {
                let ym = ((y - 1 + s) % s) * s, yp = ((y + 1) % s) * s, y0 = y * s
                for x in 0..<s {
                    let xm = (x - 1 + s) % s, xp = (x + 1) % s
                    let i = y0 + x
                    let lapU = u[ym + x] + u[yp + x] + u[y0 + xm] + u[y0 + xp] - 4 * u[i]
                    let lapV = v[ym + x] + v[yp + x] + v[y0 + xm] + v[y0 + xp] - 4 * v[i]
                    let uv2 = u[i] * v[i] * v[i]
                    nu[i] = u[i] + du * lapU - uv2 + feed * (1 - u[i])
                    nv[i] = v[i] + dv * lapV + uv2 - (feed + kill) * v[i]
                }
            }
            swap(&u, &nu)
            swap(&v, &nv)
        }
        grid = v
    }

    /// Sample at a probe point (normalized coordinates), bilinear, → [-1, 1].
    public func sample(x: Double, y: Double) -> Double {
        let s = Field.size
        let fx = x.truncatingRemainder(dividingBy: 1) * Double(s)
        let fy = y.truncatingRemainder(dividingBy: 1) * Double(s)
        let x0 = Int(fx) % s, y0 = Int(fy) % s
        let x1 = (x0 + 1) % s, y1 = (y0 + 1) % s
        let tx = Float(fx - fx.rounded(.down)), ty = Float(fy - fy.rounded(.down))
        let a = grid[y0 * s + x0] * (1 - tx) + grid[y0 * s + x1] * tx
        let b = grid[y1 * s + x0] * (1 - tx) + grid[y1 * s + x1] * tx
        let val = a * (1 - ty) + b * ty
        // V lives roughly in 0...0.4 in this regime; normalize to [-1, 1].
        return Double(min(1, max(-1, val * 5 - 1)))
    }
}
