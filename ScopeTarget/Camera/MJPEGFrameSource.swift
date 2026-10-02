import CoreImage
import Foundation

/// HTTP MJPEG stream (multipart/x-mixed-replace) – typické pro IP kamery, ESP32-CAM,
/// OctoPrint/mjpg-streamer, aplikace „IP Webcam“ apod.
/// Snímky se hledají podle JPEG značek SOI (FFD8) a EOI (FFD9), takže nezáleží na tvaru hlaviček.
final class MJPEGFrameSource: NSObject, FrameSource, URLSessionDataDelegate {
    var onFrame: ((CIImage) -> Void)?
    var onStateChange: ((FrameSourceState) -> Void)?

    let urlString: String
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var running = false
    private var receivedFrame = false
    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.qualityOfService = .userInitiated
        return q
    }()

    var displayName: String { "MJPEG \(URL(string: urlString)?.host ?? urlString)" }

    init(urlString: String) {
        self.urlString = urlString
        super.init()
    }

    func start() {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true else {
            onStateChange?(.failed("Neplatná adresa streamu."))
            return
        }
        running = true
        connect(url)
    }

    private func connect(_ url: URL) {
        guard running else { return }
        onStateChange?(.connecting)
        buffer.removeAll(keepingCapacity: true)
        receivedFrame = false
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session?.invalidateAndCancel()
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        let task = session.dataTask(with: url)
        self.task = task
        task.resume()
    }

    func stop() {
        running = false
        task?.cancel()
        session?.invalidateAndCancel()
        session = nil
        onStateChange?(.idle)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.previousFailureCount == 0, let url = URL(string: urlString), let cred = credential(from: url) {
            completionHandler(.useCredential, cred)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        extractFrames()
        // ochrana proti nekonečnému růstu při poškozeném streamu
        if buffer.count > 20_000_000 { buffer.removeAll(keepingCapacity: true) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard running, session === self.session else { return }
        let message = error?.localizedDescription ?? "Stream skončil."
        onStateChange?(.failed("\(message) Zkouším znovu…"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.running, let url = URL(string: self.urlString) else { return }
            self.connect(url)
        }
    }

    private func extractFrames() {
        var latest: Data?
        while true {
            guard let soi = buffer.firstRange(of: Data([0xFF, 0xD8]), in: buffer.startIndex..<buffer.endIndex) else {
                // žádný začátek snímku – ponech poslední bajt (může být půlka značky)
                if buffer.count > 1 { buffer.removeSubrange(buffer.startIndex..<(buffer.endIndex - 1)) }
                break
            }
            guard let eoi = buffer.firstRange(of: Data([0xFF, 0xD9]), in: soi.upperBound..<buffer.endIndex) else {
                if soi.lowerBound > buffer.startIndex { buffer.removeSubrange(buffer.startIndex..<soi.lowerBound) }
                break
            }
            latest = buffer.subdata(in: soi.lowerBound..<eoi.upperBound)
            buffer.removeSubrange(buffer.startIndex..<eoi.upperBound)
        }
        // zpracuj jen nejnovější snímek – starší by zbytečně zvyšovaly zpoždění
        guard let jpeg = latest, let image = CIImage(data: jpeg, options: [.applyOrientationProperty: true]) else { return }
        if !receivedFrame {
            receivedFrame = true
            onStateChange?(.running)
        }
        onFrame?(image)
    }
}

/// Periodické stahování jednoho JPEG snímku (např. http://kamera/snapshot.jpg).
/// Pomalejší než MJPEG, ale funguje téměř s každou IP kamerou.
final class SnapshotFrameSource: FrameSource {
    var onFrame: ((CIImage) -> Void)?
    var onStateChange: ((FrameSourceState) -> Void)?

    let urlString: String
    let intervalMs: Int
    private var loop: Task<Void, Never>?

    var displayName: String { "Snímek \(URL(string: urlString)?.host ?? urlString)" }

    init(urlString: String, intervalMs: Int) {
        self.urlString = urlString
        self.intervalMs = max(100, intervalMs)
    }

    func start() {
        guard let url = URL(string: urlString) else {
            onStateChange?(.failed("Neplatná adresa snímku."))
            return
        }
        onStateChange?(.connecting)
        let interval = UInt64(intervalMs) * 1_000_000
        loop = Task.detached(priority: .userInitiated) { [weak self] in
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
            if let cred = credential(from: url), let user = cred.user {
                let token = Data("\(user):\(cred.password ?? "")".utf8).base64EncodedString()
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
            var wasRunning = false
            while !Task.isCancelled {
                do {
                    let (data, _) = try await URLSession.shared.data(for: request)
                    if let image = CIImage(data: data, options: [.applyOrientationProperty: true]) {
                        if !wasRunning { wasRunning = true; self?.onStateChange?(.running) }
                        self?.onFrame?(image)
                    }
                } catch {
                    if Task.isCancelled { break }
                    wasRunning = false
                    self?.onStateChange?(.failed("Snímek nelze stáhnout: \(error.localizedDescription)"))
                }
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        onStateChange?(.idle)
    }
}
