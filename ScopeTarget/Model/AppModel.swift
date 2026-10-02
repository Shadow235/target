import AVFoundation
import AudioToolbox
import CoreGraphics
import Foundation
import HitCore
import Observation
import UIKit

enum MainMode: String, CaseIterable, Identifiable {
    case camera = "Kamera"
    case target = "Terč"
    var id: String { rawValue }
}

@MainActor
@Observable
final class AppModel {
    // Zdroj
    var sourceState: FrameSourceState = .idle
    private(set) var source: FrameSource?
    var cameraSource: CameraFrameSource? { source as? CameraFrameSource }
    var zoom: CGFloat = 1
    var cameraLocked = false

    // Obraz
    var rawPreview: CGImage?
    var rawSize: CGSize = .zero
    var rectified: CGImage?
    var targetFrame: TargetFrame?
    var diffImage: CGImage?
    var detectorStatus: DetectorStatus = .waitingForReference
    var lastShift: Registration.Shift = .zero

    // Stav aplikace
    var mode: MainMode = .camera { didSet { pushSettings() } }
    var prefs: AppPreferences {
        didSet { prefs.save(); pushSettings() }
    }
    var armed = false {
        didSet {
            UIApplication.shared.isIdleTimerDisabled = armed
            pushSettings()
        }
    }
    var showDiff = false { didSet { pushSettings() } }
    var session: ShootingSession
    var selectedShotID: Shot.ID?
    var lastHitFlash: Date?

    private let processor: FrameProcessor
    private let speech = AVSpeechSynthesizer()

    init() {
        let prefs = AppPreferences.load()
        self.prefs = prefs
        self.session = ShootingSession(name: AppModel.defaultSessionName(), calibration: prefs.calibration)
        self.processor = FrameProcessor(settings: ProcessingSettings(calibration: prefs.calibration))
        if prefs.calibration.isSet { mode = .target }
        wireProcessor()
        pushSettings()
        if let src = prefs.source { connect(src) }
    }

