import Foundation
import HealthKit

/// Real HealthKit implementation of SyncSourceProviding.
///
/// Samples: one HKAnchoredObjectQuery per wire type — returns only NEW or
/// CHANGED samples plus deletions since the last persisted anchor.
/// Buckets: HKStatisticsCollectionQuery (.cumulativeSum, midnight anchor,
/// 1-hour intervals) per bucket type for today; BucketMath turns the per-hour
/// sums into the cumulative-from-midnight wire array.
final class HealthKitSyncSource: SyncSourceProviding {
    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore) {
        self.healthStore = healthStore
    }

    private struct QuantitySpec {
        let wire: String
        let type: HKQuantityType
        let unit: HKUnit
        let scale: Double
        let unitLabel: String
    }

    private static let quantitySpecs: [QuantitySpec] = [
        QuantitySpec(wire: "heart_rate", type: HKQuantityType(.heartRate),
                     unit: .count().unitDivided(by: .minute()), scale: 1, unitLabel: "count/min"),
        QuantitySpec(wire: "hrv_sdms", type: HKQuantityType(.heartRateVariabilitySDNN),
                     unit: .second(), scale: 1000, unitLabel: "ms"),
        QuantitySpec(wire: "resting_heart_rate", type: HKQuantityType(.restingHeartRate),
                     unit: .count().unitDivided(by: .minute()), scale: 1, unitLabel: "count/min"),
        QuantitySpec(wire: "respiratory_rate", type: HKQuantityType(.respiratoryRate),
                     unit: .count().unitDivided(by: .minute()), scale: 1, unitLabel: "count/min"),
        QuantitySpec(wire: "spo2", type: HKQuantityType(.oxygenSaturation),
                     unit: .percent(), scale: 1, unitLabel: "%"),
    ]

    private struct BucketSpec {
        let wire: String
        let type: HKQuantityType
        let unit: HKUnit
    }

    private static let bucketSpecs: [BucketSpec] = [
        BucketSpec(wire: "steps", type: HKQuantityType(.stepCount), unit: .count()),
        BucketSpec(wire: "active_energy", type: HKQuantityType(.activeEnergyBurned), unit: .kilocalorie()),
        BucketSpec(wire: "basal_energy", type: HKQuantityType(.basalEnergyBurned), unit: .kilocalorie()),
        BucketSpec(wire: "distance", type: HKQuantityType(.distanceWalkingRunning), unit: .meter()),
        BucketSpec(wire: "daylight", type: HKQuantityType(.timeInDaylight), unit: .minute()),
        BucketSpec(wire: "flights", type: HKQuantityType(.flightsClimbed), unit: .count()),
    ]

    private struct AnchoredPage {
        let samples: [HKSample]
        let deleted: [HKDeletedObject]
        let anchor: HKQueryAnchor?
    }

    // MARK: - SyncSourceProviding

    func collectPayload(storedAnchors: [String: Data]) async throws -> (payload: SyncPayload, newAnchors: [String: Data]) {
        let now = Date()
        var samples: [SampleDTO] = []
        var deleted: [DeletedDTO] = []
        var newAnchors: [String: Data] = [:]

        for spec in Self.quantitySpecs {
            let page = try await anchoredPage(type: spec.type, anchor: Self.anchor(fromData: storedAnchors[spec.wire]))
            for sample in page.samples {
                guard let quantitySample = sample as? HKQuantitySample else { continue }
                let value = quantitySample.quantity.doubleValue(for: spec.unit) * spec.scale
                samples.append(SampleDTO(
                    type: spec.wire,
                    uuid: sample.uuid.uuidString,
                    start: WireFormats.iso8601(sample.startDate),
                    end: WireFormats.iso8601(sample.endDate),
                    value: WireFormats.numberString(value),
                    unit: spec.unitLabel,
                    durationMin: nil,
                    kcal: nil
                ))
            }
            for removed in page.deleted {
                deleted.append(DeletedDTO(type: spec.wire, uuid: removed.uuid.uuidString))
            }
            if let anchor = page.anchor {
                newAnchors[spec.wire] = Self.anchorData(anchor)
            }
        }

        let sleepPage = try await anchoredPage(type: HKCategoryType(.sleepAnalysis),
                                               anchor: Self.anchor(fromData: storedAnchors["sleep_stage"]))
        for sample in sleepPage.samples {
            guard let category = sample as? HKCategorySample,
                  let stage = Self.wireStage(category.value) else { continue }
            samples.append(SampleDTO(
                type: "sleep_stage",
                uuid: sample.uuid.uuidString,
                start: WireFormats.iso8601(sample.startDate),
                end: WireFormats.iso8601(sample.endDate),
                value: stage,
                unit: nil,
                durationMin: nil,
                kcal: nil
            ))
        }
        for removed in sleepPage.deleted {
            deleted.append(DeletedDTO(type: "sleep_stage", uuid: removed.uuid.uuidString))
        }
        if let anchor = sleepPage.anchor {
            newAnchors["sleep_stage"] = Self.anchorData(anchor)
        }

        let workoutPage = try await anchoredPage(type: HKWorkoutType.workoutType(),
                                                 anchor: Self.anchor(fromData: storedAnchors["workout"]))
        for sample in workoutPage.samples {
            guard let workout = sample as? HKWorkout else { continue }
            let kcal = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie())
            samples.append(SampleDTO(
                type: "workout",
                uuid: sample.uuid.uuidString,
                start: WireFormats.iso8601(sample.startDate),
                end: WireFormats.iso8601(sample.endDate),
                value: nil,
                unit: nil,
                durationMin: Self.rounded(workout.duration / 60),
                kcal: kcal.map(Self.rounded)
            ))
        }
        for removed in workoutPage.deleted {
            deleted.append(DeletedDTO(type: "workout", uuid: removed.uuid.uuidString))
        }
        if let anchor = workoutPage.anchor {
            newAnchors["workout"] = Self.anchorData(anchor)
        }

        let buckets = try await collectBuckets(now: now)
        let payload = SyncPayload(
            date: WireFormats.dayString(for: now),
            buckets: buckets.isEmpty ? nil : buckets,
            samples: samples.isEmpty ? nil : samples,
            deleted: deleted.isEmpty ? nil : deleted
        )
        return (payload, newAnchors)
    }

    // MARK: - Wire value mapping

    /// HKCategoryValueSleepAnalysis -> wire stage string. In-bed samples are
    /// not representable on the wire (nil = skip).
    static func wireStage(_ rawValue: Int) -> String? {
        switch HKCategoryValueSleepAnalysis(rawValue: rawValue) {
        case .asleepCore: return "asleep_core"
        case .asleepDeep: return "asleep_deep"
        case .asleepREM: return "asleep_rem"
        case .awake: return "awake"
        case .inBed: return nil
        default: return "asleep_unspecified"
        }
    }

    static func rounded(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    // MARK: - Anchored queries (one-shot)

    private func anchoredPage(type: HKSampleType, anchor: HKQueryAnchor?) async throws -> AnchoredPage {
        let store = healthStore
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKAnchoredObjectQuery(type: type, predicate: nil, anchor: anchor, limit: HKObjectQueryNoLimit) { query, samples, deleted, newAnchor, error in
                store.stop(query) // HKAnchoredObjectQuery is long-running; make it one-shot
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: AnchoredPage(samples: samples ?? [], deleted: deleted ?? [], anchor: newAnchor))
                }
            }
            store.execute(query)
        }
    }

    // MARK: - Today's cumulative hourly buckets

    private func collectBuckets(now: Date) async throws -> [BucketSeriesDTO] {
        let startOfDay = Calendar.current.startOfDay(for: now)
        var series: [BucketSeriesDTO] = []
        for spec in Self.bucketSpecs {
            let perHour = try await hourlySums(type: spec.type, unit: spec.unit, startOfDay: startOfDay, now: now)
            series.append(BucketSeriesDTO(type: spec.wire, values: BucketMath.cumulative24(perHour: perHour)))
        }
        return series
    }

    private func hourlySums(type: HKQuantityType, unit: HKUnit, startOfDay: Date, now: Date) async throws -> [Double?] {
        var perHour = [Double?](repeating: nil, count: BucketMath.hoursPerDay)
        let predicate = HKQuery.predicateForSamples(withStart: startOfDay, end: now)
        let query = HKStatisticsCollectionQuery(
            quantityType: type,
            quantitySamplePredicate: predicate,
            options: .cumulativeSum,
            anchorDate: startOfDay,
            intervalComponents: DateComponents(hour: 1)
        )
        let store = healthStore
        let collection: HKStatisticsCollection = try await withCheckedThrowingContinuation { continuation in
            query.initialResultsHandler = { query, results, error in
                store.stop(query)
                if let error {
                    continuation.resume(throwing: error)
                } else if let results {
                    continuation.resume(returning: results)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "HealthKitSyncSource",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "statistics query returned neither results nor error"]
                    ))
                }
            }
            store.execute(query)
        }
        let calendar = Calendar.current
        collection.enumerateStatistics(from: startOfDay, to: now) { statistics, _ in
            let hour = calendar.component(.hour, from: statistics.startDate)
            guard hour >= 0, hour < BucketMath.hoursPerDay else { return }
            if let sum = statistics.sumQuantity() {
                perHour[hour] = sum.doubleValue(for: unit)
            }
        }
        return perHour
    }

    // MARK: - Anchor (de)serialization

    private static func anchorData(_ anchor: HKQueryAnchor) -> Data {
        (try? NSKeyedArchiver.archivedData(withRootObject: anchor, requiringSecureCoding: true)) ?? Data()
    }

    private static func anchor(fromData data: Data?) -> HKQueryAnchor? {
        guard let data = data, !data.isEmpty else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: data)
    }
}
