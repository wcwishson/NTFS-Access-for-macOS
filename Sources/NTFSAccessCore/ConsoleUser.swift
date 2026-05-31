import Darwin
import Foundation

public struct ConsoleUser {
    public let uid: UInt32
    public let gid: UInt32

    public init(uid: UInt32, gid: UInt32) {
        self.uid = uid
        self.gid = gid
    }

    public static func current() -> ConsoleUser {
        var statBuffer = stat()
        if stat("/dev/console", &statBuffer) == 0 {
            return ConsoleUser(uid: statBuffer.st_uid, gid: statBuffer.st_gid)
        }

        return ConsoleUser(uid: getuid(), gid: getgid())
    }
}
