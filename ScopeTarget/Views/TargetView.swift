import SwiftUI
import HitCore

/// Narovnaný terč se zakreslenými kruhy a zásahy.
struct TargetView: View {
    enum Tool: String, CaseIterable, Identifiable {
        case select = "Výběr"
        case add = "Přidat ránu"
        case center = "Střed terče"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .select: return "hand.point.up.left"
            case .add: return "plus.circle"
            case .center: return "scope"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State private var tool: Tool = .select
    @State private var draggingShot: Shot.ID?
    @State private var dragPoint: PointMM?
    @State private var banner: Shot?
    @State private var zoom: CGFloat = 1
    @State private var pinchBase: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            if let base = model.targetFrame ?? fallbackFrame {
                let frame = withCurrentCenter(base)
                let fit = FitGeometry(imageSize: CGSize(width: frame.widthPx, height: frame.heightPx),
                                      container: geo.size)
                let scale = fit.rect.width / CGFloat(frame.widthPx)
                ZStack {
                    content(frame: frame, fit: fit, scale: scale)
                        .scaleEffect(zoom, anchor: zoomAnchor(frame: frame, fit: fit, size: geo.size))
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .clipped()
                .contentShape(Rectangle())
                .gesture(dragGesture(frame: frame, fit: fit, scale: scale, size: geo.size))
                .simultaneousGesture(
                    MagnifyGesture()
                        .onChanged { zoom = min(8, max(1, pinchBase * $0.magnification)) }
                        .onEnded { _ in pinchBase = zoom }
                )
            } else {
                Text("Nejprve vyznačte terč v režimu Kamera")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { toolBar.padding() }
        .overlay(alignment: .top) { bannerView.padding(.top, 16) }
        .onChange(of: model.session.shots.count) { old, new in
            guard new > old, let last = model.session.shots.last, !last.manual else { return }
            withAnimation(.spring) { banner = last }
            let id = last.id
            Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if banner?.id == id { withAnimation { banner = nil } }
            }
        }
    }

    /// Při zoomu drž střed skupiny (nebo terče) uprostřed.
    private func zoomAnchor(frame: TargetFrame, fit: FitGeometry, size: CGSize) -> UnitPoint {
        let focus = model.session.shots.isEmpty ? PointMM.zero : model.session.stats.center
        let px = frame.toPx(focus)
        let x = (fit.rect.minX + px.x * fit.rect.width / CGFloat(frame.widthPx)) / size.width
        let y = (fit.rect.minY + px.y * fit.rect.height / CGFloat(frame.heightPx)) / size.height
        return UnitPoint(x: min(1, max(0, x)), y: min(1, max(0, y)))
    }

    /// Střed kruhů vždy podle aktuální kalibrace (procesor ho může mít o snímek starší).
    private func withCurrentCenter(_ f: TargetFrame) -> TargetFrame {
        var f = f
        f.centerOffsetMM = model.session.calibration.centerOffsetMM
        return f
    }

    /// Bez živého obrazu (např. prohlížení staré relace) použij rozměry z kalibrace.
    private var fallbackFrame: TargetFrame? {
        let c = model.session.calibration
        guard c.isSet else { return nil }
        let k = 1000 / max(c.faceWidthMM, c.faceHeightMM)
        return TargetFrame(widthPx: Int(c.faceWidthMM * k), heightPx: Int(c.faceHeightMM * k),
                           faceWidthMM: c.faceWidthMM, faceHeightMM: c.faceHeightMM,
                           centerOffsetMM: c.centerOffsetMM)
    }

