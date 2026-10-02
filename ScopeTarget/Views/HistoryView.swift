import SwiftUI
import HitCore

struct HistoryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ShootingSession] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(sessions) { s in
                    Button {
                        model.loadSession(s)
                        model.mode = .target
                        dismiss()
                    } label: {
                        row(s)
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            SessionStore.delete(s)
                            sessions.removeAll { $0.id == s.id }
                        } label: { Label("Smazat", systemImage: "trash") }
                    }
                }
            }
            .overlay {
                if sessions.isEmpty { Text("Žádné uložené relace").foregroundStyle(.secondary) }
            }
            .navigationTitle("Historie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
        }
        .onAppear { sessions = SessionStore.loadAll().filter { !$0.shots.isEmpty || $0.id == model.session.id } }
    }

    private func row(_ s: ShootingSession) -> some View {
        let g = s.stats
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.headline)
                Text("\(s.calibration.target.name) · \(Int(s.calibration.distanceM)) m")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(g.count) ran" + (s.calibration.target.scored ? " · \(g.totalScore) b." : ""))
                if g.count >= 2 {
                    Text(String(format: "ES %.0f mm · %.2f MOA", g.extremeSpreadMM,
                                Angular.moa(g.extremeSpreadMM, distanceM: s.calibration.distanceM)))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if s.id == model.session.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
        }
        .foregroundStyle(.primary)
    }
}
