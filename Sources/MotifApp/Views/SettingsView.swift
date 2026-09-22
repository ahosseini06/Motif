import SwiftUI
import MotifKit

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @State private var key = ""
    @State private var model = Settings.model
    @State private var hasStoredKey = Settings.apiKey != nil
    @State private var checking = false
    @State private var result: (ok: Bool, text: String)?

    var body: some View {
        Form {
            Section {
                SecureField(hasStoredKey ? "•••••••••••• (stored in Keychain)" : "Paste your Gemini API key", text: $key)
                TextField("Model", text: $model, prompt: Text(Settings.defaultModel))
                HStack {
                    Button("Save & Test") { save() }.disabled(checking || (key.isEmpty && !hasStoredKey))
                    if hasStoredKey { Button("Remove Key", role: .destructive) { Settings.apiKey = nil; hasStoredKey = false; result = nil; app.apiKeyChanged() } }
                    if checking { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red).font(.callout).lineLimit(3)
                    }
                }
            } header: { Text("Descriptions — Gemini API") } footer: {
                Text("Use a paid-tier key: Google doesn't train on paid-tier data. Motif sends one small, silent 360p proxy per clip (about 24 frames) plus the camera motion it measured, and nothing from projects set to On-Device Only. Typical cost is around $1 per 1,000 clips.")
                    .foregroundStyle(.secondary)
            }

            Section("On this Mac") {
                LabeledContent("Depth model", value: DepthEstimator.isInstalled ? "Installed (Depth Anything V2 Small, Apache-2.0)" : "Downloads on first project (~50 MB)")
                LabeledContent("Motion spec", value: "version \(MotionSpec.version)")
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        Settings.model = model.trimmingCharacters(in: .whitespaces)
        if !key.isEmpty { Settings.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let stored = Settings.apiKey else { return }
        checking = true; result = nil
        Task {
            do {
                try await GeminiTagger(apiKey: stored, model: Settings.model).verify()
                result = (true, "Key and model work")
                key = ""; hasStoredKey = true
                app.apiKeyChanged()
            } catch {
                result = (false, error.localizedDescription)
            }
            checking = false
        }
    }
}