    @ViewBuilder
    private func content(frame: TargetFrame, fit: FitGeometry, scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            if let img = model.rectified {
                Image(decorative: img, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .frame(width: fit.rect.width, height: fit.rect.height)
                    .position(x: fit.rect.midX, y: fit.rect.midY)
            } else {
                Rectangle().fill(Color(white: 0.92))
                    .frame(width: fit.rect.width, height: fit.rect.height)
                    .position(x: fit.rect.midX, y: fit.rect.midY)
            }
            if model.showDiff, let diff = model.diffImage {
                Image(decorative: diff, scale: 1)
                    .resizable()
                    .colorMultiply(.red)
                    .blendMode(.screen)
                    .frame(width: fit.rect.width, height: fit.rect.height)
                    .position(x: fit.rect.midX, y: fit.rect.midY)
            }
            Canvas { ctx, _ in
                drawOverlay(ctx: ctx, frame: frame, fit: fit, scale: scale)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Kreslení

    private func viewPoint(_ p: PointMM, frame: TargetFrame, fit: FitGeometry, scale: CGFloat) -> CGPoint {
        let px = frame.toPx(p)
        return CGPoint(x: fit.rect.minX + px.x * scale, y: fit.rect.minY + px.y * scale)
    }

    private func drawOverlay(ctx: GraphicsContext, frame: TargetFrame, fit: FitGeometry, scale: CGFloat) {
        let cal = model.session.calibration
        let target = cal.target
        let ppm = frame.pxPerMM * scale
        let center = viewPoint(.zero, frame: frame, fit: fit, scale: scale)

        // kruhy – kontrola, že střed a měřítko sedí s natištěným terčem
        if target.scored {
            for s in stride(from: target.maxScore, to: target.maxScore - target.ringCount, by: -1) {
                let r = target.ringRadius(forScore: s) * ppm
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.cyan.opacity(0.45)), lineWidth: 1)
            }
            if let x = target.xDiameterMM {
                let r = x / 2 * ppm
                ctx.stroke(Path(ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.cyan.opacity(0.45)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
        }
        var cross = Path()
        cross.move(to: CGPoint(x: center.x - 12, y: center.y)); cross.addLine(to: CGPoint(x: center.x + 12, y: center.y))
        cross.move(to: CGPoint(x: center.x, y: center.y - 12)); cross.addLine(to: CGPoint(x: center.x, y: center.y + 12))
        ctx.stroke(cross, with: .color(tool == .center ? .yellow : .cyan), lineWidth: tool == .center ? 2 : 1)

        let shots = model.session.shots
        guard !shots.isEmpty else { return }

        // střed skupiny
        let g = model.session.stats
        if shots.count >= 2 {
            let gc = viewPoint(g.center, frame: frame, fit: fit, scale: scale)
            var p = Path()
            p.move(to: CGPoint(x: gc.x - 9, y: gc.y - 9)); p.addLine(to: CGPoint(x: gc.x + 9, y: gc.y + 9))
            p.move(to: CGPoint(x: gc.x + 9, y: gc.y - 9)); p.addLine(to: CGPoint(x: gc.x - 9, y: gc.y + 9))
            ctx.stroke(p, with: .color(.blue), lineWidth: 2.5)
            let r = g.meanRadiusMM * ppm
            ctx.stroke(Path(ellipseIn: CGRect(x: gc.x - r, y: gc.y - r, width: 2 * r, height: 2 * r)),
                       with: .color(.blue.opacity(0.6)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }

        let holeR = max(7, cal.caliberMM / 2 * ppm)
        for (i, shot) in shots.enumerated() {
            let pos = (shot.id == draggingShot ? dragPoint : nil) ?? shot.position
            let c = viewPoint(pos, frame: frame, fit: fit, scale: scale)
            let isLast = i == shots.count - 1
            let color: Color = isLast ? .red : .orange
            let rect = CGRect(x: c.x - holeR, y: c.y - holeR, width: 2 * holeR, height: 2 * holeR)
            ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.35)))
            ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: isLast ? 3 : 2)
            if shot.id == model.selectedShotID {
                ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -5, dy: -5)), with: .color(.white), lineWidth: 2)
            }
            let label = Text("\(shot.number)").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
            ctx.draw(label, at: CGPoint(x: c.x + holeR + 8, y: c.y - holeR - 4))
        }
    }

    // MARK: Gesta

