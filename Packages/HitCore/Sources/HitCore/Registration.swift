import Foundation

/// Odhad posunu mezi dvěma snímky (kompenzace chvění dalekohledu / stativu).
public enum Registration {
    public struct Shift: Equatable, Sendable {
        public var dx: Int
        public var dy: Int
        public init(dx: Int, dy: Int) { self.dx = dx; self.dy = dy }
        public static let zero = Shift(dx: 0, dy: 0)
    }

    /// Najde posun (dx, dy) takový, že `current(x + dx, y + dy) ≈ reference(x, y)`.
    /// Hledá hrubě na zmenšeném obraze a pak zpřesňuje v plném rozlišení.
    public static func estimateShift(reference: GrayImage, current: GrayImage, maxShift: Int) -> Shift {
        precondition(reference.width == current.width && reference.height == current.height)
        guard maxShift > 0 else { return .zero }

        let factor = maxShift >= 8 && min(reference.width, reference.height) >= 128 ? 4 : 1
        var coarse = Shift.zero
        if factor > 1 {
            let r = reference.downsampled(by: factor).boxBlurred(radius: 1)
            let c = current.downsampled(by: factor).boxBlurred(radius: 1)
            let range = maxShift / factor + 1
            coarse = bestShift(r, c, center: .zero, range: range, step: 1)
            coarse = Shift(dx: coarse.dx * factor, dy: coarse.dy * factor)
        }
        let r = reference.boxBlurred(radius: 1)
        let c = current.boxBlurred(radius: 1)
        let fine = bestShift(r, c, center: coarse, range: factor > 1 ? factor : maxShift, step: 2)
        return Shift(dx: max(-maxShift, min(maxShift, fine.dx)),
                     dy: max(-maxShift, min(maxShift, fine.dy)))
    }

    /// Hledání minima SAD (součtu absolutních rozdílů) s odečtenými průměry
    /// – robustní vůči změně jasu.
    private static func bestShift(_ ref: GrayImage, _ cur: GrayImage, center: Shift, range: Int, step: Int) -> Shift {
        let w = ref.width, h = ref.height
        let margin = max(abs(center.dx), abs(center.dy)) + range + 1
        let x0 = margin, x1 = w - margin, y0 = margin, y1 = h - margin
        guard x1 - x0 > 8, y1 - y0 > 8 else { return center }

        let meanR = ref.mean(inset: margin)
        var best = center
        var bestCost = Float.greatestFiniteMagnitude
        for dy in (center.dy - range)...(center.dy + range) {
            for dx in (center.dx - range)...(center.dx + range) {
                // průměr posunuté oblasti aktuálního snímku
                var sumC: Float = 0
                var n: Float = 0
                var y = y0
                while y < y1 {
                    let rowC = (y + dy) * w
                    var x = x0
                    while x < x1 { sumC += cur.pixels[rowC + x + dx]; n += 1; x += step }
                    y += step
                }
                let offset = meanR - sumC / n
                var cost: Float = 0
                y = y0
                while y < y1 {
                    let rowR = y * w
                    let rowC = (y + dy) * w
                    var x = x0
                    while x < x1 {
                        cost += abs(ref.pixels[rowR + x] - cur.pixels[rowC + x + dx] - offset)
                        x += step
                    }
                    y += step
                }
                // mírná preference menších posunů při shodě
                cost *= 1 + 0.0005 * Float(abs(dx - center.dx) + abs(dy - center.dy))
                if cost < bestCost {
                    bestCost = cost
                    best = Shift(dx: dx, dy: dy)
                }
            }
        }
        return best
    }
}
