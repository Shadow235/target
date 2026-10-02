import SwiftUI
import HitCore

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSource = false
    @State private var showSettings = false
    @State private var showHistory = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                ZStack {
                    Color.black
                    switch model.mode {
                    case .camera: CameraView()
                    case .target: TargetView()
                    }
                }
            }
            Divider()
            SidebarView(showHistory: $showHistory)
                .frame(width: 340)
        }
        .sheet(isPresented: $showSource) { SourcePickerView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showHistory) { HistoryView() }
        .onAppear { if model.source == nil { showSource = true } }
    }

    private var toolbar: some View {
        @Bindable var model = model
        return HStack(spacing: 14) {
            Picker("Režim", selection: $model.mode) {
                ForEach(MainMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)

            Button { showSource = true } label: {
                Label(model.source?.displayName ?? "Zdroj", systemImage: "video")
                    .lineLimit(1)
            }

            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(model.statusText).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()

            Button { showSettings = true } label: { Image(systemName: "gearshape") }
                .font(.title3)

            Button {
                model.armed.toggle()
            } label: {
                Label(model.armed ? "Detekce běží" : "Spustit detekci",
                      systemImage: model.armed ? "stop.circle.fill" : "scope")
                    .font(.headline)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.armed ? .red : .green)
            .disabled(!model.prefs.calibration.isSet || model.source == nil)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var statusColor: Color {
        switch model.sourceState {
        case .running:
            if case .disturbed = model.detectorStatus, model.armed { return .orange }
            return model.armed ? .green : .yellow
        case .connecting: return .yellow
        case .failed: return .red
        case .idle: return .gray
        }
    }
}

/// Umístění obrazu s „aspect fit“ v kontejneru a převody souřadnic.
struct FitGeometry {
    let rect: CGRect

    init(imageSize: CGSize, container: CGSize) {
        guard imageSize.width > 0, imageSize.height > 0 else { rect = .zero; return }
        let s = min(container.width / imageSize.width, container.height / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        rect = CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    func normalized(_ p: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)),
                y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }

    func view(_ n: CGPoint) -> CGPoint {
        CGPoint(x: rect.minX + n.x * rect.width, y: rect.minY + n.y * rect.height)
    }
}