    private func mmPoint(_ loc: CGPoint, frame: TargetFrame, fit: FitGeometry, scale: CGFloat, size: CGSize) -> PointMM {
        // zpětný převod scaleEffect
        let a = zoomAnchor(frame: frame, fit: fit, size: size)
        let ax = a.x * size.width, ay = a.y * size.height
        let ux = ax + (loc.x - ax) / zoom, uy = ay + (loc.y - ay) / zoom
        return frame.toMM(x: (ux - fit.rect.minX) / scale, y: (uy - fit.rect.minY) / scale)
    }

    private func dragGesture(frame: TargetFrame, fit: FitGeometry, scale: CGFloat, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let p = mmPoint(v.location, frame: frame, fit: fit, scale: scale, size: size)
                switch tool {
                case .select:
                    if draggingShot == nil, hypot(v.translation.width, v.translation.height) > 6,
                       let sel = model.selectedShotID,
                       let shot = model.session.shots.first(where: { $0.id == sel }) {
                        let start = mmPoint(v.startLocation, frame: frame, fit: fit, scale: scale, size: size)
                        let tolMM = 30 / (frame.pxPerMM * scale * zoom)
                        if hypot(shot.position.x - start.x, shot.position.y - start.y) < tolMM {
                            draggingShot = sel
                        }
                    }
                    if draggingShot != nil { dragPoint = p }
                case .center, .add:
                    break
                }
            }
            .onEnded { v in
                let p = mmPoint(v.location, frame: frame, fit: fit, scale: scale, size: size)
                let isTap = hypot(v.translation.width, v.translation.height) <= 6
                switch tool {
                case .select:
                    if let id = draggingShot, let dp = dragPoint {
                        model.moveShot(id, to: dp)
                    } else if isTap {
                        let tolMM = 30 / (frame.pxPerMM * scale * zoom)
                        let nearest = model.session.shots.min {
                            hypot($0.position.x - p.x, $0.position.y - p.y) < hypot($1.position.x - p.x, $1.position.y - p.y)
                        }
                        if let n = nearest, hypot(n.position.x - p.x, n.position.y - p.y) < tolMM {
                            model.selectedShotID = n.id
                        } else {
                            model.selectedShotID = nil
                        }
                    }
                    draggingShot = nil
                    dragPoint = nil
                case .add:
                    if isTap {
                        model.addShot(at: p, manual: true)
                        tool = .select
                    }
                case .center:
                    if isTap { model.setCenter(atCurrentMM: p) }
                }
            }
    }

    // MARK: Ovládání

    private var toolBar: some View {
        HStack(spacing: 12) {
            Picker("Nástroj", selection: $tool) {
                ForEach(Tool.allCases) { Label($0.rawValue, systemImage: $0.icon).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 380)

            if let sel = model.selectedShotID {
                Button(role: .destructive) { model.deleteShot(sel) } label: {
                    Label("Smazat ránu", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            Spacer()
            if zoom > 1.01 {
                Button { withAnimation { zoom = 1; pinchBase = 1 } } label: {
                    Label(String(format: "%.1f×", zoom), systemImage: "arrow.down.right.and.arrow.up.left")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var bannerView: some View {
        if let shot = banner {
            HStack(spacing: 16) {
                Text("Rána \(shot.number)").font(.title2.bold())
                if let s = shot.score {
                    Text(shot.isX ? "X" : "\(s)")
                        .font(.system(size: 44, weight: .heavy, design: .rounded))
                        .foregroundStyle(.yellow)
                }
                Text(directionText(shot.position)).font(.title3).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24).padding(.vertical, 10)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// „↑ 21 mm  ← 42 mm“
func directionText(_ p: PointMM) -> String {
    let v = abs(p.y) < 0.5 ? "" : "\(p.y > 0 ? "↑" : "↓") \(Int(abs(p.y).rounded())) mm"
    let h = abs(p.x) < 0.5 ? "" : "\(p.x > 0 ? "→" : "←") \(Int(abs(p.x).rounded())) mm"
    let s = [v, h].filter { !$0.isEmpty }.joined(separator: "  ")
    return s.isEmpty ? "střed" : s
}
