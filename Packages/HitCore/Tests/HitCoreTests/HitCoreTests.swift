import XCTest
@testable import HitCore

/// Deterministický generátor pro opakovatelné testy.
struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(1 << 53)
    }
    mutating func noise(_ amp: Double) -> Float { Float((next() * 2 - 1) * amp) }
}

/// Syntetický terč: papír, kruhy, černé jablko a průstřely.
struct SyntheticTarget {
    let size = 400
    var holes: [(x: Double, y: Double, r: Double)] = []

    func render(shiftX: Double = 0, shiftY: Double = 0, noise: Double = 4, brightness: Float = 1, seed: UInt64) -> GrayImage {
        var rng = LCG(state: seed)
        var img = GrayImage(width: size, height: size)
        let c = Double(size) / 2
        for y in 0..<size {
            for x in 0..<size {
                // souřadnice na „fyzickém“ terči (obraz je posunutý o shift)
                let tx = Double(x) + shiftX, ty = Double(y) + shiftY
                let d = hypot(tx - c, ty - c)
                var v: Float = 215
                if d < 60 { v = 35 }                                   // černé jablko
                let ring = d.truncatingRemainder(dividingBy: 20)
                if d < 180 && (ring < 1.2) { v = d < 60 ? 190 : 40 }  // čáry kruhů
                for h in holes where hypot(tx - h.x, ty - h.y) <= h.r {
                    v = d < 60 ? 120 : 20                              // průstřel (na černém světlejší)
                }
                img[x, y] = max(0, min(255, v * brightness + rng.noise(noise)))
            }
        }
        return img
    }
}

final class HitCoreTests: XCTestCase {

    func testRegistrationRecoversShift() {
        let t = SyntheticTarget()
        let ref = t.render(seed: 1)
        let cur = t.render(shiftX: 7, shiftY: -5, seed: 2)
        let s = Registration.estimateShift(reference: ref, current: cur, maxShift: 16)
        // current(x+dx) == ref(x)  =>  dx = -shift
        XCTAssertEqual(s.dx, -7)
        XCTAssertEqual(s.dy, 5)
    }

    func testNoFalsePositivesOnNoiseAndJitter() {
        let t = SyntheticTarget()
        let det = HitDetector(config: DetectorConfig(expectedHoleDiameterPx: 6))
        var total = 0
        var rng = LCG(state: 99)
        for i in 0..<20 {
            let jx = Double(Int(rng.next() * 9) - 4), jy = Double(Int(rng.next() * 9) - 4)
            total += det.process(t.render(shiftX: jx, shiftY: jy, noise: 6,
                                          brightness: 1 + Float(i) * 0.004, seed: UInt64(i + 10))).count
        }
        XCTAssertEqual(total, 0)
    }

    func testSubpixelJitterNoFalsePositivesButDetectsHole() {
        var t = SyntheticTarget()
        let det = HitDetector(config: DetectorConfig(expectedHoleDiameterPx: 6))
        var rng = LCG(state: 3)
        func frame(_ seed: Int) -> GrayImage {
            // posun o zlomky pixelu – hrany kruhů „přeskakují“
            t.render(shiftX: rng.next() * 3 - 1.5, shiftY: rng.next() * 3 - 1.5, noise: 5, seed: UInt64(seed))
        }
        var found: [DetectedHit] = []
        for i in 0..<15 { found += det.process(frame(i)) }
        XCTAssertEqual(found.count, 0, "falešné zásahy při subpixelovém chvění")

        t.holes.append((x: 300, y: 250, r: 3))
        for i in 15..<22 { found += det.process(frame(i)) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.x ?? 0, 300, accuracy: 2)
        XCTAssertEqual(found.first?.y ?? 0, 250, accuracy: 2)
    }

