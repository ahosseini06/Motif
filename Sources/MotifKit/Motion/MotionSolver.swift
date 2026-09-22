import Foundation

/// One flow measurement. `x, y, u, v` in pixels, origin at the image centre, y down.
/// `inverseDepth` is relative inverse depth normalised to median 1, when a depth map is available.
public struct FlowPoint {
    public var x: Float, y: Float, u: Float, v: Float
    public var inverseDepth: Float?
    public var weight: Float

    public init(x: Float, y: Float, u: Float, v: Float, inverseDepth: Float? = nil, weight: Float = 1) {
        self.x = x; self.y = y; self.u = u; self.v = v; self.inverseDepth = inverseDepth; self.weight = weight
    }
}

/// Per-pair solution in solver variables (radians, log-scale, scene-depths) — see docs/motion-spec.md.
public struct PairSolution {
    public var omega: SIMD3<Double> = .zero     // ωx (tilt), ωy (pan), ωz (roll)
    public var zoom: Double = 0
    public var translation: SIMD3<Double>? = nil
    public var inlierRatio: Double = 0
    public var medianResidual: Double = 0       // px, after the accepted fit
    public var cost: Double = 0
}

public enum MotionSolver {
    /// Rotation + zoom only. RANSAC for a subject-proof start, then IRLS.
    public static func solveRotation(_ pts: [FlowPoint], focal f: Double, seed: UInt64 = 1) -> PairSolution {
        guard pts.count >= 8 else { return PairSolution() }
        var rng = SplitMix(seed: seed)
        var best: [Double] = [0, 0, 0, 0]
        var bestScore = -1.0
        for _ in 0..<160 {
            let a = pts[Int(rng.next() % UInt64(pts.count))], b = pts[Int(rng.next() % UInt64(pts.count))]
            if abs(a.x - b.x) + abs(a.y - b.y) < 40 { continue }
            guard let p = leastSquares([a, b], weights: [1, 1], f: f, withTranslation: false, ridge: 1e-9) else { continue }
            var score = 0.0
            for pt in pts {
                let r = residual(pt, p, f: f)
                if r < inlierThreshold(pt) { score += Double(pt.weight) }
            }
            if score > bestScore { bestScore = score; best = p }
        }
        return refine(pts, start: best, f: f, withTranslation: false)
    }

    /// Rotation + zoom + translation, for points carrying inverse depth. Starts from a rotation-only solution.
    public static func solveJoint(_ pts: [FlowPoint], focal f: Double, start: PairSolution) -> PairSolution {
        let withDepth = pts.filter { $0.inverseDepth != nil }
        guard withDepth.count >= 16 else { return start }
        let p0 = [start.omega.x, start.omega.y, start.omega.z, start.zoom, 0, 0, 0]
        // Under strong parallax the rotation-only fit locks onto one depth layer, and robust weights seeded from it
        // would hide every other layer from the joint fit. So also try from a plain least-squares start; keep the better.
        let seeded = refine(withDepth, start: p0, f: f, withTranslation: true)
        let open = refine(withDepth, start: p0, f: f, withTranslation: true, uniformFirstPass: true)
        return open.cost < seeded.cost ? open : seeded
    }

    // MARK: - internals

    static func inlierThreshold(_ p: FlowPoint) -> Double {
        0.35 + 0.06 * Double((p.u * p.u + p.v * p.v).squareRoot())
    }

    /// Rows of the design matrix for one point, in focal-normalised units.
    @inline(__always)
    static func rows(_ p: FlowPoint, f: Double, withTranslation: Bool) -> ([Double], [Double]) {
        let x = Double(p.x) / f, y = Double(p.y) / f
        var ru = [x * y, -(1 + x * x), y, x]
        var rv = [1 + y * y, -x * y, -x, y]
        if withTranslation {
            let d = Double(p.inverseDepth ?? 1)
            ru += [-d, 0, x * d]
            rv += [0, -d, y * d]
        }
        return (ru, rv)
    }

    static func residual(_ p: FlowPoint, _ params: [Double], f: Double) -> Double {
        let (ru, rv) = rows(p, f: f, withTranslation: params.count == 7)
        var pu = 0.0, pv = 0.0
        for i in 0..<params.count { pu += ru[i] * params[i]; pv += rv[i] * params[i] }
        let du = Double(p.u) - pu * f, dv = Double(p.v) - pv * f
        return (du * du + dv * dv).squareRoot()
    }

