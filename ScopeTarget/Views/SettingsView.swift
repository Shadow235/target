import SwiftUI
import HitCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let cal = model.prefs.calibration
        NavigationStack {
            Form {
                Section("Terč") {
                    Picker("Předvolba", selection: Binding(
                        get: { cal.target.id },
                        set: { id in
                            if let t = RingTarget.presets.first(where: { $0.id == id }) { model.applyPreset(t) }
                        })) {
                        ForEach(RingTarget.presets) { Text($0.name).tag($0.id) }
                        if !RingTarget.presets.contains(where: { $0.id == cal.target.id }) {
                            Text(cal.target.name).tag(cal.target.id)
                        }
                    }
                    number("Šířka vyznačené plochy", value: cal.faceWidthMM, unit: "mm") { v in
                        model.updateCalibration { $0.faceWidthMM = v }
                    }
                    number("Výška vyznačené plochy", value: cal.faceHeightMM, unit: "mm") { v in
                        model.updateCalibration { $0.faceHeightMM = v }
                    }
                    if cal.target.scored {
                        number("Průměr nejvyššího kruhu", value: cal.target.innerDiameterMM, unit: "mm") { v in
                            model.updateCalibration { $0.target.innerDiameterMM = v; $0.target.id = "custom"; $0.target.name = "Vlastní" }
                        }
                        number("Šířka kruhu", value: cal.target.ringWidthMM, unit: "mm") { v in
                            model.updateCalibration { $0.target.ringWidthMM = v; $0.target.id = "custom"; $0.target.name = "Vlastní" }
                        }
                        Stepper("Počet kruhů: \(cal.target.ringCount)", value: Binding(
                            get: { cal.target.ringCount },
                            set: { n in model.updateCalibration { $0.target.ringCount = n; $0.target.id = "custom"; $0.target.name = "Vlastní" } }
                        ), in: 1...20)
                    }
                    Button("Vynulovat střed kruhů") { model.updateCalibration { $0.centerOffsetMM = .zero } }
                }

                Section {
                    number("Ráže (průměr střely)", value: cal.caliberMM, unit: "mm") { v in
                        model.updateCalibration { $0.caliberMM = v }
                    }
                    number("Vzdálenost terče", value: cal.distanceM, unit: "m") { v in
                        model.updateCalibration { $0.distanceM = v }
                    }
                } header: {
                    Text("Zbraň")
                } footer: {
                    Text("Ráže určuje očekávanou velikost průstřelu a bodování (dotyk čáry = vyšší hodnota). Vzdálenost slouží pro přepočet na MOA / mrad.")
                }

                Section {
                    VStack(alignment: .leading) {
                        Text("Citlivost: \(Int(100 - model.prefs.threshold))")
                        Slider(value: Binding(get: { Double(100 - model.prefs.threshold) },
                                              set: { model.prefs.threshold = Float(100 - $0) }),
                               in: 20...92, step: 1)
                    }
                    Stepper("Potvrzení po \(model.prefs.confirmFrames) snímcích", value: $model.prefs.confirmFrames, in: 2...8)
                    Toggle("Zobrazit rozdílový obraz (ladění)", isOn: $model.showDiff)
                    resolutionInfo
                } header: {
                    Text("Detekce")
                } footer: {
                    Text("Vyšší citlivost zachytí i malé díry na velkou vzdálenost, ale víc reaguje na tetelení vzduchu. Víc potvrzovacích snímků = méně falešných zásahů, ale pomalejší hlášení.")
                }

                Section("Hlášení") {
                    Toggle("Hlasové hlášení zásahu", isOn: $model.prefs.announce)
                    Toggle("Zvuk při zásahu", isOn: $model.prefs.playSound)
                }

                Section {
                    Button("Znovu vyznačit terč") {
                        model.updateCalibration { $0.isSet = false }
                        model.armed = false
                        model.mode = .camera
                        dismiss()
                    }
                }
            }
            .navigationTitle("Nastavení")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
        }
    }

    @ViewBuilder
    private var resolutionInfo: some View {
        if let f = model.targetFrame {
            let holePx = model.prefs.calibration.caliberMM * f.pxPerMM
            LabeledContent("Rozlišení terče", value: String(format: "%.2f px/mm · průstřel ≈ %.1f px", f.pxPerMM, holePx))
            if holePx < 3 {
                Label("Průstřel je v obraze menší než 3 px – zvětšete zoom dalekohledu, nebo vyznačte menší oblast.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }
        }
    }

    private func number(_ title: String, value: Double, unit: String, set: @escaping (Double) -> Void) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, value: Binding(get: { value }, set: { if $0 > 0 { set($0) } }),
                          format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 100)
                Text(unit).foregroundStyle(.secondary)
            }
        }
    }
}
