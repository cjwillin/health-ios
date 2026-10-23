import SwiftUI

struct ContentView: View {
    @StateObject private var store = HealthKitStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    LabeledContent("Authorization", value: store.authorizationStatus)
                    LabeledContent("Background delivery", value: store.backgroundDeliveryStatus)
                    LabeledContent("Observer", value: store.observerStatus)
                    LabeledContent("Build", value: Self.buildLabel)
                }

                Section("Today's steps") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.stepsToday.map { "\($0)" } ?? "—")
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .contentTransition(.numericText())
                        if let at = store.stepsFetchedAt {
                            Text("fetched \(HealthKitStore.timestamp(at))")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("HealthKit wake log (newest first)") {
                    if store.wakeLog.isEmpty {
                        Text("No wakes yet. Keep the phone with you and walk — each new step sample in the background appends a line here. Reopening the app also refreshes the count.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(Array(store.wakeLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.footnote, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Health Sync")
        }
        .task { await store.authorizeAndStart() }
        .refreshable { await store.refreshAndSync(trigger: "app_open") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await store.refreshAndSync(trigger: "app_open") }
            }
        }
    }

    private static var buildLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(version) (\(build))"
    }
}
