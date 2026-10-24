import Foundation

public enum NetworkCounterDelta {
    /// Decimal MB/s from real monotonic byte counters. First/reset samples have
    /// no rate; callers wait for a second observation rather than invent zero.
    public static func rates(previousRX: UInt64, previousTX: UInt64, currentRX: UInt64, currentTX: UInt64,
                             elapsed: Double) -> (down: Double, up: Double)? {
        guard elapsed.isFinite, elapsed > 0, currentRX >= previousRX, currentTX >= previousTX else { return nil }
        return (Double(currentRX - previousRX) / elapsed / 1_000_000,
                Double(currentTX - previousTX) / elapsed / 1_000_000)
    }
}
