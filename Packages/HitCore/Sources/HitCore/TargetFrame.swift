import Foundation

/// Převod mezi pixely rektifikovaného obrazu (počátek vlevo nahoře, y dolů)
/// a milimetry na terči (počátek ve středu kruhů, y nahoru).
public struct TargetFrame: Codable, Sendable, Equatable {
    public var widthPx: Int
    public var heightPx: Int
    public var faceWidthMM: Double
    public var faceHeightMM: Double
    /// Posun středu kruhů vůči středu vyznačené plochy (mm, +y nahoru).
    public var centerOffsetMM: PointMM

    public init(widthPx: Int, heightPx: Int, faceWidthMM: Double, faceHeightMM: Double,
                centerOffsetMM: PointMM = .zero) {
        self.widthPx = widthPx; self.heightPx = heightPx
        self.faceWidthMM = faceWidthMM; self.faceHeightMM = faceHeightMM
        self.centerOffsetMM = centerOffsetMM
    }

    public var pxPerMMX: Double { Double(widthPx) / faceWidthMM }
    public var pxPerMMY: Double { Double(heightPx) / faceHeightMM }
    public var pxPerMM: Double { (pxPerMMX + pxPerMMY) / 2 }

    public func toMM(x: Double, y: Double) -> PointMM {
        let mx = x / pxPerMMX - faceWidthMM / 2 - centerOffsetMM.x
        let my = faceHeightMM / 2 - y / pxPerMMY - centerOffsetMM.y
        return PointMM(x: mx, y: my)
    }

    public func toPx(_ p: PointMM) -> (x: Double, y: Double) {
        let x = (p.x + centerOffsetMM.x + faceWidthMM / 2) * pxPerMMX
        let y = (faceHeightMM / 2 - p.y - centerOffsetMM.y) * pxPerMMY
        return (x, y)
    }

    /// Rozměry výstupu rektifikace: zachová poměr stran terče a zhruba rozlišení zdroje.
    public static func outputSize(faceWidthMM: Double, faceHeightMM: Double,
                                  sourceQuadWidthPx: Double, sourceQuadHeightPx: Double,
                                  maxSide: Int = 1000, minSide: Int = 200) -> (width: Int, height: Int) {
        let ppm = max(sourceQuadWidthPx / faceWidthMM, sourceQuadHeightPx / faceHeightMM)
        var w = faceWidthMM * ppm, h = faceHeightMM * ppm
        let longSide = max(w, h)
        if longSide > Double(maxSide) { let k = Double(maxSide) / longSide; w *= k; h *= k }
        if longSide < Double(minSide) { let k = Double(minSide) / longSide; w *= k; h *= k }
        return (max(16, Int(w.rounded())), max(16, Int(h.rounded())))
    }
}
