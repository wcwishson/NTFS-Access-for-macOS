import AppKit
import Darwin
import NTFSMountDaemonCore

if let helperIndex = CommandLine.arguments.firstIndex(of: "--mount-helper") {
    let helperArguments = Array(CommandLine.arguments.dropFirst(helperIndex + 1))
    Darwin.exit(MountHelperProcess.run(arguments: helperArguments))
}

if CommandLine.arguments.contains("--mountd") {
    MountDaemonProcess.run()
    Darwin.exit(0)
}

let app = NSApplication.shared
let delegate = AppController()
app.delegate = delegate
app.run()
