import SwiftUI
import HitCore

/// Živý obraz z kamery + vyznačení terče čtyřmi rohy.
struct CameraView: View {
    @Environment(AppModel.self) private var model
    @State private var dragCorners: [CGPoint]?

    var body: some View {
        GeometryReader { geo in
            let imgSize = model.rawSize == .zero ? CGSize(width: 16, height: 9) : model.rawSize
            let fit = FitGeometry(imageSize: imgSize, container: geo.size)
            let corners = dragCorners ?? model.prefs.calibration.corners

            ZStack(alignment: .topLeading) {
                if let img = model.rawPreview {
                    Image(decorative: img, scale: 1)
                        .resizable()
                        .frame(width: fit.rect.width, height: fit.rect.height)
                        .position(x: fit.rect.midX, y: fit.rect.midY)
                } else {
                    placeholder.frame(width: geo.size.width, height: geo.size.height)
                }

                if model.rawPreview != nil {
                    quad(corners.map(fit.view))
                    ForEach(0..<4, id: \.self) { i in
                        handle(index: i, at: fit.view(corners[i]), fit: fit)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: "camera")
            .overlay(alignment: .bottom) { controls.padding() }
            .overlay(alignment: .top) { hint.padding(.top, 12) }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 12) {
            ProgressView().opacity(model.sourceState == .connecting ? 1 : 0)
            Text(model.source == nil ? "Vyberte zdroj obrazu" : model.statusText)
                .foregroundStyle(.secondary)
        }
    }

    private var hint: some View {
        Text("Přetáhněte rohy na okraje terče (vlevo nahoře → vpravo nahoře → vpravo dole → vlevo dole)")
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(.black.opacity(0.6), in: Capsule())
            .opacity(model.rawPreview == nil ? 0 : 1)
    }

    private func quad(_ pts: [CGPoint]) -> some View {
        Path { p in
            p.move(to: pts[0])
            for q in pts.dropFirst() { p.addLine(to: q) }
            p.closeSubpath()
        }
        .stroke(Color.green, style: StrokeStyle(lineWidth: 2, dash: [8, 5]))
        .allowsHitTesting(false)
    }

    private func handle(index: Int, at point: CGPoint, fit: FitGeometry) -> some View {
        let labels = ["LH", "PH", "PD", "LD"]
        return ZStack {
            Circle().fill(Color.green.opacity(0.25)).frame(width: 56, height: 56)
            Circle().stroke(Color.green, lineWidth: 2).frame(width: 22, height: 22)
            Text(labels[index]).font(.caption2.bold()).offset(y: -24)
        }
        .position(point)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("camera"))
                .onChanged { v in
                    var c = dragCorners ?? model.prefs.calibration.corners
                    c[index] = fit.normalized(v.location)
                    dragCorners = c
                }
                .onEnded { _ in
                    if let c = dragCorners {
                        model.updateCalibration { $0.corners = c }
                    }
                    dragCorners = nil
                }
        )
    }

    private var controls: some View {
        HStack(spacing: 16) {
            if let cam = model.cameraSource, cam.supportsZoom {
                Image(systemName: "minus.magnifyingglass")
                Slider(value: Binding(get: { Double(model.zoom) }, set: { model.setZoom(CGFloat($0)) }),
                       in: 1...Double(cam.maxZoom))
                    .frame(width: 220)
                Text(String(format: "%.1f×", model.zoom)).monospacedDigit().frame(width: 50)
            }
            if model.cameraSource != nil {
                Button {
                    model.toggleCameraLock()
                } label: {
                    Label(model.cameraLocked ? "Expozice zamčena" : "Zamknout expozici",
                          systemImage: model.cameraLocked ? "lock.fill" : "lock.open")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            Button {
                model.confirmCalibration()
            } label: {
                Label("Potvrdit terč", systemImage: "checkmark.circle.fill").font(.headline)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.rawPreview == nil)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
