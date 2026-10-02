import Foundation

/// Nastavení detektoru. Rozměry jsou v pixelech rektifikovaného obrazu terče.
public struct DetectorConfig: Sendable, Equatable {
    /// Očekávaný průměr průstřelu v px (ráže × px/mm).
    public var expectedHoleDiameterPx: Double
    /// Minimální rozdíl jasu (0–255) pro semínko oblasti. Nižší = citlivější.
    public var threshold: Float = 30
    /// Kolikrát po sobě musí být změna vidět, než se potvrdí jako zásah.
    public var confirmFrames: Int = 3
    /// Maximální očekávaný posun obrazu mezi snímky (chvění) v px.
    public var maxShiftPx: Int = 16
    /// Tolerance nepřesného zarovnání (px) – potlačuje falešné změny na hranách.
    public var alignTolerancePx: Int = 1
    /// Rychlost, s jakou se reference přizpůsobuje pomalým změnám světla (0–1 za analýzu).
    public var referenceBlend: Float = 0.04
    /// Podíl změněných pixelů, nad kterým je snímek považován za narušený (světlo, pohyb kamery).
    public var disturbedFraction: Double = 0.02
    /// Po kolika narušených analýzách po sobě se reference založí znovu.
    public var rebaselineAfter: Int = 6
    /// Povolený rozsah plochy vůči očekávané ploše průstřelu.
    public var minAreaFactor: Double = 0.2
    public var maxAreaFactor: Double = 6

    public init(expectedHoleDiameterPx: Double) {
        self.expectedHoleDiameterPx = expectedHoleDiameterPx
    }

    var expectedArea: Double { .pi * pow(expectedHoleDiameterPx / 2, 2) }
    var minArea: Int { max(2, Int((expectedArea * minAreaFactor).rounded(.down))) }
    var maxArea: Int { max(minArea + 4, Int((expectedArea * maxAreaFactor).rounded(.up))) }
    var matchTolerance: Double { max(3, expectedHoleDiameterPx * 1.2) }
}

/// Nově potvrzený průstřel v souřadnicích referenčního (rektifikovaného) obrazu.
public struct DetectedHit: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var diameterPx: Double
    public var contrast: Float
}

public enum DetectorStatus: Sendable, Equatable {
    case waitingForReference
    case tracking(candidates: Int)
    case disturbed
    case rebaselined
}

/// Stavový detektor nových průstřelů porovnáním s referenčním snímkem.
///
/// Postup pro každý (zprůměrovaný) snímek:
/// 1. odhad posunu vůči referenci a jeho kompenzace,
/// 2. vyrovnání jasu,
/// 3. absolutní rozdíl → hysterezní práh → oblasti vhodné velikosti,
/// 4. kandidát se musí objevit `confirmFrames`× na stejném místě,
/// 5. potvrzený průstřel se „vpálí“ do reference, aby se nehlásil znovu.
public final class HitDetector {
    public var config: DetectorConfig
    public private(set) var reference: GrayImage?
    public private(set) var lastDiff: GrayImage?
    public private(set) var lastShift: Registration.Shift = .zero
    public private(set) var status: DetectorStatus = .waitingForReference

    private struct Candidate {
        var x: Double
        var y: Double
        var diameter: Double
        var contrast: Float
        var seen: Int
        var missed: Int
    }
    private var candidates: [Candidate] = []
    private var disturbedStreak = 0

    public init(config: DetectorConfig) {
        self.config = config
    }

    /// Zahodí referenci; další snímek se stane novou referencí (např. nový/přelepený terč).
    public func reset() {
        reference = nil
        lastDiff = nil
        candidates = []
        disturbedStreak = 0
        status = .waitingForReference
    }

    public func setReference(_ image: GrayImage) {
        reference = image
        candidates = []
        disturbedStreak = 0
        status = .tracking(candidates: 0)
    }

