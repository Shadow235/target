import AVFoundation
import CoreImage
import UIKit

/// Vestavěná kamera iPadu nebo USB-C (UVC) kamera připojená k iPadu (iPadOS 17+).
final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrame: ((CIImage) -> Void)?
    var onStateChange: ((FrameSourceState) -> Void)?

    let deviceID: String
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let outputQueue = DispatchQueue(label: "camera.frames", qos: .userInitiated)
    private(set) var device: AVCaptureDevice?
    private var connection: AVCaptureConnection?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var disconnectObserver: NSObjectProtocol?

    var displayName: String { device?.localizedName ?? "Kamera" }

    init(deviceID: String) {
        self.deviceID = deviceID
        super.init()
    }

    deinit {
        if let disconnectObserver { NotificationCenter.default.removeObserver(disconnectObserver) }
    }

    /// Vestavěné i externí (USB-C) kamery.
    static func availableDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType] = [
            .external, .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera
        ]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
    }

    func start() {
        onStateChange?(.connecting)
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.onStateChange?(.failed("Aplikace nemá povolený přístup ke kameře (Nastavení → Soukromí)."))
                return
            }
            DispatchQueue.main.async { self.startOnMain() }
        }
    }

    private func startOnMain() {
        guard let device = AVCaptureDevice(uniqueID: deviceID) else {
            onStateChange?(.failed("Kamera není připojená."))
            return
        }
        self.device = device
        // koordinátor natočení musí vzniknout na hlavním vlákně
        rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)

        disconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: .main
        ) { [weak self] _ in
            self?.onStateChange?(.failed("Kamera byla odpojena."))
        }

        sessionQueue.async { [weak self] in self?.configureAndRun(device) }
    }

    private func configureAndRun(_ device: AVCaptureDevice) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else { throw CameraError.cannotAdd }
            session.addInput(input)
        } catch {
            session.commitConfiguration()
            onStateChange?(.failed("Kameru nelze otevřít: \(error.localizedDescription)"))
            return
        }

        // co nejvyšší rozlišení (max 4K) s alespoň 15 fps – pro detekci děr je rozlišení klíčové
        session.sessionPreset = .inputPriority
        if let best = Self.bestFormat(for: device) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = best
                device.unlockForConfiguration()
            } catch {}
        }

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        connection = output.connection(with: .video)
        session.commitConfiguration()

        DispatchQueue.main.async { [weak self] in self?.observeRotation() }
        session.startRunning()
        onStateChange?(session.isRunning ? .running : .failed("Kameru se nepodařilo spustit."))
    }

    private func observeRotation() {
        guard let rotationCoordinator else { return }
        rotationObservation = rotationCoordinator.observe(\.videoRotationAngleForHorizonLevelCapture,
                                                          options: [.initial, .new]) { [weak self] coord, _ in
            let angle = coord.videoRotationAngleForHorizonLevelCapture
            self?.sessionQueue.async {
                guard let conn = self?.connection, conn.isVideoRotationAngleSupported(angle) else { return }
                conn.videoRotationAngle = angle
            }
        }
    }

    private static func bestFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        device.formats
            .filter { f in
                let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
                let maxFps = f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return d.width <= 3840 && maxFps >= 15
            }
            .max { a, b in
                let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
                let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
                return Int(da.width) * Int(da.height) < Int(db.width) * Int(db.height)
            }
    }

    func stop() {
        rotationObservation = nil
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        onStateChange?(.idle)
    }

    // MARK: Ovládání kamery

    var maxZoom: CGFloat {
        guard let device else { return 1 }
        return min(device.activeFormat.videoMaxZoomFactor, 15)
    }

    var supportsZoom: Bool { maxZoom > 1.01 }

    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = max(1, min(factor, min(device.activeFormat.videoMaxZoomFactor, 15)))
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Zamkne ostření, expozici a vyvážení bílé. Důležité: automatika by jinak
    /// měnila jas obrazu a zhoršovala porovnávání snímků.
    func setLocked(_ locked: Bool) {
        guard let device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusModeSupported(locked ? .locked : .continuousAutoFocus) {
                    device.focusMode = locked ? .locked : .continuousAutoFocus
                }
                if device.isExposureModeSupported(locked ? .locked : .continuousAutoExposure) {
                    device.exposureMode = locked ? .locked : .continuousAutoExposure
                }
                if device.isWhiteBalanceModeSupported(locked ? .locked : .continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = locked ? .locked : .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    /// Zaostří / změří expozici na bod (normalizované souřadnice snímku 0–1).
    func focus(at point: CGPoint) {
        guard let device else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(CIImage(cvPixelBuffer: buffer))
    }

    private enum CameraError: Error { case cannotAdd }
}
