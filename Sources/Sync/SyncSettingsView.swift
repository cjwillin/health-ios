import SwiftUI

/// Settings screen for the v2 uploader. Base URL + both Cloudflare Access
/// values are stored ONLY in the keychain (kSecClassGenericPassword); the
/// fields are write-only (never re-loaded into the UI after save) and the
/// credential fields are masked.
struct SyncSettingsView: View {
    @ObservedObject private var engine: UploaderEngine
    @StateObject private var model: SyncSettingsModel

    init(engine: UploaderEngine) {
        _engine = ObservedObject(wrappedValue: engine)
        _model = StateObject(wrappedValue: SyncSettingsModel(engine: engine))
    }

    var body: some View {
        Form {
            Section("Cloudflare Access ingress") {
                TextField("Base URL (https://…)", text: $model.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("CF-Access-Client-Id", text: $model.clientId)
                SecureField("CF-Access-Client-Secret", text: $model.clientSecret)
                Button("Save to keychain") { model.save() }
                if !model.saveMessage.isEmpty {
                    Text(model.saveMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section("Diagnostics") {
                Button("Send test upload") { model.sendTestUpload() }
                LabeledContent("Last sync", value: engine.lastSyncAt.map { HealthKitStore.timestamp($0) } ?? "never")
                LabeledContent("Last HTTP result", value: engine.lastHTTPResult)
                    .font(.footnote)
                Text("One diagnostic line (counts and HTTP statuses only — never health values) is posted to /ingest/v2/diag per wake, sync and error.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Upload settings")
    }
}

@MainActor
final class SyncSettingsModel: ObservableObject {
    @Published var baseURL = ""
    @Published var clientId = ""
    @Published var clientSecret = ""
    @Published var saveMessage = ""

    private weak var engine: UploaderEngine?

    init(engine: UploaderEngine) {
        self.engine = engine
    }

    func save() {
        if SyncKeychain.save(baseURL: baseURL, clientId: clientId, clientSecret: clientSecret) {
            saveMessage = "Saved to keychain ✓"
            baseURL = ""
            clientId = ""
            clientSecret = ""
        } else {
            saveMessage = "Save failed — need absolute base URL (https://…) and both CF-Access values."
        }
    }

    func sendTestUpload() {
        guard let engine = engine else {
            saveMessage = "Uploader unavailable."
            return
        }
        saveMessage = "Sending…"
        Task {
            await engine.syncNow(trigger: "manual_test")
            saveMessage = engine.lastHTTPResult
        }
    }
}