    static func leastSquares(_ pts: [FlowPoint], weights: [Double], f: Double,
                             withTranslation: Bool, ridge: Double) -> [Double]? {
        let n = withTranslation ? 7 : 4
        var ata = [Double](repeating: 0, count: n * n), atb = [Double](repeating: 0, count: n)
        for (k, p) in pts.enumerated() {
            let w = weights[k] * Double(p.weight)
            if w <= 0 { continue }
            let (ru, rv) = rows(p, f: f, withTranslation: withTranslation)
            let bu = Double(p.u) / f, bv = Double(p.v) / f
            for i in 0..<n {
                atb[i] += w * (ru[i] * bu + rv[i] * bv)
                for j in i..<n { ata[i * n + j] += w * (ru[i] * ru[j] + rv[i] * rv[j]) }
            }
        }
        var trace = 0.0
        for i in 0..<n { trace += ata[i * n + i] }
        let lambda = ridge * max(trace / Double(n), 1e-12)
        for i in 0..<n {
            // The prior sits on translation only: without parallax, motion is attributed to rotation / zoom.
            ata[i * n + i] += (i >= 4 ? lambda : lambda * 1e-4)
            for j in 0..<i { ata[i * n + j] = ata[j * n + i] }
        }
        return solveLinear(ata, atb, n: n)
    }

    static func refine(_ pts: [FlowPoint], start: [Double], f: Double, withTranslation: Bool,
                       uniformFirstPass: Bool = false) -> PairSolution {
        var params = start
        var weights = [Double](repeating: 1, count: pts.count)
        for pass in 0..<(uniformFirstPass ? 8 : 6) {
            for (k, p) in pts.enumerated() where !(uniformFirstPass && pass == 0) {
                let c = 3 * inlierThreshold(p)                 // Tukey biweight
                let r = residual(p, params, f: f) / c
                weights[k] = r < 1 ? (1 - r * r) * (1 - r * r) : 0
            }
            guard let next = leastSquares(pts, weights: weights, f: f,
                                          withTranslation: withTranslation, ridge: 2e-3) else { break }
            params = next
        }
        var sol = PairSolution()
        sol.omega = SIMD3(params[0], params[1], params[2])
        sol.zoom = params[3]
        if withTranslation { sol.translation = SIMD3(params[4], params[5], params[6]) }
        var residuals: [Double] = [], inlierWeight = 0.0, totalWeight = 0.0, cost = 0.0
        for p in pts {
            let r = residual(p, params, f: f), t = inlierThreshold(p)
            residuals.append(r)
            totalWeight += Double(p.weight)
            if r < t { inlierWeight += Double(p.weight) }
            let c = 3 * t
            cost += Double(p.weight) * min(r * r, c * c)
        }
        residuals.sort()
        sol.medianResidual = residuals[residuals.count / 2]
        sol.inlierRatio = totalWeight > 0 ? inlierWeight / totalWeight : 0
        sol.cost = cost / max(totalWeight, 1)
        return sol
    }

    /// Gaussian elimination with partial pivoting; `a` is n×n row-major.
    static func solveLinear(_ a: [Double], _ b: [Double], n: Int) -> [Double]? {
        var a = a, b = b
        for col in 0..<n {
            var pivot = col
            for r in (col + 1)..<n where abs(a[r * n + col]) > abs(a[pivot * n + col]) { pivot = r }
            if abs(a[pivot * n + col]) < 1e-14 { return nil }
            if pivot != col {
                for c in 0..<n { a.swapAt(col * n + c, pivot * n + c) }
                b.swapAt(col, pivot)
            }
            for r in (col + 1)..<n {
                let m = a[r * n + col] / a[col * n + col]
                if m == 0 { continue }
                for c in col..<n { a[r * n + c] -= m * a[col * n + c] }
                b[r] -= m * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for r in stride(from: n - 1, through: 0, by: -1) {
            var s = b[r]
            for c in (r + 1)..<n { s -= a[r * n + c] * x[c] }
            x[r] = s / a[r * n + r]
        }
        return x
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
