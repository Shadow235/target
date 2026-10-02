import Foundation

/// Bod v milimetrech vůči středu terče. +x doprava, +y nahoru (jako na terči).
public struct PointMM: Codable, Sendable, Equatable, Hashable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
    public var distance: Double { hypot(x, y) }
    public static let zero = PointMM(x: 0, y: 0)
}

/// Kruhový terč: nejvyšší kruh má průměr `innerDiameterMM`, každý další je o `ringWidthMM` (poloměr) větší.
public struct RingTarget: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var faceWidthMM: Double
    public var faceHeightMM: Double
    public var innerDiameterMM: Double
    public var ringWidthMM: Double
    public var ringCount: Int
    public var maxScore: Int
    /// Vnitřní desítka (X). nil = nepoužívá se.
    public var xDiameterMM: Double?
    /// Počet vnitřních kruhů, které jsou černé (terčové „jablko“) – jen pro vykreslení.
    public var blackRings: Int
    /// false = bez bodování, jen poloha zásahů.
    public var scored: Bool

    public init(id: String, name: String, faceWidthMM: Double, faceHeightMM: Double,
                innerDiameterMM: Double, ringWidthMM: Double, ringCount: Int, maxScore: Int,
                xDiameterMM: Double? = nil, blackRings: Int = 0, scored: Bool = true) {
        self.id = id; self.name = name
        self.faceWidthMM = faceWidthMM; self.faceHeightMM = faceHeightMM
        self.innerDiameterMM = innerDiameterMM; self.ringWidthMM = ringWidthMM
        self.ringCount = ringCount; self.maxScore = maxScore
        self.xDiameterMM = xDiameterMM; self.blackRings = blackRings; self.scored = scored
    }

    /// Poloměr hranice kruhu s hodnotou `score` (maxScore = nejmenší kruh).
    public func ringRadius(forScore score: Int) -> Double {
        let k = maxScore - score
        return innerDiameterMM / 2 + Double(k) * ringWidthMM
    }

    public var outerRadiusMM: Double { ringRadius(forScore: maxScore - ringCount + 1) }

    /// Bodová hodnota podle pravidla „dotyk čáry = vyšší hodnota“ (měřidlo ráže).
    public func score(at p: PointMM, caliberMM: Double) -> (score: Int, isX: Bool) {
        guard scored else { return (0, false) }
        let edge = max(0, p.distance - caliberMM / 2)
        let isX = xDiameterMM.map { edge <= $0 / 2 } ?? false
        let inner = innerDiameterMM / 2
        if edge <= inner { return (maxScore, isX) }
        let k = Int(((edge - inner) / ringWidthMM).rounded(.up))
        let s = maxScore - k
        return (s >= maxScore - ringCount + 1 ? s : 0, false)
    }

    // MARK: Předvolby (rozměry podle pravidel ISSF, kde je to relevantní)

    public static let issf300mRifle = RingTarget(
        id: "issf300", name: "ISSF 300 m puška", faceWidthMM: 1300, faceHeightMM: 1300,
        innerDiameterMM: 100, ringWidthMM: 50, ringCount: 10, maxScore: 10,
        xDiameterMM: 50, blackRings: 5)

    public static let issf50mRifle = RingTarget(
        id: "issf50r", name: "ISSF 50 m malorážka", faceWidthMM: 250, faceHeightMM: 250,
        innerDiameterMM: 10.4, ringWidthMM: 8, ringCount: 10, maxScore: 10,
        xDiameterMM: 5, blackRings: 7)

    public static let issfPrecisionPistol = RingTarget(
        id: "issf25p", name: "ISSF 25/50 m pistole", faceWidthMM: 550, faceHeightMM: 550,
        innerDiameterMM: 50, ringWidthMM: 25, ringCount: 10, maxScore: 10,
        xDiameterMM: 25, blackRings: 4)

    public static let generic100m = RingTarget(
        id: "gen100", name: "Obecný 100 m (10 kruhů, 5 cm)", faceWidthMM: 500, faceHeightMM: 500,
        innerDiameterMM: 50, ringWidthMM: 25, ringCount: 10, maxScore: 10,
        blackRings: 4)

    public static let unscored = RingTarget(
        id: "free", name: "Libovolný terč (bez bodování)", faceWidthMM: 500, faceHeightMM: 500,
        innerDiameterMM: 0, ringWidthMM: 25, ringCount: 0, maxScore: 0, scored: false)

    public static let presets: [RingTarget] = [generic100m, issf300mRifle, issf50mRifle, issfPrecisionPistol, unscored]
}

