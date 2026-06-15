import Foundation

// MARK: - Forecast line (one per oref type, or the cone min/max)

/// A single forecast series compressed into a polynomial.
/// The polynomial evaluates as:
///   y = coefficients[0] + coefficients[1]*t + coefficients[2]*t² + …
/// where `t` is **minutes** elapsed since `startDate`.
/// The polynomial is valid for `t` in [0, endMinutes].
struct WatchForecastPolynomial: Codable, Equatable, Hashable {
    /// oref forecast type tag, e.g. "UAM", "ZT", "IOB", "COB".
    /// Empty string for the cone min/max series.
    var type: String

    /// Polynomial coefficients in ascending order of degree.
    var coefficients: [Double]

    /// Absolute start time of the first forecast point (== determination.deliverAt).
    var startDate: Date

    /// Duration covered by the polynomial in minutes (= (pointCount - 1) * 5).
    var endMinutes: Double

    /// Number of original 5-minute data points that were fitted.
    var pointCount: Int

    // MARK: Evaluate

    /// Returns the predicted glucose value at `minutesFromStart` minutes after `startDate`.
    func evaluate(at minutesFromStart: Double) -> Double {
        coefficients.enumerated().reduce(0.0) { acc, pair in
            acc + pair.element * pow(minutesFromStart, Double(pair.offset))
        }
    }

    /// Convenience: evaluate at a wall-clock `date`.
    func evaluate(at date: Date) -> Double {
        let t = date.timeIntervalSince(startDate) / 60.0
        return evaluate(at: t)
    }
}

// MARK: - Container sent in WatchState

struct WatchForecastData: Codable, Equatable, Hashable {
    /// One compressed line per oref forecast type (UAM, ZT, IOB, COB, …).
    var forecastLines: [WatchForecastPolynomial]

    /// Cone lower-bound polynomial (min across all types at each step).
    var coneMin: WatchForecastPolynomial?

    /// Cone upper-bound polynomial (max across all types at each step).
    var coneMax: WatchForecastPolynomial?

    /// When true the watch should render the cone (coneMin/coneMax).
    /// When false it should render the individual `forecastLines`.
    var showCone: Bool

    var isEmpty: Bool { forecastLines.isEmpty && coneMin == nil }
}

// MARK: - Polynomial least-squares fitting

enum PolynomialFitter {
    /// Fit a polynomial of the given `degree` (clamped to `min(degree, n-1)`)
    /// through `values`, where each successive value is `intervalMinutes` apart.
    ///
    /// Returns coefficients `[a0, a1, a2, …]` such that the fit minimises
    /// the sum of squared residuals.  `t` is in minutes.
    static func fit(values: [Double], degree: Int, intervalMinutes: Double = 5.0) -> [Double] {
        let n = values.count
        guard n >= 1 else { return [] }
        let d = min(degree, n - 1) // can't over-fit

        // Build Vandermonde matrix X  (n rows × (d+1) cols)
        let cols = d + 1
        var X = [Double](repeating: 0, count: n * cols)
        for i in 0 ..< n {
            let t = Double(i) * intervalMinutes
            for j in 0 ..< cols {
                X[i * cols + j] = pow(t, Double(j))
            }
        }

        // Normal equations: (Xᵀ X) · c = Xᵀ · y
        let XtX = matMul(
            transposeMatrix(X, rows: n, cols: cols),
            rows: cols,
            cols: n,
            rhs: X,
            rhsCols: cols
        )
        let Xty = matVecMul(
            transposeMatrix(X, rows: n, cols: cols),
            rows: cols,
            cols: n,
            vec: values
        )

        return gaussianElimination(A: XtX, size: cols, b: Xty) ?? [Double](repeating: 0, count: cols)
    }

    // MARK: – Matrix helpers (row-major, flat arrays)

    private static func transposeMatrix(_ M: [Double], rows: Int, cols: Int) -> [Double] {
        var T = [Double](repeating: 0, count: rows * cols)
        for r in 0 ..< rows {
            for c in 0 ..< cols {
                T[c * rows + r] = M[r * cols + c]
            }
        }
        return T
    }

    /// Multiplies (aRows × aCols) · (aCols × bCols).  `b` is the original
    /// matrix whose row count equals `aCols`.
    private static func matMul(
        _ A: [Double], rows aRows: Int, cols aCols: Int,
        rhs B: [Double], rhsCols bCols: Int
    ) -> [Double] {
        var C = [Double](repeating: 0, count: aRows * bCols)
        for i in 0 ..< aRows {
            for j in 0 ..< bCols {
                var sum = 0.0
                for k in 0 ..< aCols {
                    sum += A[i * aCols + k] * B[k * bCols + j]
                }
                C[i * bCols + j] = sum
            }
        }
        return C
    }

