import Foundation
import HealthKit
import UIKit

/// All HealthKit interaction for the spike: authorization, today's step count,
/// and the HKObserverQuery + enableBackgroundDelivery wiring for stepCount.
/// Every background wake is appended (timestamped) to `wakeLog` for the spike
/// screen, so the owner can count wakes without a Mac.
@MainActor
final class HealthKitStore: ObservableObject {
    @Published private(set) var authorizationStatus = "not requested yet"
    @Published private(set) var backgroundDeliveryStatus = "not enabled yet"
    @Published private(set) var observerStatus = "not registered yet"
    @Published private(set) var stepsToday: Int?
    @Published private(set) var stepsFetchedAt: Date?
    @Published private(set) var wakeLog: [String] = []

    private let healthStore = HKHealthStore()
    private var observerRegistered = false
    private var sawInitialObserverCall = false

    static let readTypes: Set<HKSampleType> = [
        HKQuantityType(.stepCount),
        HKQuantityType(.heartRate),
        HKCategoryType(.sleepAnalysis),
        HKWorkoutType.workoutType(),
    ]

    func authorizeAndStart() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            authorizationStatus = "HealthKit UNAVAILABLE on this device"
            log("ERROR: HKHealthStore.isHealthDataAvailable() == false")
            return
        }
        do {
            try await healthStore.requestAuthorization(toShare: [], read: Self.readTypes)
            authorizationStatus = "authorized (read: steps, HR, sleep, workouts)"
            log("HealthKit read authorization granted")
        } catch {
            authorizationStatus = "authorization FAILED: \(error.localizedDescription)"
            log("ERROR: authorization failed: \(error.localizedDescription)")
            return
        }
        await refreshSteps()
        startObserverAndBackgroundDelivery()
    }

    /// Cumulative step count from start of day to now (Health app semantics).
    func refreshSteps() async {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: Date())
        let stepType = HKQuantityType(.stepCount)
        let steps: Int = await withCheckedContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: stepType,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, _ in
                let sum = statistics?.sumQuantity()?.doubleValue(for: .count()) ?? 0
                continuation.resume(returning: Int(sum.rounded()))
            }
            self.healthStore.execute(query)
        }
        stepsToday = steps
        stepsFetchedAt = Date()
    }

    /// HKObserverQuery for stepCount + enableBackgroundDelivery(.immediate).
    /// The observer fires once at registration ("initial anchor call") and then
    /// once per new stepCount sample delivered while the app is suspended.
    private func startObserverAndBackgroundDelivery() {
        guard !observerRegistered else { return }
        observerRegistered = true
        let stepType = HKQuantityType(.stepCount)

        healthStore.enableBackgroundDelivery(for: stepType, frequency: .immediate) { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if success {
                    self.backgroundDeliveryStatus = "enabled (stepCount, .immediate)"
                    self.log("background delivery ENABLED for stepCount")
                } else {
                    self.backgroundDeliveryStatus = "FAILED: \(error?.localizedDescription ?? "unknown error")"
                    self.log("ERROR: enableBackgroundDelivery failed: \(error?.localizedDescription ?? "unknown")")
                }
            }
        }

        let query = HKObserverQuery(sampleType: stepType, predicate: nil) { [weak self] completion in
            // Private HealthKit queue. Must call `completion` when done.
            guard let self else { completion(); return }
            DispatchQueue.main.async {
                let initial = !self.sawInitialObserverCall
                self.sawInitialObserverCall = true
                // Hold background runtime while refreshing, then report done.
                var bgTask: UIBackgroundTaskIdentifier = .invalid
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "HKObserver-stepCount") {
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                        bgTask = .invalid
                    }
                }
                Task { @MainActor in
                    if initial {
                        self.observerStatus = "registered (initial anchor call done)"
                        self.log("HKObserverQuery registered — initial anchor call")
                    } else {
                        self.log("BACKGROUND WAKE  \(Self.timestamp())")
                    }
                    await self.refreshSteps()
                    if bgTask != .invalid {
                        UIApplication.shared.endBackgroundTask(bgTask)
                    }
                    completion()
                }
            }
        }
        healthStore.execute(query)
    }

    // MARK: - Helpers

    func log(_ line: String) {
        wakeLog.insert("\(Self.timestamp())  \(line)", at: 0)
        if wakeLog.count > 200 {
            wakeLog.removeLast(wakeLog.count - 200)
        }
    }

    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
