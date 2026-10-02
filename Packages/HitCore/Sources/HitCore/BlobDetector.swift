import Foundation

/// Souvislá oblast změny v rozdílovém obraze (kandidát na průstřel).
public struct Blob: Sendable, Equatable {
    public var x: Double          // těžiště vážené intenzitou rozdílu
    public var y: Double
    public var area: Int          // počet pixelů
    public var peak: Float        // maximální rozdíl v oblasti
    public var minX: Int, minY: Int, maxX: Int, maxY: Int

    public var equivalentDiameter: Double { 2 * (Double(area) / .pi).squareRoot() }
    public var bboxWidth: Int { maxX - minX + 1 }
    public var bboxHeight: Int { maxY - minY + 1 }
}

public enum BlobDetector {
    /// Najde oblasti pomocí hysterezního prahu: semínko musí mít rozdíl ≥ `high`,
    /// oblast se rozrůstá přes pixely ≥ `low`. 8-okolí.
    public static func findBlobs(in diff: GrayImage, high: Float, low: Float,
                                 minArea: Int, maxArea: Int, border: Int = 0) -> [Blob] {
        let w = diff.width, h = diff.height
        var visited = [Bool](repeating: false, count: w * h)
        var blobs: [Blob] = []
        var stack: [Int] = []
        stack.reserveCapacity(1024)

        let bx0 = border, by0 = border, bx1 = w - border, by1 = h - border
        guard bx1 > bx0, by1 > by0 else { return [] }

        for y in by0..<by1 {
            for x in bx0..<bx1 {
                let i = y * w + x
                if visited[i] || diff.pixels[i] < high { continue }

                var area = 0
                var sw: Double = 0, sx: Double = 0, sy: Double = 0
                var peak: Float = 0
                var minX = x, maxX = x, minY = y, maxY = y
                var tooBig = false
                visited[i] = true
                stack.append(i)

                while let j = stack.popLast() {
                    let jx = j % w, jy = j / w
                    let v = diff.pixels[j]
                    area += 1
                    let wgt = Double(v)
                    sw += wgt; sx += wgt * Double(jx); sy += wgt * Double(jy)
                    peak = max(peak, v)
                    minX = min(minX, jx); maxX = max(maxX, jx)
                    minY = min(minY, jy); maxY = max(maxY, jy)
                    if area > maxArea { tooBig = true }

                    for ny in max(jy - 1, by0)...min(jy + 1, by1 - 1) {
                        for nx in max(jx - 1, bx0)...min(jx + 1, bx1 - 1) {
                            let k = ny * w + nx
                            if !visited[k] && diff.pixels[k] >= low {
                                visited[k] = true
                                stack.append(k)
                            }
                        }
                    }
                }

                if tooBig || area < minArea || sw <= 0 { continue }
                blobs.append(Blob(x: sx / sw, y: sy / sw, area: area, peak: peak,
                                  minX: minX, minY: minY, maxX: maxX, maxY: maxY))
            }
        }
        return blobs
    }
}
