import CoreGraphics
import Foundation
import HitCore

/// Kalibrace: kde je terč v obraze a jaké má rozměry.
struct Calibration: Codable, Equatable {
    /// Rohy plochy terče v normalizovaných souřadnicích snímku (0–1, počátek vlevo nahoře):
    /// vlevo nahoře, vpravo nahoře, vpravo dole, vlevo dole.
    var corners: [CGPoint] = [CGPoint(x: 0.3, y: 0.2), CGPoint(x: 0.7, y: 0.2),
                              CGPoint(x: 0.7, y: 0.8), CGPoint(x: 0.3, y: 0.8)]
    var isSet = false
    var target: RingTarget = .generic100m
    /// Skutečné rozměry vyznačené plochy (obvykle papír terče).
    var faceWidthMM: Double = RingTarget.generic100m.faceWidthMM
    var faceHeightMM: Double = RingTarget.generic100m.faceHeightMM
    /// Posun středu kruhů vůči středu vyznačené plochy.
    var centerOffsetMM: PointMM = .zero
    var caliberMM: Double = 7.62
    var distanceM: Double = 100
}

struct Shot: Codable, Identifiable, Equatable {
    var id = UUID()
    var number: Int
    var time: Date
    var position: PointMM
    var score: Int?
    var isX: Bool
    var manual: Bool
    var detectedDiameterMM: Double?
}

struct ShootingSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var started = Date()
    var name: String
    var calibration: Calibration
    var shots: [Shot] = []

    var stats: GroupStats {
        GroupStats(points: shots.map(\.position),
                   scores: shots.compactMap(\.score),
                   xs: shots.filter(\.isX).count)
    }

    /// Přepočet bodů po změně terče / ráže / středu.
    mutating func rescore() {
        for i in shots.indices {
            let s = calibration.target.score(at: shots[i].position, caliberMM: calibration.caliberMM)
            shots[i].score = calibration.target.scored ? s.score : nil
            shots[i].isX = s.isX
        }
    }

    mutating func renumber() {
        for i in shots.indices { shots[i].number = i + 1 }
    }

    func csv() -> String {
        let f = ISO8601DateFormatter()
        var lines = ["cislo;cas;x_mm;y_mm;vzdalenost_mm;body;x;rucne"]
        for s in shots {
            lines.append([
                "\(s.number)", f.string(from: s.time),
                String(format: "%.1f", s.position.x), String(format: "%.1f", s.position.y),
                String(format: "%.1f", s.position.distance),
                s.score.map(String.init) ?? "", s.isX ? "1" : "0", s.manual ? "1" : "0"
            ].joined(separator: ";"))
        }
        return lines.joined(separator: "\n")
    }
}

/// Ukládání relací jako JSON do složky Dokumenty (přístupné i z aplikace Soubory).
enum SessionStore {
    private static var directory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Relace", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func save(_ session: ShootingSession) {
        let url = directory.appendingPathComponent("\(session.id.uuidString).json")
        if let data = try? encoder.encode(session) { try? data.write(to: url, options: .atomic) }
    }

    static func loadAll() -> [ShootingSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(ShootingSession.self, from: Data(contentsOf: $0)) }
            .sorted { $0.started > $1.started }
    }

    static func delete(_ session: ShootingSession) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(session.id.uuidString).json"))
    }

    static func exportCSV(_ session: ShootingSession) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(session.name.replacingOccurrences(of: "/", with: "-")).csv")
        do {
            try session.csv().write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}

/// Nastavení, která se pamatují mezi spuštěními.
struct AppPreferences: Codable, Equatable {
    var source: SourceDescriptor?
    var calibration = Calibration()
    var threshold: Float = 30
    var confirmFrames = 3
    var announce = true
    var playSound = true

    private static let key = "AppPreferences.v1"

    static func load() -> AppPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(AppPreferences.self, from: data) else { return AppPreferences() }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
