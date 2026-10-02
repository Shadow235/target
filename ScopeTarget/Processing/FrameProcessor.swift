import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import HitCore

/// Výsledek jedné analýzy – předává se na hlavní vlákno.
struct AnalysisOutput {
    var hits: [DetectedHit]
    var status: DetectorStatus
    var shift: Registration.Shift
    var frame: TargetFrame
    var diffImage: CGImage?
}

/// Parametry zpracování, které mění uživatel.
struct ProcessingSettings: Equatable {
    var calibration: Calibration
    var threshold: Float = 30
    var confirmFrames: Int = 3
    var analysisInterval: TimeInterval = 0.3
    var armed = false
    var wantsRawPreview = true
    var wantsDiff = false
}

/// Zpracovává snímky ze zdroje. Volá se z vlákna zdroje; pokud je předchozí snímek
/// ještě ve zpracování, nový se zahodí (nikdy se nehromadí zpoždění).
final class FrameProcessor {
    var onRawPreview: ((CGImage, CGSize) -> Void)?
    var onRectified: ((CGImage, TargetFrame) -> Void)?
    var onAnalysis: ((AnalysisOutput) -> Void)?

    private let busy = NSLock()
    private let settingsLock = NSLock()
    private var _settings: ProcessingSettings
    private var settingsChanged = true

    private let context = CIContext(options: [.cacheIntermediates: false])
    private let gray = CGColorSpaceCreateDeviceGray()
    private let rgb = CGColorSpaceCreateDeviceRGB()

    private var detector = HitDetector(config: DetectorConfig(expectedHoleDiameterPx: 5))
    private var accumulator = FrameAccumulator()
    private var lastAveraged: GrayImage?
    private var frame: TargetFrame?
    private var sourceSize: CGSize = .zero
    private var wasArmed = false
    private var lastRawPreview = Date.distantPast
    private var lastRectPreview = Date.distantPast
    private var lastAnalysis = Date()

    init(settings: ProcessingSettings) {
        _settings = settings
    }

    func update(_ settings: ProcessingSettings) {
        settingsLock.lock()
        if settings != _settings {
            _settings = settings
            settingsChanged = true
        }
        settingsLock.unlock()
    }

    private func currentSettings() -> (ProcessingSettings, Bool) {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        let changed = settingsChanged
        settingsChanged = false
        return (_settings, changed)
    }

    /// Ručně přidaný zásah: okolí se převezme do reference, aby ho detektor nehlásil.
    func absorbManualHit(at p: PointMM, caliberMM: Double) {
        busy.lock()
        defer { busy.unlock() }
        guard let frame, let img = lastAveraged else { return }
        let px = frame.toPx(p)
        detector.absorb(from: img, x: px.x, y: px.y, radius: caliberMM * frame.pxPerMM * 1.5 + 3)
    }

    /// Nová reference (např. po přelepení terče).
    func resetReference() {
        busy.lock()
        detector.reset()
        accumulator = FrameAccumulator()
        busy.unlock()
    }

    // MARK: Zpracování

    func handle(_ image: CIImage) {
        guard busy.try() else { return }
        defer { busy.unlock() }

        let (settings, changed) = currentSettings()
        let extent = image.extent
        let now = Date()

        if settings.wantsRawPreview, now.timeIntervalSince(lastRawPreview) > 0.08 {
            lastRawPreview = now
            if let cg = renderPreview(image, maxSide: 1600) {
                onRawPreview?(cg, extent.size)
            }
        }

        let cal = settings.calibration
        guard cal.isSet else { return }

        if changed || extent.size != sourceSize || frame == nil {
            sourceSize = extent.size
            reconfigure(settings, extent: extent)
        }
        guard let frame else { return }

        guard let rect = rectify(image, corners: cal.corners, extent: extent, frame: frame) else { return }

        if now.timeIntervalSince(lastRectPreview) > 0.1,
           let cg = context.createCGImage(rect, from: CGRect(x: 0, y: 0, width: frame.widthPx, height: frame.heightPx),
                                          format: .RGBA8, colorSpace: rgb) {
            lastRectPreview = now
            onRectified?(cg, frame)
        }

        // zapnutí detekce = nová reference
        if settings.armed && !wasArmed {
            detector.reset()
            accumulator = FrameAccumulator()
            lastAnalysis = now
        }
        wasArmed = settings.armed
        guard settings.armed else { return }

        guard let g = grayImage(rect, width: frame.widthPx, height: frame.heightPx) else { return }
        accumulator.add(g)

        guard now.timeIntervalSince(lastAnalysis) >= settings.analysisInterval,
              let avg = accumulator.takeAverage() else { return }
        lastAnalysis = now
        lastAveraged = avg

        let hits = detector.process(avg)
        var diffCG: CGImage?
        if settings.wantsDiff, let d = detector.lastDiff {
            diffCG = makeGrayCGImage(d.scaled(by: 3))
        }
        onAnalysis?(AnalysisOutput(hits: hits, status: detector.status, shift: detector.lastShift,
                                   frame: frame, diffImage: diffCG))
    }