/// Úhlové jednotky pro vyhodnocení skupiny.
public enum Angular {
    /// Milliradiány: mm na 1 m vzdálenosti.
    public static func mrad(_ mm: Double, distanceM: Double) -> Double {
        guard distanceM > 0 else { return 0 }
        return mm / distanceM
    }

    /// Úhlové minuty (MOA).
    public static func moa(_ mm: Double, distanceM: Double) -> Double {
        mrad(mm, distanceM: distanceM) * 3.437746771
    }
}

/// Statistika skupiny zásahů.
public struct GroupStats: Sendable, Equatable {
    public var count: Int
    public var totalScore: Int
    public var xCount: Int
    public var center: PointMM            // střed skupiny (střední bod zásahu)
    public var extremeSpreadMM: Double    // největší vzdálenost středů dvou zásahů
    public var meanRadiusMM: Double       // průměrná vzdálenost od středu skupiny
    public var widthMM: Double
    public var heightMM: Double

    public init(points: [PointMM], scores: [Int] = [], xs: Int = 0) {
        count = points.count
        totalScore = scores.reduce(0, +)
        xCount = xs
        guard !points.isEmpty else {
            center = .zero; extremeSpreadMM = 0; meanRadiusMM = 0; widthMM = 0; heightMM = 0
            return
        }
        let cx = points.map(\.x).reduce(0, +) / Double(points.count)
        let cy = points.map(\.y).reduce(0, +) / Double(points.count)
        center = PointMM(x: cx, y: cy)
        var es: Double = 0
        for i in points.indices {
            for j in points.indices where j > i {
                es = max(es, hypot(points[i].x - points[j].x, points[i].y - points[j].y))
            }
        }
        extremeSpreadMM = es
        meanRadiusMM = points.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / Double(points.count)
        widthMM = (points.map(\.x).max() ?? 0) - (points.map(\.x).min() ?? 0)
        heightMM = (points.map(\.y).max() ?? 0) - (points.map(\.y).min() ?? 0)
    }

    public var averageScore: Double { count > 0 ? Double(totalScore) / Double(count) : 0 }
}

/// Český slovní popis polohy zásahu – pro hlasové hlášení.
public enum HitDescriber {
    public static func describe(number: Int, point: PointMM, score: Int?, isX: Bool) -> String {
        var parts: [String] = ["Rána \(number)"]
        if let score {
            parts.append(score == 0 ? "mimo" : (isX ? "vnitřní desítka" : scoreWord(score)))
        }
        let dist = point.distance
        if dist < 5 {
            parts.append("střed")
        } else {
            var dir: [String] = []
            let cmX = abs(point.x) / 10, cmY = abs(point.y) / 10
            if cmY >= 0.5 { dir.append("\(format(cmY)) \(point.y > 0 ? "nahoru" : "dolů")") }
            if cmX >= 0.5 { dir.append("\(format(cmX)) \(point.x > 0 ? "vpravo" : "vlevo")") }
            if !dir.isEmpty { parts.append(dir.joined(separator: ", ")) }
        }
        return parts.joined(separator: ", ")
    }

    private static func format(_ cm: Double) -> String {
        let v = cm >= 10 ? cm.rounded() : (cm * 2).rounded() / 2
        let s = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v).replacingOccurrences(of: ".", with: ",")
        return "\(s) cm"
    }

    private static func scoreWord(_ s: Int) -> String {
        switch s {
        case 10: return "desítka"
        case 9: return "devítka"
        case 8: return "osmička"
        case 7: return "sedmička"
        case 6: return "šestka"
        case 5: return "pětka"
        case 4: return "čtyřka"
        case 3: return "trojka"
        case 2: return "dvojka"
        case 1: return "jednička"
        default: return "\(s)"
        }
    }
}