    func testDetectsNewHolesOnceWithJitter() {
        var t = SyntheticTarget()
        let det = HitDetector(config: DetectorConfig(expectedHoleDiameterPx: 6))
        var rng = LCG(state: 7)
        func frame(_ seed: Int) -> GrayImage {
            // první snímek (reference) bez posunu, aby šla ověřit absolutní poloha
            let jx = Double(Int(rng.next() * 7) - 3), jy = Double(Int(rng.next() * 7) - 3)
            return t.render(shiftX: seed == 0 ? 0 : jx, shiftY: seed == 0 ? 0 : jy, noise: 5, seed: UInt64(seed))
        }
        for i in 0..<4 { XCTAssertTrue(det.process(frame(i)).isEmpty) }

        // první rána na bílém papíře
        t.holes.append((x: 270, y: 150, r: 3))
        var found: [DetectedHit] = []
        for i in 4..<10 { found += det.process(frame(i)) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.x ?? 0, 270, accuracy: 1.5)
        XCTAssertEqual(found.first?.y ?? 0, 150, accuracy: 1.5)

        // druhá rána v černém jablku
        t.holes.append((x: 190, y: 215, r: 3))
        found = []
        for i in 10..<16 { found += det.process(frame(i)) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.x ?? 0, 190, accuracy: 1.5)
        XCTAssertEqual(found.first?.y ?? 0, 215, accuracy: 1.5)
    }

    func testLightingChangeDoesNotCreateHits() {
        let t = SyntheticTarget()
        let det = HitDetector(config: DetectorConfig(expectedHoleDiameterPx: 6))
        var total = 0
        for i in 0..<3 { total += det.process(t.render(seed: UInt64(i))).count }
        // mrak – náhlé ztmavení o 25 %
        for i in 3..<12 { total += det.process(t.render(brightness: 0.75, seed: UInt64(i))).count }
        XCTAssertEqual(total, 0)
    }

    func testScoringISSF() {
        let t = RingTarget.issf50mRifle   // desítka 10,4 mm, kruh 8 mm
        let cal = 5.6
        XCTAssertEqual(t.score(at: .zero, caliberMM: cal).score, 10)
        XCTAssertTrue(t.score(at: .zero, caliberMM: cal).isX)
        // okraj díry přesně na hranici desítky => 10
        XCTAssertEqual(t.score(at: PointMM(x: 5.2 + 2.8, y: 0), caliberMM: cal).score, 10)
        XCTAssertEqual(t.score(at: PointMM(x: 5.2 + 2.8 + 0.1, y: 0), caliberMM: cal).score, 9)
        XCTAssertEqual(t.score(at: PointMM(x: 0, y: -(77.2 + 2.8)), caliberMM: cal).score, 1)
        XCTAssertEqual(t.score(at: PointMM(x: 0, y: -(77.2 + 3.0)), caliberMM: cal).score, 0)
    }

    func testGroupStatsAndAngles() {
        let pts = [PointMM(x: -10, y: 0), PointMM(x: 10, y: 0), PointMM(x: 0, y: 30)]
        let g = GroupStats(points: pts)
        XCTAssertEqual(g.center.y, 10, accuracy: 1e-9)
        XCTAssertEqual(g.extremeSpreadMM, hypot(10, 30), accuracy: 1e-9)
        XCTAssertEqual(Angular.mrad(100, distanceM: 100), 1, accuracy: 1e-9)
        XCTAssertEqual(Angular.moa(29.0888, distanceM: 100), 1, accuracy: 1e-3)
    }

    func testTargetFrameRoundTrip() {
        let f = TargetFrame(widthPx: 800, heightPx: 400, faceWidthMM: 500, faceHeightMM: 250,
                            centerOffsetMM: PointMM(x: 10, y: -5))
        let p = PointMM(x: 37, y: -12)
        let px = f.toPx(p)
        let back = f.toMM(x: px.x, y: px.y)
        XCTAssertEqual(back.x, p.x, accuracy: 1e-9)
        XCTAssertEqual(back.y, p.y, accuracy: 1e-9)
        // střed plochy je o offset vedle středu kruhů
        let c = f.toMM(x: 400, y: 200)
        XCTAssertEqual(c.x, -10, accuracy: 1e-9)
        XCTAssertEqual(c.y, 5, accuracy: 1e-9)
    }

    func testDescriberCzech() {
        let s = HitDescriber.describe(number: 3, point: PointMM(x: -42, y: 21), score: 9, isX: false)
        XCTAssertEqual(s, "Rána 3, devítka, 2 cm nahoru, 4 cm vlevo")
    }
}