    /// Zpracuje snímek a vrátí nově potvrzené zásahy.
    @discardableResult
    public func process(_ frame: GrayImage) -> [DetectedHit] {
        guard let ref = reference, ref.width == frame.width, ref.height == frame.height else {
            setReference(frame)
            return []
        }

        // 1) stabilizace
        let shift = Registration.estimateShift(reference: ref, current: frame, maxShift: config.maxShiftPx)
        lastShift = shift
        let margin = max(abs(shift.dx), abs(shift.dy)) + 2
        var aligned = frame.shifted(dx: shift.dx, dy: shift.dy)

        // 2) vyrovnání jasu
        let mRef = ref.mean(inset: margin)
        let mCur = aligned.mean(inset: margin)
        if mCur > 1 { aligned = aligned.scaled(by: mRef / mCur) }

        // 3) rozdíl (s lehkým rozmazáním proti šumu, pokud jsou díry dost velké)
        let blur = config.expectedHoleDiameterPx >= 7 ? 1 : 0
        let a = aligned.boxBlurred(radius: blur)
        let r = ref.boxBlurred(radius: blur)
        // Každý pixel se porovná s nejpodobnějším pixelem reference v okolí ±tol.
        // Tím zmizí falešné změny na hranách kruhů při posunu o zlomek pixelu,
        // ale střed průstřelu (větší než okolí) zůstane viditelný.
        let tol = config.expectedHoleDiameterPx >= 3.5 ? config.alignTolerancePx : 0
        var diff = GrayImage(width: ref.width, height: ref.height)
        var sumDiff: Double = 0
        let w = ref.width, h = ref.height
        for y in 0..<h {
            let row = y * w
            for x in 0..<w {
                let v = a.pixels[row + x]
                var d = abs(v - r.pixels[row + x])
                if tol > 0 && d > 0 {
                    for ny in max(0, y - tol)...min(h - 1, y + tol) {
                        let nrow = ny * w
                        for nx in max(0, x - tol)...min(w - 1, x + tol) {
                            d = min(d, abs(v - r.pixels[nrow + nx]))
                        }
                    }
                }
                diff.pixels[row + x] = d
                sumDiff += Double(d)
            }
        }
        for y in 0..<diff.height {
            for x in 0..<diff.width where x < margin || y < margin || x >= diff.width - margin || y >= diff.height - margin {
                diff[x, y] = 0
            }
        }
        lastDiff = diff

        // adaptivní práh – při silném tetelení vzduchu se automaticky zvedne
        let meanDiff = Float(sumDiff / Double(diff.pixels.count))
        let high = max(config.threshold, meanDiff * 6)
        let low = high * 0.5

        var changed = 0
        for v in diff.pixels where v >= high { changed += 1 }
        if Double(changed) / Double(diff.pixels.count) > config.disturbedFraction {
            disturbedStreak += 1
            if disturbedStreak >= config.rebaselineAfter {
                setReference(aligned)
                status = .rebaselined
            } else {
                status = .disturbed
            }
            return []
        }
        disturbedStreak = 0

        let blobs = BlobDetector.findBlobs(in: diff, high: high, low: low,
                                           minArea: config.minArea, maxArea: config.maxArea,
                                           border: margin)
            .filter { b in
                // průstřel je zhruba kulatý – vyřaď dlouhé tenké změny (tráva, hrana papíru)
                let longSide = Double(max(b.bboxWidth, b.bboxHeight))
                let shortSide = Double(min(b.bboxWidth, b.bboxHeight))
                return longSide <= max(3, shortSide * 3.5)
            }

        // 4) párování s kandidáty
        var matched = [Bool](repeating: false, count: candidates.count)
        for b in blobs {
            var bestIdx = -1
            var bestDist = config.matchTolerance
            for (idx, c) in candidates.enumerated() where !matched[idx] {
                let d = hypot(c.x - b.x, c.y - b.y)
                if d <= bestDist { bestDist = d; bestIdx = idx }
            }
            if bestIdx >= 0 {
                var c = candidates[bestIdx]
                let n = Double(c.seen)
                c.x = (c.x * n + b.x) / (n + 1)
                c.y = (c.y * n + b.y) / (n + 1)
                c.diameter = (c.diameter * n + b.equivalentDiameter) / (n + 1)
                c.contrast = max(c.contrast, b.peak)
                c.seen += 1
                c.missed = 0
                candidates[bestIdx] = c
                matched[bestIdx] = true
            } else {
                candidates.append(Candidate(x: b.x, y: b.y, diameter: b.equivalentDiameter,
                                            contrast: b.peak, seen: 1, missed: 0))
                matched.append(true)
            }
        }
        for idx in candidates.indices where !matched[idx] {
            candidates[idx].missed += 1
        }
        candidates.removeAll { $0.missed > 1 }

        // 5) potvrzení
        var hits: [DetectedHit] = []
        var remaining: [Candidate] = []
        var updatedRef = ref
        for c in candidates {
            if c.seen >= config.confirmFrames {
                hits.append(DetectedHit(x: c.x, y: c.y, diameterPx: c.diameter, contrast: c.contrast))
                let radius = max(3, c.diameter * 1.5 + 2)
                stamp(from: aligned, into: &updatedRef, cx: c.x, cy: c.y, radius: radius)
            } else {
                remaining.append(c)
            }
        }
        candidates = remaining

        // pomalé přizpůsobení reference světlu (mimo aktivní kandidáty)
        blendReference(&updatedRef, with: aligned, excluding: candidates)
        reference = updatedRef
        status = .tracking(candidates: candidates.count)
        return hits
    }

    /// Ručně přidaný / smazaný zásah: převezme aktuální vzhled okolí do reference.
    public func absorb(from frame: GrayImage, x: Double, y: Double, radius: Double) {
        guard var ref = reference else { return }
        let aligned = frame.shifted(dx: lastShift.dx, dy: lastShift.dy)
        stamp(from: aligned, into: &ref, cx: x, cy: y, radius: radius)
        reference = ref
        candidates.removeAll { hypot($0.x - x, $0.y - y) <= radius }
    }

    private func stamp(from src: GrayImage, into dst: inout GrayImage, cx: Double, cy: Double, radius: Double) {
        let r2 = radius * radius
        let x0 = max(0, Int(cx - radius)), x1 = min(dst.width - 1, Int(cx + radius) + 1)
        let y0 = max(0, Int(cy - radius)), y1 = min(dst.height - 1, Int(cy + radius) + 1)
        guard x0 <= x1, y0 <= y1 else { return }
        for y in y0...y1 {
            for x in x0...x1 {
                let dx = Double(x) - cx, dy = Double(y) - cy
                if dx * dx + dy * dy <= r2 { dst[x, y] = src[x, y] }
            }
        }
    }

    private func blendReference(_ ref: inout GrayImage, with cur: GrayImage, excluding cands: [Candidate]) {
        let a = config.referenceBlend
        guard a > 0 else { return }
        let keep = 1 - a
        let guardR = config.matchTolerance * 2
        for y in 0..<ref.height {
            let row = y * ref.width
            let nearY = cands.filter { abs($0.y - Double(y)) <= guardR }
            for x in 0..<ref.width {
                if !nearY.isEmpty && nearY.contains(where: { hypot($0.x - Double(x), $0.y - Double(y)) <= guardR }) {
                    continue
                }
                ref.pixels[row + x] = ref.pixels[row + x] * keep + cur.pixels[row + x] * a
            }
        }
    }
}
