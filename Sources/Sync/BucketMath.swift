import Foundation

/// Pure math for the wire bucket arrays: `values[i]` is the cumulative sum
/// from local midnight through the end of hour i (index 0 = hour 00). Hours
/// before the first hour with any data are JSON null ("nulls before first
/// data"); from the first data hour through hour 23 the latest cumulative
/// value is carried forward. Empty day -> all null.
enum BucketMath {
    static let hoursPerDay = 24

    static func cumulative24(perHour: [Double?]) -> [Double?] {
        var values = [Double?](repeating: nil, count: hoursPerDay)
        var running = 0.0
        var sawData = false
        for hour in 0 ..< hoursPerDay {
            guard hour < perHour.count, let sum = perHour[hour] else { continue }
            sawData = true
            running += sum
            values[hour] = running
        }
        guard sawData else { return values }
        var last: Double?
        for hour in 0 ..< hoursPerDay {
            if let value = values[hour] {
                last = value
            } else if let current = last {
                values[hour] = current
            }
        }
        return values
    }
}
