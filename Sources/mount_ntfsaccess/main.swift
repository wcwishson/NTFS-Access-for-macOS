import Darwin
import NTFSMountDaemonCore

@main
public struct MountNTFSAccessMain {
    public static func main() {
        Darwin.exit(MountHelperProcess.run(arguments: Array(CommandLine.arguments.dropFirst())))
    }
}
