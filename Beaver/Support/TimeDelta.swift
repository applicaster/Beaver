//
//  TimeDelta.swift
//  Beaver
//

import Foundation

/// Signed, compact time difference for the Log feed's Δ column.
public enum TimeDelta {
    public static func text(milliseconds ms: Int64) -> String {
        let sign = ms < 0 ? "−" : "+"
        let magnitude = Int(ms.magnitude)
        switch magnitude {
        case ..<1_000:
            return "\(sign)\(magnitude) ms"
        case ..<60_000:
            return sign + String(format: "%.3f s", Double(magnitude) / 1_000)
        case ..<3_600_000:
            let seconds = magnitude / 1_000
            return sign + String(format: "%ldm %02lds", seconds / 60, seconds % 60)
        default:
            let minutes = magnitude / 60_000
            return sign + String(format: "%ldh %02ldm", minutes / 60, minutes % 60)
        }
    }
}
