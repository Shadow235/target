import Foundation

/// Jednoduchý šedotónový obraz s hodnotami 0...255 ve Float.
public struct GrayImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var pixels: [Float]

    public init(width: Int, height: Int, pixels: [Float]) {
        precondition(pixels.count == width * height, "Počet pixelů neodpovídá rozměrům")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public init(width: Int, height: Int, fill: Float = 0) {
        self.init(width: width, height: height, pixels: Array(repeating: fill, count: width * height))
    }

    /// Vytvoří obraz z 8bitového bufferu (např. výstup CIContext v formátu L8).
    public init(width: Int, height: Int, bytes: [UInt8], bytesPerRow: Int? = nil) {
        let stride = bytesPerRow ?? width
        var px = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = y * stride
            let out = y * width
            for x in 0..<width {
                px[out + x] = Float(bytes[row + x])
            }
        }
        self.init(width: width, height: height, pixels: px)
    }

    @inlinable
    public subscript(x: Int, y: Int) -> Float {
        get { pixels[y * width + x] }
        set { pixels[y * width + x] = newValue }
    }

    /// Hodnota s ořezem souřadnic na okraj obrazu.
    @inlinable
    public func clamped(_ x: Int, _ y: Int) -> Float {
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        return pixels[cy * width + cx]
    }

    /// 8bitová reprezentace (např. pro zobrazení ladicí masky).
    public func bytes() -> [UInt8] {
        pixels.map { UInt8(max(0, min(255, $0.rounded()))) }
    }

    /// Průměr v obdélníku (výchozí: celý obraz).
    public func mean(inset: Int = 0) -> Float {
        let x0 = inset, y0 = inset, x1 = width - inset, y1 = height - inset
        guard x1 > x0, y1 > y0 else { return 0 }
        var sum: Double = 0
        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 { sum += Double(pixels[row + x]) }
        }
        return Float(sum / Double((x1 - x0) * (y1 - y0)))
    }

    /// Zmenšení průměrováním bloků factor×factor.
    public func downsampled(by factor: Int) -> GrayImage {
        guard factor > 1 else { return self }
        let w = width / factor, h = height / factor
        var out = [Float](repeating: 0, count: w * h)
        let norm = 1 / Float(factor * factor)
        for y in 0..<h {
            for x in 0..<w {
                var s: Float = 0
                for dy in 0..<factor {
                    let row = (y * factor + dy) * width + x * factor
                    for dx in 0..<factor { s += pixels[row + dx] }
                }
                out[y * w + x] = s * norm
            }
        }
        return GrayImage(width: w, height: h, pixels: out)
    }

    /// Separabilní krabicové rozmazání s poloměrem `radius`.
    public func boxBlurred(radius: Int) -> GrayImage {
        guard radius > 0 else { return self }
        var tmp = [Float](repeating: 0, count: pixels.count)
        let norm = 1 / Float(2 * radius + 1)
        // Horizontálně
        for y in 0..<height {
            let row = y * width
            var acc: Float = 0
            for k in -radius...radius { acc += clamped(k, y) }
            for x in 0..<width {
                tmp[row + x] = acc * norm
                acc += clamped(x + radius + 1, y) - clamped(x - radius, y)
            }
        }
        // Vertikálně
        var out = [Float](repeating: 0, count: pixels.count)
        for x in 0..<width {
            var acc: Float = 0
            for k in -radius...radius { acc += tmp[min(max(k, 0), height - 1) * width + x] }
            for y in 0..<height {
                out[y * width + x] = acc * norm
                let add = tmp[min(y + radius + 1, height - 1) * width + x]
                let sub = tmp[max(y - radius, 0) * width + x]
                acc += add - sub
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Posun obrazu: výsledek(x, y) = self(x + dx, y + dy). Okraje se doplní nejbližším pixelem.
    public func shifted(dx: Int, dy: Int) -> GrayImage {
        if dx == 0 && dy == 0 { return self }
        var out = [Float](repeating: 0, count: pixels.count)
        for y in 0..<height {
            let sy = min(max(y + dy, 0), height - 1) * width
            let row = y * width
            for x in 0..<width {
                out[row + x] = pixels[sy + min(max(x + dx, 0), width - 1)]
            }
        }
        return GrayImage(width: width, height: height, pixels: out)
    }

    /// Vynásobení všech pixelů konstantou.
    public func scaled(by factor: Float) -> GrayImage {
        if factor == 1 { return self }
        return GrayImage(width: width, height: height, pixels: pixels.map { $0 * factor })
    }
}

/// Průměruje po sobě jdoucí snímky – potlačuje šum senzoru a tetelení vzduchu (mirage).
public struct FrameAccumulator: Sendable {
    private var sum: [Float] = []
    private var width = 0
    private var height = 0
    public private(set) var count = 0

    public init() {}

    public mutating func add(_ image: GrayImage) {
        if image.width != width || image.height != height || sum.isEmpty {
            width = image.width
            height = image.height
            sum = image.pixels
            count = 1
            return
        }
        for i in 0..<sum.count { sum[i] += image.pixels[i] }
        count += 1
    }

    /// Vrátí průměr a vynuluje akumulátor.
    public mutating func takeAverage() -> GrayImage? {
        guard count > 0 else { return nil }
        let inv = 1 / Float(count)
        let img = GrayImage(width: width, height: height, pixels: sum.map { $0 * inv })
        sum = []
        count = 0
        return img
    }
}