    static func defaultSessionName() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "cs_CZ")
        f.dateFormat = "d. M. yyyy HH:mm"
        return "Relace \(f.string(from: Date()))"
    }

    private func wireProcessor() {
        processor.onRawPreview = { [weak self] image, size in
            Task { @MainActor in
                self?.rawPreview = image
                self?.rawSize = size
            }
        }
        processor.onRectified = { [weak self] image, frame in
            Task { @MainActor in
                self?.rectified = image
                self?.targetFrame = frame
            }
        }
        processor.onAnalysis = { [weak self] out in
            Task { @MainActor in self?.handle(out) }
        }
    }

    private func pushSettings() {
        processor.update(ProcessingSettings(
            calibration: prefs.calibration,
            threshold: prefs.threshold,
            confirmFrames: prefs.confirmFrames,
            analysisInterval: 0.3,
            armed: armed && prefs.calibration.isSet,
            wantsRawPreview: mode == .camera || !prefs.calibration.isSet,
            wantsDiff: showDiff))
    }

    // MARK: Zdroj obrazu

    func connect(_ descriptor: SourceDescriptor) {
        source?.stop()
        rawPreview = nil
        rectified = nil
        let src = descriptor.makeSource()
        let processor = self.processor
        src.onFrame = { image in processor.handle(image) }
        src.onStateChange = { [weak self] state in
            Task { @MainActor in self?.sourceState = state }
        }
        source = src
        zoom = 1
        cameraLocked = false
        if prefs.source != descriptor { prefs.source = descriptor }
        src.start()
    }

    func disconnect() {
        source?.stop()
        source = nil
        armed = false
    }

    func setZoom(_ z: CGFloat) {
        zoom = z
        cameraSource?.setZoom(z)
    }

    func toggleCameraLock() {
        cameraLocked.toggle()
        cameraSource?.setLocked(cameraLocked)
    }

    // MARK: Kalibrace

    func updateCalibration(_ change: (inout Calibration) -> Void) {
        var cal = prefs.calibration
        change(&cal)
        prefs.calibration = cal
        session.calibration = cal
        session.rescore()
        SessionStore.save(session)
    }

    func applyPreset(_ target: RingTarget) {
        updateCalibration {
            $0.target = target
            $0.faceWidthMM = target.faceWidthMM
            $0.faceHeightMM = target.faceHeightMM
            $0.centerOffsetMM = .zero
        }
    }

    /// Posune střed kruhů na bod `p` (v aktuálních mm souřadnicích); zásahy se přepočítají.
    func setCenter(atCurrentMM p: PointMM) {
        for i in session.shots.indices {
            session.shots[i].position = PointMM(x: session.shots[i].position.x - p.x,
                                                y: session.shots[i].position.y - p.y)
        }
        updateCalibration {
            $0.centerOffsetMM = PointMM(x: $0.centerOffsetMM.x + p.x, y: $0.centerOffsetMM.y + p.y)
        }
    }

    func confirmCalibration() {
        updateCalibration { $0.isSet = true }
        mode = .target
        // při zapnuté automatice by se jas měnil – u vestavěné/USB kamery rovnou zamknout
        if let cam = cameraSource, !cameraLocked {
            cameraLocked = true
            cam.setLocked(true)
        }
    }

    // MARK: Zásahy

    private func handle(_ out: AnalysisOutput) {
        detectorStatus = out.status
        lastShift = out.shift
        targetFrame = out.frame
        diffImage = out.diffImage
        for hit in out.hits {
            let p = out.frame.toMM(x: hit.x, y: hit.y)
            addShot(at: p, manual: false, diameterMM: hit.diameterPx / out.frame.pxPerMM)
        }
    }

    func addShot(at p: PointMM, manual: Bool, diameterMM: Double? = nil) {
        let cal = prefs.calibration
        let s = cal.target.score(at: p, caliberMM: cal.caliberMM)
        let shot = Shot(number: session.shots.count + 1, time: Date(), position: p,
                        score: cal.target.scored ? s.score : nil, isX: s.isX,
                        manual: manual, detectedDiameterMM: diameterMM)
        session.shots.append(shot)
        selectedShotID = shot.id
        lastHitFlash = Date()
        if manual { processor.absorbManualHit(at: p, caliberMM: cal.caliberMM) }
        SessionStore.save(session)
        announce(shot)
    }

    func deleteShot(_ id: Shot.ID) {
        session.shots.removeAll { $0.id == id }
        session.renumber()
        if selectedShotID == id { selectedShotID = nil }
        SessionStore.save(session)
    }

    func moveShot(_ id: Shot.ID, to p: PointMM) {
        guard let i = session.shots.firstIndex(where: { $0.id == id }) else { return }
        session.shots[i].position = p
        session.shots[i].manual = true
        session.rescore()
        SessionStore.save(session)
    }

    func undoLast() {
        guard let last = session.shots.last else { return }
        deleteShot(last.id)
    }

    /// Nová série na stejném terči (zásahy se vynulují, reference zůstává).
    func newSeries() {
        SessionStore.save(session)
        session = ShootingSession(name: Self.defaultSessionName(), calibration: prefs.calibration)
        selectedShotID = nil
    }

    /// Terč byl vyměněn / přelepen – nová reference.
    func targetReplaced() {
        processor.resetReference()
        newSeries()
    }

    func loadSession(_ s: ShootingSession) {
        SessionStore.save(session)
        session = s
        selectedShotID = nil
    }

    private func announce(_ shot: Shot) {
        if prefs.playSound { AudioServicesPlaySystemSound(1057) }
        guard prefs.announce else { return }
        let text = HitDescriber.describe(number: shot.number, point: shot.position,
                                         score: shot.score, isX: shot.isX)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "cs-CZ")
        utterance.rate = 0.52
        speech.stopSpeaking(at: .word)
        speech.speak(utterance)
    }

    var statusText: String {
        switch sourceState {
        case .idle: return "Bez zdroje"
        case .connecting: return "Připojuji…"
        case .failed(let msg): return msg
        case .running:
            guard prefs.calibration.isSet else { return "Vyznačte terč" }
            guard armed else { return "Připraveno – detekce vypnuta" }
            switch detectorStatus {
            case .waitingForReference: return "Snímám referenci…"
            case .tracking(let c): return c > 0 ? "Sleduji (\(c) kandidát)" : "Sleduji terč"
            case .disturbed: return "Rušení obrazu (světlo / pohyb)"
            case .rebaselined: return "Nová reference po rušení"
            }
        }
    }
}
