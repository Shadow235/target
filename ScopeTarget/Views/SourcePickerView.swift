import AVFoundation
import SwiftUI

struct SourcePickerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var devices: [AVCaptureDevice] = []
    @State private var url = "http://192.168.4.1:81/stream"
    @State private var isSnapshot = false
    @State private var intervalMs = 500.0

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if devices.isEmpty {
                        Text("Žádná kamera nenalezena").foregroundStyle(.secondary)
                    }
                    ForEach(devices, id: \.uniqueID) { d in
                        Button {
                            model.connect(.camera(id: d.uniqueID, name: d.localizedName))
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: d.deviceType == .external ? "cable.connector" : "camera")
                                VStack(alignment: .leading) {
                                    Text(d.localizedName)
                                    Text(kind(d)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if case .camera(let id, _) = model.prefs.source, id == d.uniqueID {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    Button("Obnovit seznam", systemImage: "arrow.clockwise") { refresh() }
                } header: {
                    Text("Kamery")
                } footer: {
                    Text("USB-C kamera (UVC) se zobrazí po připojení k iPadu. Vestavěnou kameru použijte s digiscoping adaptérem na okulár.")
                }

                Section {
                    TextField("URL", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Typ", selection: $isSnapshot) {
                        Text("MJPEG stream").tag(false)
                        Text("JPEG snímek").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if isSnapshot {
                        Stepper("Interval \(Int(intervalMs)) ms", value: $intervalMs, in: 100...5000, step: 100)
                    }
                    Button("Připojit", systemImage: "wifi") {
                        let clean = url.trimmingCharacters(in: .whitespaces)
                        model.connect(isSnapshot ? .snapshot(url: clean, intervalMs: Int(intervalMs)) : .mjpeg(url: clean))
                        dismiss()
                    }
                    .disabled(URL(string: url.trimmingCharacters(in: .whitespaces)) == nil)
                } header: {
                    Text("WiFi kamera")
                } footer: {
                    Text("Příklady: ESP32-CAM http://192.168.4.1:81/stream · IP Webcam http://IP:8080/video · snímek http://IP/snapshot.jpg. Přihlášení: http://uzivatel:heslo@IP/… RTSP zatím není podporováno – většina kamer nabízí i MJPEG nebo snímek.")
                }

                if model.source != nil {
                    Section {
                        Button("Odpojit zdroj", role: .destructive) {
                            model.disconnect()
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Zdroj obrazu")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Hotovo") { dismiss() } }
            }
        }
        .onAppear {
            refresh()
            switch model.prefs.source {
            case .mjpeg(let u): url = u; isSnapshot = false
            case .snapshot(let u, let ms): url = u; isSnapshot = true; intervalMs = Double(ms)
            default: break
            }
        }
    }

    private func refresh() {
        devices = CameraFrameSource.availableDevices()
    }

    private func kind(_ d: AVCaptureDevice) -> String {
        if d.deviceType == .external { return "Externí USB-C kamera" }
        switch d.position {
        case .back: return "Zadní kamera iPadu"
        case .front: return "Přední kamera iPadu"
        default: return "Kamera"
        }
    }
}
