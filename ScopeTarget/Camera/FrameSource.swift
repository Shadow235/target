import CoreImage
import Foundation

enum FrameSourceState: Equatable {
    case idle
    case connecting
    case running
    case failed(String)
}

/// Společné rozhraní pro všechny zdroje obrazu.
/// Callbacky se volají na libovolném vlákně na pozadí.
protocol FrameSource: AnyObject {
    var onFrame: ((CIImage) -> Void)? { get set }
    var onStateChange: ((FrameSourceState) -> Void)? { get set }
    var displayName: String { get }
    func start()
    func stop()
}

/// Uložitelný popis zdroje – pamatuje se mezi spuštěními.
enum SourceDescriptor: Codable, Hashable {
    /// AVCaptureDevice.uniqueID (vestavěná nebo USB-C kamera)
    case camera(id: String, name: String)
    /// HTTP MJPEG stream (multipart/x-mixed-replace)
    case mjpeg(url: String)
    /// Opakované stahování JPEG snímku
    case snapshot(url: String, intervalMs: Int)

    var title: String {
        switch self {
        case .camera(_, let name): return name
        case .mjpeg(let url): return "MJPEG \(url)"
        case .snapshot(let url, _): return "Snímek \(url)"
        }
    }

    @MainActor
    func makeSource() -> FrameSource {
        switch self {
        case .camera(let id, _): return CameraFrameSource(deviceID: id)
        case .mjpeg(let url): return MJPEGFrameSource(urlString: url)
        case .snapshot(let url, let ms): return SnapshotFrameSource(urlString: url, intervalMs: ms)
        }
    }
}

/// Přihlašovací údaje zadané přímo v URL (http://user:heslo@192.168.1.10/...).
func credential(from url: URL) -> URLCredential? {
    guard let user = url.user, !user.isEmpty else { return nil }
    return URLCredential(user: user.removingPercentEncoding ?? user,
                         password: url.password?.removingPercentEncoding ?? url.password ?? "",
                         persistence: .forSession)
}
