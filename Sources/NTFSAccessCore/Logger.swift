import Foundation
import OSLog

public enum Log {
    private static let subsystem = "com.ntfsaccess"
    private static let runtime = Logger(subsystem: subsystem, category: "runtime")

    public static func info(_ message: String) {
        runtime.info("\(message, privacy: .public)")
    }

    public static func warning(_ message: String) {
        runtime.warning("\(message, privacy: .public)")
    }

    public static func error(_ message: String) {
        runtime.error("\(message, privacy: .public)")
    }
}
