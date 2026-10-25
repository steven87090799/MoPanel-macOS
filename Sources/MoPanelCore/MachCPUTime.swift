import Foundation

public enum MachCPUTime {
    /// PROC_PIDTASKINFO totals are Mach absolute-time ticks. Intel often has a
    /// 1:1 timebase; Apple Silicon does not. Convert only after taking the delta
    /// in integer space, avoiding overflow from multiplying lifetime totals.
    public static func percentage(deltaTicks: UInt64, elapsedSeconds: Double,
                                  numerator: UInt32, denominator: UInt32) -> Double? {
        guard numerator > 0, denominator > 0, elapsedSeconds.isFinite, elapsedSeconds > 0 else { return nil }
        let value = Double(deltaTicks) * Double(numerator) / Double(denominator) / 1e9 / elapsedSeconds * 100
        return value.isFinite ? value : nil
    }
}
