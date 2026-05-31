import Foundation
import NTFSAccessCore

@main
struct NewFSNTFSAccessMain {
    static func main() {
        do {
            let invocation = try parseArguments(Array(CommandLine.arguments.dropFirst()))
            let formatter = try FormatterInvocation(label: invocation.label, deviceArgument: invocation.deviceArgument)
            try formatter.run()
        } catch {
            fputs("Error: \(error.localizedDescription)\n", stderr)
            fputs(usage, stderr)
            exit(1)
        }
    }

    private static let usage = """
    usage: newfs_ntfsaccess [-v <volume name>] <device>

    Safety: device must be an external, writable partition such as /dev/disk13s2.
    Developer override for tests/rescue only: NTFSACCESS_ALLOW_UNSAFE_NEWFS_TARGET=1
    """

    private struct ParsedArguments {
        let label: String?
        let deviceArgument: String
    }

    private static func parseArguments(_ arguments: [String]) throws -> ParsedArguments {
        var label: String?
        var index = 0
        var positional: [String] = []

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "-v":
                guard index + 1 < arguments.count else {
                    throw AppError(message: "Missing volume name after -v")
                }
                label = arguments[index + 1]
                index += 2
            case "--help", "-h":
                throw AppError(message: "")
            default:
                if argument.hasPrefix("-") {
                    throw AppError(message: "Unknown option: \(argument)")
                }
                positional.append(argument)
                index += 1
            }
        }

        guard positional.count == 1 else {
            throw AppError(message: "Expected exactly one device argument")
        }

        return ParsedArguments(label: label, deviceArgument: positional[0])
    }

    private struct FormatterInvocation {
        let label: String?
        let geometry: DiskDeviceGeometry

        init(label: String?, deviceArgument: String) throws {
            self.label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.geometry = try DevicePathResolver.diskGeometry(for: deviceArgument)
            let allowUnsafeTarget = ProcessInfo.processInfo.environment["NTFSACCESS_ALLOW_UNSAFE_NEWFS_TARGET"] == "1"
            try DevicePathResolver.validateSafeFormatTarget(geometry, allowUnsafeTarget: allowUnsafeTarget)
        }

        func run() throws {
            guard let mkntfs = DependencyChecker.resolveMKNTFSPath() else {
                throw AppError(message: "mkntfs backend not found")
            }

            var arguments = [
                "-F",
                "-Q",
                "-s", "\(geometry.sectorSize)"
            ]
            if let partitionStartSector = geometry.partitionStartSector {
                arguments += ["-p", "\(partitionStartSector)"]
            }
            if let label, !label.isEmpty {
                arguments += ["-L", label]
            }
            arguments.append(geometry.blockDevicePath)
            arguments.append("\(geometry.totalSectors)")

            _ = try Shell.runChecked(mkntfs, arguments, timeout: 180)

            if let label,
               !label.isEmpty,
               let ntfslabel = DependencyChecker.resolveNTFSLabelPath() {
                _ = try? Shell.run(ntfslabel, [geometry.blockDevicePath, label], timeout: 20)
            }

            print("Created NTFS file system on \(geometry.blockDevicePath)")
        }
    }
}