    private func reconfigure(_ settings: ProcessingSettings, extent: CGRect) {
        let cal = settings.calibration
        let pts = cal.corners.map { CGPoint(x: $0.x * extent.width, y: $0.y * extent.height) }
        let quadW = (dist(pts[0], pts[1]) + dist(pts[3], pts[2])) / 2
        let quadH = (dist(pts[0], pts[3]) + dist(pts[1], pts[2])) / 2
        let size = TargetFrame.outputSize(faceWidthMM: cal.faceWidthMM, faceHeightMM: cal.faceHeightMM,
                                          sourceQuadWidthPx: quadW, sourceQuadHeightPx: quadH)
        let newFrame = TargetFrame(widthPx: size.width, heightPx: size.height,
                                   faceWidthMM: cal.faceWidthMM, faceHeightMM: cal.faceHeightMM,
                                   centerOffsetMM: cal.centerOffsetMM)
        let geometryChanged = frame.map { $0.widthPx != newFrame.widthPx || $0.heightPx != newFrame.heightPx } ?? true
        frame = newFrame

        var config = DetectorConfig(expectedHoleDiameterPx: max(1.5, cal.caliberMM * newFrame.pxPerMM))
        config.threshold = settings.threshold
        config.confirmFrames = settings.confirmFrames
        config.maxShiftPx = max(8, min(40, Int(Double(max(size.width, size.height)) * 0.03)))
        detector.config = config
        if geometryChanged {
            detector.reset()
            accumulator = FrameAccumulator()
        }
    }

    private func dist(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    /// Perspektivní narovnání terče ze 4 rohů (normalizované, počátek vlevo nahoře).
    private func rectify(_ image: CIImage, corners: [CGPoint], extent: CGRect, frame: TargetFrame) -> CIImage? {
        guard corners.count == 4 else { return nil }
        func ci(_ p: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + p.x * extent.width, y: extent.minY + (1 - p.y) * extent.height)
        }
        let f = CIFilter.perspectiveCorrection()
        f.inputImage = image
        f.topLeft = ci(corners[0])
        f.topRight = ci(corners[1])
        f.bottomRight = ci(corners[2])
        f.bottomLeft = ci(corners[3])
        f.crop = true
        guard var out = f.outputImage, out.extent.width > 1, out.extent.height > 1 else { return nil }
        out = out.transformed(by: CGAffineTransform(translationX: -out.extent.minX, y: -out.extent.minY))
        out = out.transformed(by: CGAffineTransform(scaleX: CGFloat(frame.widthPx) / out.extent.width,
                                                    y: CGFloat(frame.heightPx) / out.extent.height))
        return out.cropped(to: CGRect(x: 0, y: 0, width: frame.widthPx, height: frame.heightPx))
    }

    private func renderPreview(_ image: CIImage, maxSide: CGFloat) -> CGImage? {
        let e = image.extent
        let scale = min(1, maxSide / max(e.width, e.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return context.createCGImage(scaled, from: scaled.extent, format: .RGBA8, colorSpace: rgb)
    }

    /// Převod do šedi s jistým uspořádáním řádků (řádek 0 = horní okraj).
    private func grayImage(_ image: CIImage, width: Int, height: Int) -> GrayImage? {
        guard let cg = context.createCGImage(image, from: CGRect(x: 0, y: 0, width: width, height: height),
                                             format: .L8, colorSpace: gray) else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? GrayImage(width: width, height: height, bytes: bytes) : nil
    }

    private func makeGrayCGImage(_ img: GrayImage) -> CGImage? {
        let data = Data(img.bytes()) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: img.width, space: gray, bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
