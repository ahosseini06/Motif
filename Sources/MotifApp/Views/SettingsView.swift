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
                SecureField(hasStoredKey ? "•••••••••••• (stored in your Keychain)" : "Paste your Gemini API key", text: $key)
                TextField("Model", text: $model, prompt: Text(Settings.defaultModel))
                HStack {
                    Button("Save & Test") { save() }.disabled(checking || (key.isEmpty && !hasStoredKey))
                    Link("Get a key…", destination: Self.keyPage).help(Self.keyPage.absoluteString)
                    if hasStoredKey { Button("Remove Key", role: .destructive) { Settings.apiKey = nil; hasStoredKey = false; result = nil; app.apiKeyChanged() } }
                    if checking { ProgressView().controlSize(.small) }
                    if let result {
                        Label(result.text, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(result.ok ? .green : .red).font(.callout).lineLimit(3)
                    }
                }
            } header: { Text("Descriptions — your Gemini API key") } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Motif has no account and no server of its own: descriptions are billed to your key, and nothing else about it leaves this Mac. The key is stored in your login Keychain — or set GEMINI_API_KEY in the environment, which wins over it.")
                    Text("Each clip costs one request carrying a silent 360p proxy (about 24 frames) and the camera motion measured on this Mac — roughly $1 per 1,000 clips. A free key works for trying it out, with much lower rate limits and Google reserving the right to train on what you send; for client footage use a paid-tier key, which they don't train on. Projects set to On-Device Only never upload anything at all.")
                }
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

    static let keyPage = URL(string: "https://aistudio.google.com/apikey")!

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