    private static func matVecMul(
        _ A: [Double], rows: Int, cols: Int,
        vec: [Double]
    ) -> [Double] {
        var result = [Double](repeating: 0, count: rows)
        for i in 0 ..< rows {
            for j in 0 ..< cols {
                result[i] += A[i * cols + j] * vec[j]
            }
        }
        return result
    }

    /// Gaussian elimination with partial pivoting.  Returns nil if the system
    /// is singular (shouldn't happen for well-formed Vandermonde problems).
    private static func gaussianElimination(A: [Double], size n: Int, b: [Double]) -> [Double]? {
        // Augmented matrix [A | b]
        var M = [Double](repeating: 0, count: n * (n + 1))
        for i in 0 ..< n {
            for j in 0 ..< n { M[i * (n + 1) + j] = A[i * n + j] }
            M[i * (n + 1) + n] = b[i]
        }

        for col in 0 ..< n {
            // Partial pivot
            var maxRow = col
            var maxVal = abs(M[col * (n + 1) + col])
            for row in (col + 1) ..< n {
                let v = abs(M[row * (n + 1) + col])
                if v > maxVal { maxVal = v
                    maxRow = row }
            }
            guard maxVal > 1E-12 else { return nil }

            if maxRow != col {
                for j in 0 ... n {
                    let tmp = M[col * (n + 1) + j]
                    M[col * (n + 1) + j] = M[maxRow * (n + 1) + j]
                    M[maxRow * (n + 1) + j] = tmp
                }
            }

            let pivot = M[col * (n + 1) + col]
            for row in (col + 1) ..< n {
                let factor = M[row * (n + 1) + col] / pivot
                for j in col ... n {
                    M[row * (n + 1) + j] -= factor * M[col * (n + 1) + j]
                }
            }
        }

        // Back-substitution
        var x = [Double](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            x[i] = M[i * (n + 1) + n]
            for j in (i + 1) ..< n {
                x[i] -= M[i * (n + 1) + j] * x[j]
            }
            x[i] /= M[i * (n + 1) + i]
        }
        return x
    }
}

// MARK: - Builder

extension WatchForecastData {
    /// Build a `WatchForecastData` from raw oref forecast data.
    ///
    /// - Parameters:
    ///   - forecastLines: `[(type, values)]` from `OrefDetermination.forecasts`.
    ///                    Each `values` array contains glucose values at 5-min steps.
    ///   - startDate:     `determination.deliverAt` — the time of the first forecast point.
    ///   - showCone:      User setting: `true` → cone view, `false` → per-type lines.
    ///   - degree:        Polynomial degree (default 3 = cubic).
    static func build(
        forecastLines: [(type: String, values: [Int])],
        startDate: Date,
        showCone: Bool,
        degree: Int = 3
    ) -> WatchForecastData {
        guard !forecastLines.isEmpty else {
            return WatchForecastData(forecastLines: [], coneMin: nil, coneMax: nil, showCone: showCone)
        }

        // --- per-type lines ---
        let lines: [WatchForecastPolynomial] = forecastLines.compactMap { entry in
            guard !entry.values.isEmpty else { return nil }
            let doubles = entry.values.map(Double.init)
            let coeffs = PolynomialFitter.fit(values: doubles, degree: degree)
            return WatchForecastPolynomial(
                type: entry.type,
                coefficients: coeffs,
                startDate: startDate,
                endMinutes: Double(entry.values.count - 1) * 5.0,
                pointCount: entry.values.count
            )
        }

        // --- cone min/max across all types at every common time step ---
        let allValues = forecastLines.map(\.values)
        let minCount = allValues.map(\.count).min() ?? 0

        var coneMinPoly: WatchForecastPolynomial?
        var coneMaxPoly: WatchForecastPolynomial?

        if minCount > 0 {
            var minVals = [Double](repeating: Double.infinity, count: minCount)
            var maxVals = [Double](repeating: -Double.infinity, count: minCount)
            for series in allValues {
                for i in 0 ..< minCount {
                    let v = Double(series[i])
                    if v < minVals[i] { minVals[i] = v }
                    if v > maxVals[i] { maxVals[i] = v }
                }
            }

            let minCoeffs = PolynomialFitter.fit(values: minVals, degree: degree)
            coneMinPoly = WatchForecastPolynomial(
                type: "",
                coefficients: minCoeffs,
                startDate: startDate,
                endMinutes: Double(minCount - 1) * 5.0,
                pointCount: minCount
            )

            let maxCoeffs = PolynomialFitter.fit(values: maxVals, degree: degree)
            coneMaxPoly = WatchForecastPolynomial(
                type: "",
                coefficients: maxCoeffs,
                startDate: startDate,
                endMinutes: Double(minCount - 1) * 5.0,
                pointCount: minCount
            )
        }

        return WatchForecastData(
            forecastLines: lines,
            coneMin: coneMinPoly,
            coneMax: coneMaxPoly,
            showCone: showCone
        )
    }
}
