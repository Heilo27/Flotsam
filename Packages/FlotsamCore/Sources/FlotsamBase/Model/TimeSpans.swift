import Foundation

/// Fixed time spans in milliseconds, the unit of every stored timestamp (`epochMillis`). One definition of how long
/// an hour and a day are; rules that merely happen to be a day long (the exemption grace, the budget notice
/// throttle) name their own constant from these, so changing one rule never silently changes another.
public enum TimeSpan {
    public static let hourMillis: Int64 = 60 * 60 * 1000
    public static let dayMillis: Int64 = 24 * hourMillis
}
