import SwiftUI
import HitCore

/// Pravý panel: statistika skupiny, seznam ran a akce.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var showHistory: Bool
    @State private var confirmReplace = false

    var body: some View {
        VStack(spacing: 0) {
            statsPanel
                .padding()
            Divider()
            shotList
            Divider()
            actions.padding()
        }
        .background(Color(white: 0.08))
        .confirmationDialog("Byl terč vyměněn nebo přelepen?", isPresented: $confirmReplace, titleVisibility: .visible) {
            Button("Ano – nová reference a nová série") { model.targetReplaced() }
            Button("Zrušit", role: .cancel) {}
        } message: {
            Text("Aplikace si znovu nasnímá čistý terč. Aktuální série se uloží do historie.")
        }
    }

    // MARK: Statistika

    private var statsPanel: some View {
        let s = model.session
        let g = s.stats
        let d = s.calibration.distanceM
        let scored = s.calibration.target.scored
        return VStack(alignment: .leading, spacing: 10) {
            Text(s.name).font(.headline).lineLimit(1)
            HStack(alignment: .firstTextBaseline) {
                bigStat("\(g.count)", "ran")
                if scored {
                    Spacer()
                    bigStat("\(g.totalScore)", g.xCount > 0 ? "bodů (\(g.xCount)×X)" : "bodů")
                    Spacer()
                    bigStat(g.count > 0 ? String(format: "%.1f", g.averageScore) : "–", "průměr")
                }
            }
            if g.count >= 2 {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    statRow("Rozptyl (ES)", mm: g.extremeSpreadMM, d: d)
                    statRow("Stř. poloměr", mm: g.meanRadiusMM, d: d)
                    statRow("Šířka × výška", text: String(format: "%.0f × %.0f mm", g.widthMM, g.heightMM))
                }
                .font(.callout)
            }
            if g.count >= 1 {
                correction(g.center, d: d)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(size: 34, weight: .bold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func statRow(_ title: String, mm: Double, d: Double) -> some View {
        statRow(title, text: String(format: "%.0f mm · %.2f MOA · %.2f mrad",
                                    mm, Angular.moa(mm, distanceM: d), Angular.mrad(mm, distanceM: d)))
    }

    private func statRow(_ title: String, text: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(text).monospacedDigit()
        }
    }

    /// Kam posunout zaměřovač, aby se střed skupiny dostal do středu terče.
    private func correction(_ c: PointMM, d: Double) -> some View {
        let h = Angular.mrad(abs(c.x), distanceM: d)
        let v = Angular.mrad(abs(c.y), distanceM: d)
        let hMOA = Angular.moa(abs(c.x), distanceM: d)
        let vMOA = Angular.moa(abs(c.y), distanceM: d)
        return VStack(alignment: .leading, spacing: 2) {
            Text("Střed skupiny: \(directionText(c))").font(.callout)
            Text("Korekce: \(c.y > 0 ? "dolů" : "nahoru") \(String(format: "%.2f mrad / %.1f MOA", v, vMOA)), "
                 + "\(c.x > 0 ? "vlevo" : "vpravo") \(String(format: "%.2f mrad / %.1f MOA", h, hMOA))")
                .font(.caption).foregroundStyle(.secondary)
            Text("na \(Int(d)) m").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: Seznam ran

    private var shotList: some View {
        List(selection: Binding(get: { model.selectedShotID }, set: { model.selectedShotID = $0 })) {
            ForEach(model.session.shots.reversed()) { shot in
                HStack {
                    Text("\(shot.number)").font(.headline).monospacedDigit().frame(width: 32, alignment: .leading)
                    if let s = shot.score {
                        Text(shot.isX ? "X" : "\(s)")
                            .font(.title3.bold()).monospacedDigit()
                            .foregroundStyle(s == 0 ? .red : .yellow)
                            .frame(width: 34)
                    }
                    Text(directionText(shot.position)).font(.callout).monospacedDigit()
                    Spacer()
                    if shot.manual { Image(systemName: "hand.tap").foregroundStyle(.secondary) }
                    Text(shot.time, format: .dateTime.hour().minute().second())
                        .font(.caption).foregroundStyle(.secondary)
                }
                .tag(shot.id)
                .swipeActions {
                    Button(role: .destructive) { model.deleteShot(shot.id) } label: {
                        Label("Smazat", systemImage: "trash")
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.session.shots.isEmpty {
                Text(model.armed ? "Čekám na zásah…" : "Zatím žádné rány")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Akce

    private var actions: some View {
        VStack(spacing: 10) {
            HStack {
                Button { model.undoLast() } label: { Label("Zpět", systemImage: "arrow.uturn.backward") }
                    .disabled(model.session.shots.isEmpty)
                Spacer()
                Button { model.newSeries() } label: { Label("Nová série", systemImage: "plus.square.on.square") }
            }
            HStack {
                Button { confirmReplace = true } label: { Label("Nový terč", systemImage: "arrow.triangle.2.circlepath") }
                Spacer()
                if let url = SessionStore.exportCSV(model.session), !model.session.shots.isEmpty {
                    ShareLink(item: url) { Label("CSV", systemImage: "square.and.arrow.up") }
                }
                Button { showHistory = true } label: { Label("Historie", systemImage: "clock") }
            }
        }
        .buttonStyle(.bordered)
    }
}
