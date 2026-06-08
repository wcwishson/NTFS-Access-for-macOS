import XCTest

final class PackagingMetadataTests: XCTestCase {
    func testLaunchDaemonRunsMainAppInMountDaemonModeAndAssociatesMainApp() throws {
        let plist = try readPlist("Packaging/LaunchDaemons/com.ntfsaccess.mountd.plist")

        let programArguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(
            programArguments,
            [
                "/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp",
                "--mountd"
            ]
        )

        let associatedBundleIdentifiers = try XCTUnwrap(plist["AssociatedBundleIdentifiers"] as? [String])
        XCTAssertTrue(associatedBundleIdentifiers.contains("com.ntfsaccess.menu"))
        XCTAssertFalse(associatedBundleIdentifiers.contains("com.ntfsaccess.mountd"))
    }

    func testMenuAppCanRunMountDaemonMode() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/main.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("CommandLine.arguments.contains(\"--mountd\")"))
        XCTAssertTrue(source.contains("MountDaemonProcess.run()"))
    }

    func testMenuAppCanRunFilesystemMountHelperMode() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/main.swift"), encoding: .utf8)
        let package = try String(contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("\"--mount-helper\""))
        XCTAssertTrue(source.contains("MountHelperProcess.run(arguments: helperArguments)"))
        XCTAssertTrue(package.contains("MountHelperProcess.swift") || package.contains("NTFSMountDaemonCore"))
    }

    func testMenuAppDashboardUsesExistingXPCAndKeepsAccessoryQuitMenu() throws {
        let appController = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/AppController.swift"), encoding: .utf8)
        let dashboardController = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/VolumeDashboardWindowController.swift"), encoding: .utf8)
        let launchPreferences = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/AppLaunchPreferences.swift"), encoding: .utf8)
        let viewModel = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/VolumeStatusViewModel.swift"), encoding: .utf8)
        let appPackageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)

        XCTAssertTrue(appController.contains("NSApp.setActivationPolicy(.accessory)"))
        XCTAssertTrue(appController.contains("NSApp.setActivationPolicy(.regular)"))
        XCTAssertTrue(appController.contains("showDashboardWindow()\n            return"))
        XCTAssertTrue(appController.contains("makeKeyAndOrderFront"))
        XCTAssertTrue(appController.contains("NSApp.activate(ignoringOtherApps: true)"))
        XCTAssertTrue(appController.contains("shouldShowDashboardAfterLaunch"))
        XCTAssertTrue(appController.contains("ProcessInfo.processInfo.environment[\"XPC_SERVICE_NAME\"]"))
        XCTAssertTrue(appController.contains("\"com.ntfsaccess.menu\""))
        XCTAssertTrue(appController.contains("AppLaunchPreferences.shared.startMinimized"))
        XCTAssertTrue(appController.contains("applicationDidBecomeActive"))
        XCTAssertTrue(appController.contains("shouldShowDashboardOnNextActivation"))
        XCTAssertTrue(appController.contains("applicationShouldHandleReopen"))
        XCTAssertTrue(appController.contains("dashboardDidClose"))
        XCTAssertTrue(appController.contains("statusMenu.addItem(quitItem)"))
        XCTAssertTrue(appController.contains("showDashboardWindow()"))
        XCTAssertTrue(dashboardController.contains("NSWindowDelegate"))
        XCTAssertTrue(dashboardController.contains("windowWillClose"))
        XCTAssertTrue(dashboardController.contains("windowDidResize"))
        XCTAssertTrue(dashboardController.contains("FlippedDocumentView"))
        XCTAssertTrue(dashboardController.contains("updateRowsDocumentFrame"))
        XCTAssertTrue(dashboardController.contains("rowsStack.fittingSize"))
        XCTAssertTrue(dashboardController.contains("scrollView.contentSize.width"))
        XCTAssertTrue(dashboardController.contains("Fix"))
        XCTAssertTrue(dashboardController.contains("Rescan"))
        XCTAssertTrue(dashboardController.contains("Start with this Mac"))
        XCTAssertTrue(dashboardController.contains("Start minimized"))
        XCTAssertTrue(dashboardController.contains("handleStartWithMacToggle"))
        XCTAssertTrue(dashboardController.contains("handleStartMinimizedToggle"))
        XCTAssertTrue(dashboardController.contains("Open in Finder"))
        XCTAssertTrue(dashboardController.contains("Details"))
        XCTAssertTrue(launchPreferences.contains("StartMinimizedAtLogin"))
        XCTAssertTrue(launchPreferences.contains("print-disabled"))
        XCTAssertTrue(launchPreferences.contains("enabled|disabled"))
        XCTAssertTrue(launchPreferences.contains("launchctl"))
        XCTAssertTrue(launchPreferences.contains("/Library/LaunchAgents/com.ntfsaccess.menu.plist"))
        XCTAssertTrue(launchPreferences.contains("com.ntfsaccess.menu"))
        XCTAssertTrue(viewModel.contains("getVolumeStates"))
        XCTAssertTrue(viewModel.contains("Task { @MainActor [weak self] in\n                switch result"))
        XCTAssertTrue(viewModel.contains("scanNow"))
        XCTAssertTrue(viewModel.contains("repairVolume"))
        XCTAssertTrue(viewModel.contains("userFacingOperationMessage"))
        XCTAssertTrue(viewModel.contains("case \"interval\", \"startup\", \"coalesced\", \"disk appeared\", \"disk disappeared\", \"disk changed\":"))
        XCTAssertTrue(viewModel.contains("No external NTFS drives connected."))
        XCTAssertTrue(viewModel.contains("readWriteWarning"))
        XCTAssertTrue(viewModel.contains("readOnlyFallback"))
        XCTAssertTrue(viewModel.contains("failedToMount"))
        XCTAssertTrue(dashboardController.contains("case .green"))
        XCTAssertTrue(dashboardController.contains("case .yellow"))
        XCTAssertTrue(dashboardController.contains("case .red"))
        XCTAssertTrue(dashboardController.contains("case .gray"))
        XCTAssertFalse(appPackageScript.contains("LSUIElement"))
    }

    func testMenuAppPackageProvidesDockIcon() throws {
        let appPackageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)
        let iconGenerator = repositoryRoot().appendingPathComponent("scripts/generate_app_icon.swift")
        let iconResource = repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/Resources/AppIcon.icns")

        XCTAssertTrue(FileManager.default.fileExists(atPath: iconGenerator.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: iconResource.path))
        XCTAssertTrue(appPackageScript.contains("AppIcon.icns"))
        XCTAssertTrue(appPackageScript.contains("<key>CFBundleIconFile</key>"))
        XCTAssertTrue(appPackageScript.contains("<string>AppIcon</string>"))
        XCTAssertTrue(appPackageScript.contains("$RESOURCES_DIR/AppIcon.icns"))
    }

    func testFilesystemBundleMountHelperIsStandaloneExecutable() throws {
        let package = try String(contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
        let mountHelperMain = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/mount_ntfsaccess/main.swift"), encoding: .utf8)

        XCTAssertTrue(package.contains(".executable(name: \"mount_ntfsaccess\", targets: [\"mount_ntfsaccess\"])"))
        XCTAssertTrue(package.contains("name: \"mount_ntfsaccess\""))
        XCTAssertTrue(mountHelperMain.contains("MountHelperProcess.run(arguments: Array(CommandLine.arguments.dropFirst()))"))
    }

    func testMountDaemonCoreIsSharedByStandaloneAndMainAppEntrypoints() throws {
        let package = try String(contentsOf: repositoryRoot().appendingPathComponent("Package.swift"), encoding: .utf8)
        let mountdMain = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/mountd/main.swift"), encoding: .utf8)

        XCTAssertTrue(package.contains("name: \"NTFSMountDaemonCore\""))
        XCTAssertTrue(package.contains("dependencies: [\"NTFSMountDaemonCore\"]"))
        XCTAssertTrue(package.contains("name: \"mount_ntfsaccess\""))
        XCTAssertTrue(mountdMain.contains("import NTFSMountDaemonCore"))
        XCTAssertTrue(mountdMain.contains("MountDaemonProcess.run()"))
    }

    func testPackageAppScriptDoesNotCreateSeparateHelperAppForMountDaemon() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("NTFS Access Helper.app"))
        XCTAssertFalse(script.contains("HELPER_APP_DIR"))
        XCTAssertFalse(script.contains(".build/release/mountd\" \"$HELPER"))
    }

    func testPackageAppScriptBundlesRuntimeNTFSToolchainInsideApp() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain"))
        XCTAssertTrue(script.contains("copy_toolchain_binary"))
        XCTAssertTrue(script.contains("ntfs-3g.probe"))
        XCTAssertTrue(script.contains("libntfs-3g.89.dylib"))
        XCTAssertTrue(script.contains("install_name_tool"))
        XCTAssertTrue(script.contains("-change \"$MANAGED_TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib\""))
        XCTAssertTrue(script.contains("@loader_path/../lib/libntfs-3g.89.dylib"))
    }

    func testPackageAppScriptBundlesUserFacingControlToolsInsideApp() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("\"$ROOT_DIR/.build/release/ntfsaccessctl\" \"$MACOS_DIR/ntfsaccessctl\""))
        XCTAssertTrue(script.contains("\"$ROOT_DIR/.build/release/newfs_ntfsaccess\" \"$MACOS_DIR/newfs_ntfsaccess\""))
        XCTAssertTrue(script.contains("chmod 755 \"$MACOS_DIR/ntfsaccessctl\" \"$MACOS_DIR/newfs_ntfsaccess\""))
        XCTAssertTrue(script.contains("codesign_file \"$MACOS_DIR/ntfsaccessctl\""))
        XCTAssertTrue(script.contains("codesign_file \"$MACOS_DIR/newfs_ntfsaccess\""))
    }

    func testPackageAppScriptPrefersStableLocalSigningIdentityWhenAvailable() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("LOCAL_CODESIGN_IDENTITY=\"${NTFSACCESS_LOCAL_CODESIGN_IDENTITY:-NTFS Access Local Signing}\""))
        XCTAssertTrue(script.contains("NTFSACCESS_CODESIGN_IDENTITY"))
        XCTAssertTrue(script.contains("security find-certificate -c \"$LOCAL_CODESIGN_IDENTITY\""))
        XCTAssertTrue(script.contains("CODESIGN_IDENTITY=\"-\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign --force --sign \"$CODESIGN_IDENTITY\""))
        XCTAssertTrue(script.contains("codesign_file \"$TOOLCHAIN_LIB_DIR/libntfs-3g.89.dylib\""))
        XCTAssertTrue(script.contains("codesign_file \"$TOOLCHAIN_BIN_DIR/$binary\""))
        XCTAssertTrue(script.contains("codesign_file \"$TOOLCHAIN_SBIN_DIR/$binary\""))
        XCTAssertFalse(script.contains("/usr/bin/codesign --force --sign - \"$HELPER_APP_DIR\""))
        XCTAssertTrue(script.contains("codesign_file \"$APP_DIR\""))
        XCTAssertTrue(script.contains("/usr/bin/codesign --verify --deep --strict \"$APP_DIR\""))
    }

    func testPackagePkgScriptCopiesSignedAppBundleAsBundle() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("/usr/bin/ditto --noextattr --noqtn \"$DIST_DIR/NTFS Access.app\" \"$PKGROOT/Applications/NTFS Access.app\""))
        XCTAssertFalse(script.contains("\"$DIST_DIR/NTFS Access.app/Contents/MacOS/NTFSMenuApp\" \"$PKGROOT/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp\""))
    }

    func testDistributionDeclaresAppleSiliconAndIntelArchitectures() throws {
        let distribution = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/distribution.xml"), encoding: .utf8)

        XCTAssertTrue(distribution.contains("hostArchitectures=\"arm64,x86_64\""))
        XCTAssertFalse(distribution.contains("<options hostArchitectures=\"arm64,x86_64\"/>\n  <options"))
    }

    func testPackageVersionMetadataIsConsistentForCurrentBuild() throws {
        let expectedVersion = "1.0.2"
        let appPackageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_app.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let distribution = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/distribution.xml"), encoding: .utf8)
        let filesystemInfo = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Info.plist"), encoding: .utf8)

        XCTAssertTrue(appPackageScript.contains("<string>\(expectedVersion)</string>"))
        XCTAssertTrue(packageScript.contains("--version \"\(expectedVersion)\""))
        XCTAssertTrue(distribution.contains("version=\"\(expectedVersion)\""))
        XCTAssertTrue(filesystemInfo.contains("<string>\(expectedVersion)</string>"))
    }

    func testPackageDoesNotInstallUnusedHiddenMountDaemonBinary() throws {
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)
        let postinstall = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Scripts/postinstall"), encoding: .utf8)

        XCTAssertFalse(packageScript.contains(".build/release/mountd"))
        XCTAssertFalse(packageScript.contains("Application Support/NTFSAccess/mountd"))
        XCTAssertFalse(verifier.contains("require_installed_path \"$target_root\" \"/Library/Application Support/NTFSAccess/mountd\""))
        XCTAssertFalse(verifier.contains("require_payload_entry \"$payload\" \"./Library/Application Support/NTFSAccess/mountd\""))
        XCTAssertTrue(postinstall.contains("rm -f \"$APP_SUPPORT/mountd\""))
    }

    func testPackagePkgScriptInstallsManagedToolchainForFilesystemBundle() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("$PKGROOT/Library/NTFSAccess/toolchain/bin"))
        XCTAssertTrue(script.contains("$PKGROOT/Library/NTFSAccess/toolchain/sbin"))
        XCTAssertTrue(script.contains("$PKGROOT/Library/NTFSAccess/toolchain/lib"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/bin/ntfs-3g"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/bin/ntfsfix"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/sbin/mkntfs"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/sbin/ntfslabel"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib"))
    }

    func testVerifierChecksAppBundledControlTools() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("/Applications/NTFS Access.app/Contents/MacOS/ntfsaccessctl"))
        XCTAssertTrue(script.contains("/Applications/NTFS Access.app/Contents/MacOS/newfs_ntfsaccess"))
        XCTAssertTrue(script.contains("require_payload_entry \"$payload\" \"./Applications/NTFS Access.app/Contents/MacOS/ntfsaccessctl\""))
        XCTAssertTrue(script.contains("require_payload_entry \"$payload\" \"./Applications/NTFS Access.app/Contents/MacOS/newfs_ntfsaccess\""))
    }

    func testFilesystemBundleMountHelperDelegatesThroughInstalledAppWrapper() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let validator = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/validate_filesystem_bundle.sh"), encoding: .utf8)
        let wrapperPath = repositoryRoot().appendingPathComponent("Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess")
        let wrapper = try String(contentsOf: wrapperPath, encoding: .utf8)

        XCTAssertFalse(script.contains(".build/release/mount_ntfsaccess"))
        XCTAssertTrue(script.contains("Library/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess"))
        XCTAssertTrue(validator.contains("Contents/Resources/mount_ntfsaccess"))
        XCTAssertTrue(validator.contains("/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"))
        XCTAssertTrue(validator.contains("--mount-helper"))
        XCTAssertTrue(wrapper.contains("exec \"$APP_HELPER\" --mount-helper \"$@\""))
        XCTAssertTrue(script.contains("/usr/bin/install -m 755 \"$ROOT_DIR/Packaging/Filesystems/ntfsaccess.fs/Contents/Resources/mount_ntfsaccess\""))
    }

    func testVerifierExpectsManagedToolchainAndNoSeparateHelperApp() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/bin/ntfs-3g"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/bin/ntfs-3g.probe"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/bin/ntfsfix"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/sbin/mkntfs"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/sbin/ntfslabel"))
        XCTAssertTrue(script.contains("Library/NTFSAccess/toolchain/lib/libntfs-3g.89.dylib"))
        XCTAssertTrue(script.contains("require_removed_path \"$target_root\" \"/Library/NTFSAccess\""))
        XCTAssertFalse(script.contains("NTFS Access Helper.app"))
    }

    func testCLIExposesDestructiveNTFSPartitionCommand() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)
        let partitionerSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/NTFSPartitioner.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("case \"partition-ntfs\""))
        XCTAssertTrue(source.contains("--yes-destroy"))
        XCTAssertTrue(source.contains("--confirm"))
        XCTAssertTrue(source.contains("dryRunSummary(request: request)"))
        XCTAssertTrue(source.contains("partition(request: request, confirmation: typedConfirmation)"))
        XCTAssertTrue(partitionerSource.contains("Required confirmation"))
        XCTAssertTrue(partitionerSource.contains("Current partition map"))
        XCTAssertTrue(partitionerSource.contains("identity changed"))
        XCTAssertTrue(source.contains("This erases the whole disk"))
    }

    func testNewFSFormatterRejectsUnsafeTargetsByDefault() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/newfs_ntfsaccess/main.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("validateSafeFormatTarget"))
        XCTAssertTrue(source.contains("NTFSACCESS_ALLOW_UNSAFE_NEWFS_TARGET"))
        XCTAssertTrue(source.contains("external, writable partition"))
        XCTAssertFalse(source.contains("DevicePathResolver.diskGeometry(for: deviceArgument)\n        }\n\n        func run"))
    }

    func testInstallScriptsConsolidateMenuAppInstances() throws {
        let preinstall = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Scripts/preinstall"), encoding: .utf8)
        let postinstall = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Scripts/postinstall"), encoding: .utf8)

        XCTAssertTrue(preinstall.contains("stop_existing_menu_app"))
        XCTAssertTrue(postinstall.contains("stop_existing_menu_app"))
        XCTAssertTrue(postinstall.contains("launchctl kickstart -k \"gui/$console_uid/com.ntfsaccess.menu\""))
        XCTAssertTrue(preinstall.contains("done < <(/usr/bin/pgrep -f \"$menu_binary\" 2>/dev/null || true)"))
        XCTAssertTrue(postinstall.contains("done < <(/usr/bin/pgrep -f \"$menu_binary\" 2>/dev/null || true)"))
    }

    func testPostinstallRepairsRootOwnedPrivacySensitivePathsBeforeDaemonBootstrap() throws {
        let postinstall = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Scripts/postinstall"), encoding: .utf8)

        XCTAssertTrue(postinstall.contains("repair_privacy_sensitive_install_paths"))
        XCTAssertTrue(postinstall.contains("wait_for_service_unloaded"))
        XCTAssertTrue(postinstall.contains("bootstrap_system_service_with_retry"))
        XCTAssertTrue(postinstall.contains("APP_PATH=\"$(target_path \"/Applications/NTFS Access.app\")\""))
        XCTAssertTrue(postinstall.contains("TOOLCHAIN_ROOT=\"$(target_path \"/Library/NTFSAccess\")\""))
        XCTAssertTrue(postinstall.contains("chown -R root:wheel \"$APP_PATH\""))
        XCTAssertTrue(postinstall.contains("xattr -cr \"$APP_PATH\""))
        XCTAssertTrue(postinstall.contains("chown root:wheel \"$DAEMON_PLIST\""))
        XCTAssertLessThan(
            try XCTUnwrap(postinstall.range(of: "repair_privacy_sensitive_install_paths")?.lowerBound),
            try XCTUnwrap(postinstall.range(of: "bootstrap_system_service_with_retry com.ntfsaccess.mountd \"$DAEMON_PLIST\"")?.lowerBound)
        )
    }

    func testPackageBuildArchivesRecommendedSystemOwnership() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("--ownership recommended"))
    }

    func testLiveInstallValidationBatchEscalatesStaleNTFS3GForDevice() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_install_validate_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("stop_stale_ntfs3g_for_device"))
        XCTAssertTrue(script.contains("/usr/bin/pgrep -f \"ntfs-3g .*${DEVICE_ID}\""))
        XCTAssertTrue(script.contains("/bin/kill -TERM \"$pid\""))
        XCTAssertTrue(script.contains("/bin/kill -KILL \"$pid\""))
        XCTAssertTrue(script.contains("Stale ntfs-3g process survived cleanup"))
    }

    func testLiveInstallValidationBatchConsolidatesMenuAppBeforeKickstart() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_install_validate_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("stop_existing_menu_app"))
        XCTAssertTrue(script.contains("pgrep -f \"$menu_binary\""))
        XCTAssertTrue(script.contains("/bin/kill \"$pid\""))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "stop_existing_menu_app")?.lowerBound),
            try XCTUnwrap(script.range(of: "launchctl kickstart -k \"gui/$CONSOLE_UID/com.ntfsaccess.menu\"")?.lowerBound)
        )
    }

    func testLiveRestartValidationBatchAvoidsReinstallingCurrentAppBuild() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_restart_validate_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("NTFS Access live restart+validate batch"))
        XCTAssertTrue(script.contains("stop_stale_ntfs3g_for_device"))
        XCTAssertTrue(script.contains("launchctl kickstart -k system/com.ntfsaccess.mountd"))
        XCTAssertTrue(script.contains("sudo -u \"$CONSOLE_USER\" \"$VALIDATOR\" \"$DEVICE\" \"$EXPECTED_NAME\""))
        XCTAssertFalse(script.contains("installer -pkg"))
    }

    func testLiveRestartValidationBatchConsolidatesMenuAppBeforeKickstart() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_restart_validate_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("stop_existing_menu_app"))
        XCTAssertTrue(script.contains("pgrep -f \"$menu_binary\""))
        XCTAssertTrue(script.contains("/bin/kill \"$pid\""))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "stop_existing_menu_app")?.lowerBound),
            try XCTUnwrap(script.range(of: "launchctl kickstart -k \"gui/$CONSOLE_UID/com.ntfsaccess.menu\"")?.lowerBound)
        )
    }

    func testLiveRestartValidationBatchCanFormatSacrificialDeviceBeforeValidation() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_restart_validate_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("--format-first"))
        XCTAssertTrue(script.contains("FORMAT_FIRST=1"))
        XCTAssertTrue(script.contains("diskutil eraseVolume \"NTFS Access\" \"$EXPECTED_NAME\" \"$DEVICE\""))
        XCTAssertTrue(script.contains("Formatting sacrificial NTFS volume"))
        XCTAssertTrue(script.contains("diskutil listFilesystems"))
    }

    func testTwoPhysicalOvernightScriptsFrontLoadPrivilegedWorkAndRestoreAPFS() throws {
        let adminSetup = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_two_physical_admin_setup.sh"), encoding: .utf8)
        let userStress = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_two_physical_user_stress.sh"), encoding: .utf8)
        let restoreGuard = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_apfs_restore_guard.sh"), encoding: .utf8)
        let staging = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(adminSetup.contains("run_live_two_physical_admin_setup.sh must run as root"))
        XCTAssertTrue(adminSetup.contains("diskutil eraseDisk \"NTFS Access\" \"$NTFS_NAME\" GPT"))
        XCTAssertTrue(adminSetup.contains("run_live_apfs_restore_guard.sh"))
        XCTAssertFalse(adminSetup.contains("/usr/bin/nohup"))
        XCTAssertTrue(adminSetup.contains("RESTORE_PID=$!"))
        XCTAssertTrue(adminSetup.contains("wait \"$RESTORE_PID\""))
        XCTAssertTrue(adminSetup.contains("assert_whole_disk_identity \"$TARGET_DISK\""))
        XCTAssertTrue(adminSetup.contains("SAMSUNG_NTFS"))

        XCTAssertTrue(userStress.contains("run_live_two_physical_user_stress.sh must run as the logged-in user"))
        XCTAssertTrue(userStress.contains("STOP_FILE"))
        XCTAssertTrue(userStress.contains("run_pair_flow"))
        XCTAssertTrue(userStress.contains("TARGET_C"))
        XCTAssertTrue(userStress.contains("purge_transient_test_dirs"))

        XCTAssertTrue(restoreGuard.contains("run_live_apfs_restore_guard.sh must run as root"))
        XCTAssertTrue(restoreGuard.contains("touch \"$STOP_FILE\""))
        XCTAssertTrue(restoreGuard.contains("diskutil eraseDisk APFS \"$APFS_NAME\" GPT"))
        XCTAssertTrue(restoreGuard.contains("APFS_TOMORROW"))
        XCTAssertTrue(restoreGuard.contains("assert_whole_disk_identity \"$TARGET_DISK\""))

        XCTAssertTrue(staging.contains("run_live_two_physical_admin_setup.sh"))
        XCTAssertTrue(staging.contains("run_live_two_physical_user_stress.sh"))
        XCTAssertTrue(staging.contains("run_live_apfs_restore_guard.sh"))
    }

    func testLiveValidationBatchesFailWhenReadWriteMountIsUnavailable() throws {
        let installScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_install_validate_batch.sh"), encoding: .utf8)
        let restartScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_restart_validate_batch.sh"), encoding: .utf8)

        for script in [installScript, restartScript] {
            XCTAssertTrue(script.contains("NTFS Access is not reporting $DEVICE_ID as readWrite"))
            XCTAssertTrue(script.contains("exit 75"))
            XCTAssertFalse(script.contains("skipping destructive validation"))
        }
    }

    func testLiveValidationBatchesDoNotHangIndefinitelyOnLaunchctlKickstart() throws {
        let installScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_install_validate_batch.sh"), encoding: .utf8)
        let restartScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_restart_validate_batch.sh"), encoding: .utf8)

        for script in [installScript, restartScript] {
            XCTAssertTrue(script.contains("run_with_timeout"))
            XCTAssertTrue(script.contains("run_with_timeout_to_file"))
            XCTAssertTrue(script.contains("print_diskutil_info"))
            XCTAssertTrue(script.contains("run_with_timeout 20 /bin/launchctl kickstart -k system/com.ntfsaccess.mountd"))
            XCTAssertTrue(script.contains("run_with_timeout 20 /bin/launchctl kickstart -k \"gui/$CONSOLE_UID/com.ntfsaccess.menu\""))
            XCTAssertTrue(script.contains("run_with_timeout 20 /usr/sbin/diskutil unmount force \"$DEVICE\""))
            XCTAssertTrue(script.contains("run_with_timeout_to_file 12 \"$temp_output\" /usr/sbin/diskutil info \"$DEVICE\""))
            XCTAssertTrue(script.contains("print_diskutil_info \"before-validation\""))
            XCTAssertTrue(script.contains("print_diskutil_info \"after-validation\""))
            XCTAssertTrue(script.contains("timeout after ${seconds}s"))
            XCTAssertFalse(script.contains("\n/usr/sbin/diskutil info \"$DEVICE\" || true"))
        }
    }

    func testLiveFullValidationTimesOutUnmountAttemptsAndRejectsDuplicateWorkers() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_full_validation.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("run_with_timeout"))
        XCTAssertTrue(script.contains("run_with_timeout_to_file"))
        XCTAssertFalse(script.contains("wait \"$pid\" >/dev/null 2>&1 || true"))
        XCTAssertTrue(script.contains("capture_diskutil_info_plist"))
        XCTAssertTrue(script.contains("run_with_timeout_to_file 12 \"$temp_output\" /usr/sbin/diskutil info -plist \"$DEVICE\""))
        XCTAssertTrue(script.contains("trying direct root umount before diskutil for managed macFUSE mount"))
        XCTAssertTrue(script.contains("initial-umount-$attempt"))
        XCTAssertTrue(script.contains("run_with_timeout 30 /usr/sbin/diskutil unmount force \"$DEVICE\""))
        XCTAssertTrue(script.contains("diskutil force unmount failed; retrying direct root umount"))
        XCTAssertTrue(script.contains("run_with_timeout 20 /sbin/umount -f \"$MOUNT_POINT\""))
        XCTAssertTrue(script.contains("terminating stale ntfs-3g worker"))
        XCTAssertFalse(script.contains("run_with_timeout 45 /usr/sbin/diskutil unmount \"$DEVICE\""))
        XCTAssertTrue(script.contains("wait_for_unmount_or_remount"))
        XCTAssertTrue(script.contains("remount observed: mount=$diskutil_mount pids=$current_pids"))
        XCTAssertTrue(script.contains("assert_single_ntfs3g_process \"preflight\""))
        XCTAssertTrue(script.contains("assert_single_ntfs3g_process \"post-remount\""))
        XCTAssertTrue(script.contains("expected exactly one ntfs-3g process"))
    }

    func testLiveValidatorsRejectReadWriteMountsThatAreNotAccessibleToSignedInUser() throws {
        let scriptNames = [
            "live_ntfs_full_validation.sh",
            "live_ntfs_finder_workflow_probe.sh",
            "live_ntfs_finder_metadata_probe.sh",
            "live_ntfs_downloads_copy_probe.sh",
            "live_ntfs_metadata_package_matrix.sh",
            "live_ntfs_filename_matrix.sh",
            "live_ntfs_remount_churn.sh",
            "live_ntfs_guided_unplug_replug.sh",
            "live_ntfs_guided_sleep_wake.sh",
            "live_ntfs_multi_volume_flow.sh",
            "live_ntfs_filesystem_soak.sh",
            "live_ntfs_overnight_stress.sh",
            "run_live_user_validation_batch.sh"
        ]

        for scriptName in scriptNames {
            let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/\(scriptName)"), encoding: .utf8)
            XCTAssertTrue(script.contains("signed-in user cannot enter mount root"), scriptName)
            XCTAssertTrue(script.contains("signed-in user cannot write mount root"), scriptName)
            XCTAssertTrue(script.contains("/bin/ls -ldOe@"), scriptName)
        }
    }

    func testLiveFullValidationCoversFinderStyleMetadataCopy() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_full_validation.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Finder-style metadata copy"))
        XCTAssertTrue(script.contains("com.apple.quarantine"))
        XCTAssertTrue(script.contains("com.apple.FinderInfo"))
        XCTAssertTrue(script.contains("FINDER_INFO_HEX="))
        XCTAssertTrue(script.contains("46494452"))
        XCTAssertTrue(script.contains("xattr -wx com.apple.FinderInfo \"$FINDER_INFO_HEX\" \"$source_file\""))
        XCTAssertTrue(script.contains("xattr -px com.apple.FinderInfo \"$source_file\""))
        XCTAssertTrue(script.contains("xattr -px com.apple.FinderInfo \"$destination_file\""))
        XCTAssertTrue(script.contains("[[ \"$source_finder_info\" == \"$destination_finder_info\" ]]"))
        XCTAssertFalse(script.contains("[[ \"$source_quarantine\" == \"$destination_quarantine\" ]]"))
        XCTAssertFalse(script.contains("create_finder_info_blob |"))
        XCTAssertTrue(script.contains("/bin/cp -R"))
        XCTAssertTrue(script.contains("could not preserve Finder metadata"))
    }

    func testStandaloneFinderMetadataProbeIsPackagedForLiveValidation() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_finder_metadata_probe.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("Finder-style metadata copy probe"))
        XCTAssertTrue(probe.contains("com.apple.quarantine"))
        XCTAssertTrue(probe.contains("com.apple.FinderInfo"))
        XCTAssertTrue(probe.contains("FINDER_INFO_HEX="))
        XCTAssertTrue(probe.contains("xattr -wx com.apple.FinderInfo \"$FINDER_INFO_HEX\" \"$SOURCE_FILE\""))
        XCTAssertTrue(probe.contains("[[ \"$SOURCE_FINDER_INFO\" == \"$DEST_FINDER_INFO\" ]]"))
        XCTAssertFalse(probe.contains("[[ \"$SOURCE_QUARANTINE\" == \"$DEST_QUARANTINE\" ]]"))
        XCTAssertFalse(probe.contains("create_finder_info_blob |"))
        XCTAssertTrue(probe.contains("/bin/cp -R"))
        XCTAssertTrue(packageScript.contains("live_ntfs_finder_metadata_probe.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_finder_metadata_probe.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_finder_metadata_probe.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_finder_metadata_probe.sh"))
    }

    func testDownloadsFolderCopyProbeIsPackagedForPlainManualCopyRegression() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_downloads_copy_probe.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("Downloads folder copy probe"))
        XCTAssertTrue(probe.contains("/bin/cp -R \"$source\" \"$destination\""))
        XCTAssertTrue(probe.contains("/usr/bin/ditto --noextattr --norsrc \"$source\" \"$expected\""))
        XCTAssertTrue(probe.contains("/usr/bin/ditto --noextattr --norsrc \"$destination\" \"$actual\""))
        XCTAssertTrue(probe.contains("/usr/bin/find \"$target\" -name '._*' -delete"))
        XCTAssertTrue(probe.contains("/usr/bin/diff -qr \"$expected\" \"$actual\""))
        XCTAssertTrue(probe.contains("NTFSAccess_downloads_copy_probe_$STAMP"))
        XCTAssertFalse(probe.contains("rm -rf \"$DEST_ROOT\""))
        XCTAssertTrue(packageScript.contains("live_ntfs_downloads_copy_probe.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_downloads_copy_probe.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_downloads_copy_probe.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_downloads_copy_probe.sh"))
    }

    func testFinderWorkflowProbeIsPackagedForTrashAndPDFRegression() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_finder_workflow_probe.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("Finder workflow probe"))
        XCTAssertTrue(probe.contains("expected asynchronous macFUSE mount after performance fix"))
        XCTAssertTrue(probe.contains("-iname '*.pdf'"))
        XCTAssertTrue(probe.contains("copy_path \"$DOWNLOADS_DIR/Telegram\""))
        XCTAssertTrue(probe.contains("trash_and_remove \"$DEST_ROOT/Telegram\""))
        XCTAssertTrue(probe.contains("/bin/mv \"$target\" \"$trashed\""))
        XCTAssertTrue(probe.contains("/bin/rm -rf \"$trashed\""))
        XCTAssertTrue(probe.contains("run_with_timeout 180 /bin/cp -R"))
        XCTAssertFalse(probe.contains("head -z"))
        XCTAssertTrue(probe.contains("export VOLUMES LINE MODE MOUNT_POINT NAME"))
        XCTAssertTrue(packageScript.contains("live_ntfs_finder_workflow_probe.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_finder_workflow_probe.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_finder_workflow_probe.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_finder_workflow_probe.sh"))
    }

    func testUserValidationBatchRunsFinderWorkflowBeforeBroadStress() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_user_validation_batch.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("FINDER_WORKFLOW_VALIDATOR=\"$SCRIPT_DIR/live_ntfs_finder_workflow_probe.sh\""))
        XCTAssertTrue(script.contains("METADATA_PACKAGE_VALIDATOR=\"$SCRIPT_DIR/live_ntfs_metadata_package_matrix.sh\""))
        XCTAssertTrue(script.contains("FILENAME_MATRIX_VALIDATOR=\"$SCRIPT_DIR/live_ntfs_filename_matrix.sh\""))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$FINDER_WORKFLOW_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$METADATA_PACKAGE_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$FILENAME_MATRIX_VALIDATOR\" \"$device\" \"$name\""))
    }

    func testAdminBatchCanRunFinderWorkflowValidatorInsideGuiSession() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("FINDER_WORKFLOW_VALIDATOR=\"$REPO_ROOT/scripts/live_ntfs_finder_workflow_probe.sh\""))
        XCTAssertTrue(script.contains("METADATA_PACKAGE_VALIDATOR=\"$REPO_ROOT/scripts/live_ntfs_metadata_package_matrix.sh\""))
        XCTAssertTrue(script.contains("FILENAME_MATRIX_VALIDATOR=\"$REPO_ROOT/scripts/live_ntfs_filename_matrix.sh\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$FINDER_WORKFLOW_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$METADATA_PACKAGE_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$FILENAME_MATRIX_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("record_validator_failure \"finder-workflow:$id\""))
        XCTAssertTrue(script.contains("record_validator_failure \"metadata-package:$id\""))
        XCTAssertTrue(script.contains("record_validator_failure \"filename-matrix:$id\""))
    }

    func testMetadataPackageMatrixIsPackagedForFinderMetadataAndPackageCoverage() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_metadata_package_matrix.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("NTFS Access metadata/package matrix"))
        XCTAssertTrue(probe.contains("Sample.app"))
        XCTAssertTrue(probe.contains("Sample.bundle"))
        XCTAssertTrue(probe.contains("Sample.pkg"))
        XCTAssertTrue(probe.contains("com.apple.ResourceFork"))
        XCTAssertTrue(probe.contains("unsupported_known_limitation"))
        XCTAssertTrue(probe.contains("ordinary xattrs remain mandatory"))
        XCTAssertTrue(probe.contains("assert_quarantine_xattr_present"))
        XCTAssertTrue(probe.contains("metadata-package-matrix"))
        XCTAssertTrue(probe.contains("com.ntfsaccess.test"))
        XCTAssertTrue(probe.contains("/bin/cp -R"))
        XCTAssertTrue(probe.contains("/usr/bin/ditto --rsrc"))
        XCTAssertTrue(probe.contains("assert_tree_shape_ignoring_appledouble"))
        XCTAssertFalse(probe.contains("/usr/bin/diff -qr"))
        XCTAssertTrue(probe.contains("/usr/bin/cmp"))
        XCTAssertTrue(probe.contains("/usr/bin/shasum -a 256"))
        XCTAssertTrue(probe.contains("/sbin/md5 -q"))
        XCTAssertTrue(probe.contains(".Trashes/$(/usr/bin/id -u)"))
        XCTAssertTrue(packageScript.contains("live_ntfs_metadata_package_matrix.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_metadata_package_matrix.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_metadata_package_matrix.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_metadata_package_matrix.sh"))
    }

    func testFilenameMatrixIsPackagedForFilenameEdgeCoverage() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_filename_matrix.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("NTFS Access filename matrix"))
        XCTAssertTrue(probe.contains("pass_expected_file \"spaces\""))
        XCTAssertTrue(probe.contains("pass_expected_file \"cjk\""))
        XCTAssertTrue(probe.contains("pass_expected_file \"emoji\""))
        XCTAssertTrue(probe.contains("pass_expected_file \"nfc\""))
        XCTAssertTrue(probe.contains("pass_expected_file \"nfd\""))
        XCTAssertTrue(probe.contains("pass_expected_file \"case-upper\""))
        XCTAssertTrue(probe.contains("pass_expected_file \"case-lower\""))
        XCTAssertTrue(probe.contains("pass_expected_deep_path"))
        XCTAssertTrue(probe.contains("observe_name_case \"trailing-space\""))
        XCTAssertTrue(probe.contains("observe_name_case \"trailing-dot\""))
        XCTAssertTrue(probe.contains("observe_name_case \"colon\""))
        XCTAssertTrue(probe.contains("observe_name_case \"star\""))
        XCTAssertTrue(probe.contains("observe_name_case \"question\""))
        XCTAssertTrue(probe.contains("observe_normalization_collision"))
        XCTAssertTrue(probe.contains("/usr/bin/shasum -a 256"))
        XCTAssertTrue(probe.contains("/sbin/md5 -q"))
        XCTAssertTrue(packageScript.contains("live_ntfs_filename_matrix.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_filename_matrix.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_filename_matrix.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_filename_matrix.sh"))
    }

    func testFormatMatrixProbeIsPackagedAndReadOnlyInventoryOnly() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_format_matrix_probe.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)
        let userBatch = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_user_validation_batch.sh"), encoding: .utf8)
        let adminBatch = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("NTFS Access format matrix probe"))
        XCTAssertTrue(probe.contains("[/dev/diskXsY [expectedName] ...]"))
        XCTAssertTrue(probe.contains("readOnly=true writes=false mounts=false unmounts=false repairs=false formatting=false daemonActions=false"))
        XCTAssertTrue(probe.contains("format_matrix device=$device"))
        XCTAssertTrue(probe.contains("format_matrix nameCheck=expectedName=$expected_name result=matched"))
        XCTAssertTrue(probe.contains("expected volume name '$expected_name'"))
        XCTAssertTrue(probe.contains("partitionMap=$partition_map"))
        XCTAssertTrue(probe.contains("sectorSize=$sector_size"))
        XCTAssertTrue(probe.contains("clusterSize=$cluster_size"))
        XCTAssertTrue(probe.contains("variantGuess=$variant_guess"))
        XCTAssertTrue(probe.contains("ledger_row="))
        XCTAssertTrue(probe.contains("validator_command=live_ntfs_full_validation.sh"))
        XCTAssertTrue(probe.contains("validator_command=live_ntfs_metadata_package_matrix.sh"))
        XCTAssertTrue(probe.contains("validator_command=live_ntfs_filename_matrix.sh"))
        XCTAssertTrue(probe.contains("diskutil info -plist"))
        XCTAssertTrue(probe.contains("diskutil list"))
        XCTAssertTrue(probe.contains("/sbin/fstyp"))
        XCTAssertTrue(probe.contains("cluster_size=\"unknown\""))
        XCTAssertFalse(probe.contains("scan-now"))
        XCTAssertFalse(probe.contains("retry-mounts"))
        XCTAssertFalse(probe.contains("diskutil unmount"))
        XCTAssertFalse(probe.contains("diskutil mount"))
        XCTAssertFalse(probe.contains("diskutil erase"))
        XCTAssertFalse(probe.contains("newfs_ntfsaccess"))
        XCTAssertFalse(probe.contains("mkntfs"))
        XCTAssertFalse(probe.contains("ntfsfix"))
        XCTAssertFalse(probe.contains("ntfs-3g.probe"))
        XCTAssertFalse(probe.contains("assert_mount_root_user_accessible"))
        XCTAssertFalse(probe.contains("signed-in user cannot write mount root"))
        XCTAssertTrue(packageScript.contains("live_ntfs_format_matrix_probe.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_format_matrix_probe.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_format_matrix_probe.sh"))
        XCTAssertTrue(stageScript.contains("/bin/bash '$STAGE_SCRIPTS/live_ntfs_format_matrix_probe.sh' --all"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_format_matrix_probe.sh"))
        XCTAssertFalse(userBatch.contains("live_ntfs_format_matrix_probe.sh"))
        XCTAssertFalse(adminBatch.contains("live_ntfs_format_matrix_probe.sh"))
    }

    func testSpecialFeatureProbeIsPackagedAndCopyOutOnly() throws {
        let probe = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_special_feature_probe.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let supportInstallScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)
        let userBatch = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_user_validation_batch.sh"), encoding: .utf8)
        let adminBatch = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(probe.contains("NTFS Access special feature probe"))
        XCTAssertTrue(probe.contains("NTFSAccessSpecialFixtures"))
        XCTAssertTrue(probe.contains("sparse-file.bin"))
        XCTAssertTrue(probe.contains("compressed-file.bin"))
        XCTAssertTrue(probe.contains("encrypted-efs-file.bin"))
        XCTAssertTrue(probe.contains("alternate-data-stream.txt"))
        XCTAssertTrue(probe.contains("junction"))
        XCTAssertTrue(probe.contains("symlink"))
        XCTAssertTrue(probe.contains("mount-point"))
        XCTAssertTrue(probe.contains("reparse-point"))
        XCTAssertTrue(probe.contains("cloud-placeholder"))
        XCTAssertTrue(probe.contains("readOnly=true writesToNTFS=false mounts=false unmounts=false repairs=false formatting=false daemonActions=false"))
        XCTAssertTrue(probe.contains("unsupported-acceptable-must-not-crash"))
        XCTAssertTrue(probe.contains("copy_primary_stream"))
        XCTAssertTrue(probe.contains("/usr/bin/shasum -a 256"))
        XCTAssertTrue(probe.contains("/sbin/md5 -q"))
        XCTAssertTrue(probe.contains("/usr/bin/cmp"))
        XCTAssertTrue(probe.contains("status=missing expected=pre-prepared-windows-fixture"))
        XCTAssertTrue(probe.contains("status=unsupported"))
        XCTAssertFalse(probe.contains("scan-now"))
        XCTAssertFalse(probe.contains("retry-mounts"))
        XCTAssertFalse(probe.contains("diskutil unmount"))
        XCTAssertFalse(probe.contains("diskutil mount"))
        XCTAssertFalse(probe.contains("diskutil erase"))
        XCTAssertFalse(probe.contains("newfs_ntfsaccess"))
        XCTAssertFalse(probe.contains("mkntfs"))
        XCTAssertFalse(probe.contains("ntfsfix"))
        XCTAssertFalse(probe.contains("ntfs-3g.probe"))
        XCTAssertFalse(probe.contains("assert_mount_root_user_accessible"))
        XCTAssertFalse(probe.contains("signed-in user cannot write mount root"))
        XCTAssertTrue(packageScript.contains("live_ntfs_special_feature_probe.sh"))
        XCTAssertTrue(supportInstallScript.contains("live_ntfs_special_feature_probe.sh"))
        XCTAssertTrue(stageScript.contains("live_ntfs_special_feature_probe.sh"))
        XCTAssertTrue(stageScript.contains("/bin/bash '$STAGE_SCRIPTS/live_ntfs_special_feature_probe.sh' /Volumes/EXPECTED_VOLUME_NAME"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_special_feature_probe.sh"))
        XCTAssertFalse(userBatch.contains("live_ntfs_special_feature_probe.sh"))
        XCTAssertFalse(adminBatch.contains("live_ntfs_special_feature_probe.sh"))
    }

    func testLiveIntegrityValidatorsRecordSHA256AndMD5() throws {
        let scriptNames = [
            "live_ntfs_full_validation.sh",
            "live_ntfs_filesystem_soak.sh",
            "live_ntfs_remount_churn.sh",
            "live_ntfs_multi_volume_flow.sh",
            "live_ntfs_overnight_stress.sh"
        ]

        for scriptName in scriptNames {
            let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/\(scriptName)"), encoding: .utf8)
            XCTAssertTrue(script.contains("/usr/bin/shasum -a 256"), scriptName)
            XCTAssertTrue(script.contains("/sbin/md5 -q"), scriptName)
            XCTAssertTrue(script.contains("integrity="), scriptName)
        }
    }

    func testLivePerformanceValidatorsRecordTimingEvidence() throws {
        let scriptNames = [
            "live_ntfs_full_validation.sh",
            "live_ntfs_filesystem_soak.sh",
            "live_ntfs_finder_workflow_probe.sh",
            "live_ntfs_multi_volume_flow.sh",
            "live_ntfs_overnight_stress.sh"
        ]

        for scriptName in scriptNames {
            let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/\(scriptName)"), encoding: .utf8)
            XCTAssertTrue(script.contains("timing="), scriptName)
            XCTAssertTrue(script.contains("seconds="), scriptName)
        }
    }

    func testAdminBatchReportsValidatorFailuresAtEndOfRun() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("if [[ \"$FAILURES\" -gt 0 ]]; then"))
        XCTAssertTrue(script.contains("FAILED_VALIDATOR_COUNT=$FAILURES"))
        XCTAssertTrue(script.contains("for failed in \"${FAILED_VALIDATORS[@]}\"; do"))
        XCTAssertTrue(script.contains("FAILED"))
        XCTAssertTrue(script.contains("exit 75"))
    }

    func testUserFacingLiveProbesBoundScanNowWaits() throws {
        let probeScripts = [
            "scripts/live_ntfs_finder_metadata_probe.sh",
            "scripts/live_ntfs_downloads_copy_probe.sh",
            "scripts/live_ntfs_finder_workflow_probe.sh",
            "scripts/run_live_user_validation_batch.sh"
        ]

        for relativePath in probeScripts {
            let script = try String(contentsOf: repositoryRoot().appendingPathComponent(relativePath), encoding: .utf8)
            XCTAssertTrue(script.contains("run_with_timeout 120 \"$NTFSACCESSCTL\" scan-now --wait"), relativePath)
            let rawScanLines = script.split(separator: "\n").filter { line in
                line.contains("\"$NTFSACCESSCTL\" scan-now") && !line.contains("run_with_timeout")
            }
            XCTAssertTrue(rawScanLines.isEmpty, "\(relativePath) scan-now calls must go through request_scan timeout wrapper: \(rawScanLines)")
        }
    }

    func testFilesystemSoakRecognizesUnmountRemountRaceWithoutFalseFailure() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_filesystem_soak.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("current_ntfs3g_pids"))
        XCTAssertTrue(script.contains("run_with_timeout_to_file 12 \"$plist\" /usr/sbin/diskutil info -plist \"$DEVICE\""))
        XCTAssertTrue(script.contains("run_with_timeout 30 /usr/sbin/diskutil unmount force \"$DEVICE\""))
        XCTAssertTrue(script.contains("wait_for_unmount_or_remount"))
        XCTAssertTrue(script.contains("remount observed: mount=$MOUNT_POINT pids=$current_pids"))
        XCTAssertTrue(script.contains("slow remount recovered after"))
        XCTAssertTrue(script.contains("wait_for_mount_state \"cycle-$cycle\" 90"))
        XCTAssertTrue(script.contains("scan-now --wait"))
        XCTAssertTrue(script.contains("retrying direct root umount"))
        XCTAssertTrue(script.contains("run_with_timeout 20 /sbin/umount -f \"$MOUNT_POINT\""))
        XCTAssertTrue(script.contains("cycle-$cycle unmount failed"))
    }

    func testLiveRemountChurnValidationStressesRepeatedUnmountRemountState() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_remount_churn.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("CYCLES=\"${3:-12}\""))
        XCTAssertTrue(script.contains("assert_read_write_state"))
        XCTAssertTrue(script.contains("assert_single_ntfs3g_process"))
        XCTAssertTrue(script.contains("run_with_timeout_to_file 12 \"$info_plist\" /usr/sbin/diskutil info -plist \"$DEVICE\""))
        XCTAssertTrue(script.contains("run_with_timeout 30 /usr/sbin/diskutil unmount force \"$DEVICE\""))
        XCTAssertTrue(script.contains("retrying direct root umount"))
        XCTAssertTrue(script.contains("run_with_timeout 20 /sbin/umount -f \"$MOUNT_POINT\""))
        XCTAssertTrue(script.contains("scan-now --wait"))
        XCTAssertTrue(script.contains("timing=daemon-scan"))
        XCTAssertTrue(script.contains("request_scan \"cycle-$cycle-initial\""))
        XCTAssertTrue(script.contains("still waiting after attempt $attempt; requesting another daemon scan"))
        XCTAssertTrue(script.contains("read_write_mount_is_verified"))
        XCTAssertTrue(script.contains("read_write_mount_is_verified"))
        XCTAssertTrue(script.contains("verified remount on attempt"))
        XCTAssertTrue(script.contains("assert_read_write_state \"cycle-$cycle\" no-scan"))
        XCTAssertTrue(script.contains("cycle-$cycle"))
        XCTAssertTrue(script.contains("post-remount write/read failed"))
        XCTAssertTrue(script.contains("grep -qi 'macfuse'"))
        XCTAssertTrue(script.contains("Finder-style mount point disappeared"))
    }

    func testLiveOvernightStressBoundsDiskutilInfoCalls() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_overnight_stress.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("run_with_timeout_to_file"))
        XCTAssertTrue(script.contains("run_with_timeout_to_file 12 \"$info_plist\" /usr/sbin/diskutil info -plist \"$DEVICE\""))
        XCTAssertTrue(script.contains("run_with_timeout 35 /usr/sbin/diskutil unmount force \"$DEVICE\""))
        XCTAssertTrue(script.contains("retrying direct root umount"))
        XCTAssertTrue(script.contains("run_with_timeout 20 /sbin/umount -f \"$MOUNT_POINT\""))
        XCTAssertFalse(script.contains("\n  /usr/sbin/diskutil info -plist \"$DEVICE\" > \"$info_plist\""))
    }

    func testMultiVolumeFlowValidationCoversCrossDriveCopiesAndSiblingRemounts() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_multi_volume_flow.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("NTFS Access multi-volume flow validation"))
        XCTAssertTrue(script.contains("a to mac to b"))
        XCTAssertTrue(script.contains("b to mac to a"))
        XCTAssertTrue(script.contains("direct mounted volume copies"))
        XCTAssertTrue(script.contains("parallel bidirectional writes"))
        XCTAssertTrue(script.contains("/bin/mv \"$BASE_B/parallel-$cycle/a-copy.bin\" \"$BASE_B/parallel-$cycle/a-copy-renamed.bin\""))
        XCTAssertTrue(script.contains("/bin/mv \"$BASE_A/parallel-$cycle/b-copy.bin\" \"$BASE_A/parallel-$cycle/b-copy-renamed.bin\""))
        XCTAssertFalse(script.contains("/bin/mv \"$BASE_A/parallel-$cycle/a-copy.bin\""))
        XCTAssertTrue(script.contains("single-volume remount while sibling busy"))
        XCTAssertTrue(script.contains("assert_both_ready"))
        XCTAssertTrue(script.contains("ntfs3g_count_for"))
        XCTAssertTrue(script.contains("run_with_timeout_to_file 12 \"$plist\" /usr/sbin/diskutil info -plist \"$device\""))
        XCTAssertTrue(script.contains("COPYFILE_DISABLE=1 /bin/cp -X"))
        XCTAssertTrue(script.contains("wait_until_volume_ready"))
        XCTAssertTrue(script.contains("volume_ready_probe"))
        XCTAssertTrue(script.contains("request_scan"))
        XCTAssertTrue(script.contains("run_with_timeout 120 \"$NTFSACCESSCTL\" scan-now --wait"))
        XCTAssertTrue(script.contains("if volume_ready_probe \"$device\" \"$id\" \"$expected_name\" \"$out_var\" \"$label-attempt-$attempt\" no-scan; then"))
        XCTAssertTrue(script.contains("timing=daemon-scan"))
        XCTAssertTrue(script.contains("still waiting after attempt $attempt; requesting another daemon scan"))
        XCTAssertTrue(script.contains("request_scan \"$label-initial\""))
        XCTAssertTrue(script.contains("request_scan \"$label-final\""))
        let rawScanLines = script.split(separator: "\n").filter { line in
            line.contains("\"$NTFSACCESSCTL\" scan-now") && !line.contains("run_with_timeout")
        }
        XCTAssertTrue(rawScanLines.isEmpty, "scan-now calls must go through request_scan timeout wrapper: \(rawScanLines)")
        XCTAssertFalse(script.contains("if assert_volume_ready \"$device\" \"$id\" \"$expected_name\" \"$out_var\" \"$label-attempt-$attempt\""))
    }

    func testMultiVolumeFlowUsesShellBuiltinWaitForParallelWorkers() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_multi_volume_flow.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("wait \"$busy_pid\""))
        XCTAssertTrue(script.contains("wait \"$pid_a\""))
        XCTAssertTrue(script.contains("wait \"$pid_b\""))
        XCTAssertFalse(script.contains("/bin/wait"))
    }

    func testMultiVolumeFlowSizesPayloadFromAvailableCapacityAndCleansOldFlowDirs() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_multi_volume_flow.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("choose_source_mib"))
        XCTAssertTrue(script.contains("available_kib"))
        XCTAssertTrue(script.contains("NTFSACCESS_MULTI_SOURCE_MIB"))
        XCTAssertTrue(script.contains("cleanup_previous_flow_dirs"))
        XCTAssertTrue(script.contains("/bin/rm -rf \"$MOUNT_A\"/multi-flow-* \"$MOUNT_B\"/multi-flow-*"))
        XCTAssertTrue(script.contains("/usr/sbin/mkfile \"${SOURCE_MIB}m\" \"$LOCAL_SOURCE\""))
        XCTAssertFalse(script.contains("/usr/sbin/mkfile 96m \"$LOCAL_SOURCE\""))
    }

    func testMultiDeviceAdminBatchInstallsOnceAndGatesDestructiveValidatorsOnReadWriteState() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("NTFS Access live multi-device admin batch"))
        XCTAssertTrue(script.contains("--skip-install"))
        XCTAssertTrue(script.contains("skipInstall=$SKIP_INSTALL"))
        XCTAssertTrue(script.contains("--- skipping package install ---"))
        XCTAssertTrue(script.contains("/usr/sbin/installer -pkg \"$PKG_PATH\" -target /"))
        XCTAssertTrue(script.contains("probe_raw_access"))
        XCTAssertTrue(script.contains("printf '/dev/rdisk%s\\n' \"${device#/dev/disk}\""))
        XCTAssertFalse(script.contains("${device/\\/dev\\/disk/\\/dev\\/rdisk}"))
        XCTAssertTrue(script.contains("run_writable_validators"))
        XCTAssertTrue(script.contains("SKIP validators for $device ($name): not readWrite"))
        XCTAssertTrue(script.contains("run_two_volume_flow_if_possible"))
        XCTAssertTrue(script.contains("fewer than two readWrite NTFS Access volumes"))
        XCTAssertTrue(script.contains("live_ntfs_multi_volume_flow.sh"))
        XCTAssertTrue(script.contains("live_ntfs_remount_churn.sh"))
        XCTAssertTrue(script.contains("live_ntfs_filesystem_soak.sh"))
        XCTAssertTrue(script.contains("live_ntfs_full_validation.sh"))
    }

    func testMultiDeviceAdminBatchForwardsSmallDriveValidationCaps() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("NTFSACCESS_LARGE_FILE_MIB=\"${NTFSACCESS_LARGE_FILE_MIB:-}\""))
        XCTAssertTrue(script.contains("NTFSACCESS_RANDOM_FILE_COUNT=\"${NTFSACCESS_RANDOM_FILE_COUNT:-}\""))
        XCTAssertTrue(script.contains("NTFSACCESS_RANDOM_FILE_MIB=\"${NTFSACCESS_RANDOM_FILE_MIB:-}\""))
        XCTAssertTrue(script.contains("NTFSACCESS_MULTI_SOURCE_MIB=\"${NTFSACCESS_MULTI_SOURCE_MIB:-}\""))
        XCTAssertTrue(script.contains("/usr/bin/env \\"))
        XCTAssertTrue(script.contains("/bin/launchctl asuser \"$CONSOLE_UID\" /usr/bin/sudo -u \"$CONSOLE_USER\" /usr/bin/env"))
    }

    func testMultiDeviceAdminWrapperDiscoversLiveNTFSTargetsBeforeAdminBatch() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("NTFS Access live multi-device preflight"))
        XCTAssertTrue(script.contains("SCRIPT_DIR=\"$(cd \"$(dirname \"${BASH_SOURCE[0]}\")\" && pwd -P)\""))
        XCTAssertTrue(script.contains("REPO_ROOT=\"$(cd \"$SCRIPT_DIR/..\" && pwd -P)\""))
        XCTAssertTrue(script.contains("/tmp/ntfsaccess-live-multi-preflight"))
        XCTAssertTrue(script.contains("diskutil list external physical"))
        XCTAssertTrue(script.contains("diskutil info -plist \"$device\""))
        XCTAssertTrue(script.contains("fstyp \"$device\""))
        XCTAssertTrue(script.contains("diskutil list \"$device\""))
        XCTAssertTrue(script.contains("is_ntfs_candidate"))
        XCTAssertTrue(script.contains("is_ntfs_personality"))
        XCTAssertTrue(script.contains("windows nt filesystem"))
        XCTAssertTrue(script.contains("ntfs access"))
        XCTAssertTrue(script.contains("skip=$device reason=not-live-ntfs-filesystem"))
        XCTAssertTrue(script.contains("--dry-run"))
        XCTAssertTrue(script.contains("--skip-install"))
        XCTAssertTrue(script.contains("\"$PKG_PATH\""))
        XCTAssertTrue(script.contains("--skip-install \\\n    \"$PKG_PATH\""))
        XCTAssertFalse(script.contains("batch_args"))
        XCTAssertTrue(script.contains("dry-run complete; admin batch not started"))
        XCTAssertFalse(script.contains("mapfile"))
        XCTAssertFalse(script.contains("/dev/disk12s1:NTFS_STRESS"))
        XCTAssertFalse(script.contains("/dev/disk13s2:HP_NTFS_A"))
        XCTAssertFalse(script.contains("/dev/disk13s3:HP_NTFS_B"))
    }

    func testMultiDeviceAdminStageScriptCopiesRunnableBatchOutsideDocuments() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("/Users/Shared/NTFSAccessLiveBatch"))
        XCTAssertTrue(script.contains("SUPPORT_INSTALL_SCRIPTS=\"$SUPPORT_INSTALL_ROOT/scripts\""))
        XCTAssertTrue(script.contains("SUPPORT_INSTALL_LAUNCHDAEMONS=\"$SUPPORT_INSTALL_ROOT/Packaging/LaunchDaemons\""))
        XCTAssertTrue(script.contains("ditto --noqtn"))
        XCTAssertTrue(script.contains("NTFSAccess-installer.pkg"))
        XCTAssertTrue(script.contains("run_live_multi_device_admin_batch.sh"))
        XCTAssertTrue(script.contains("run_live_user_validation_batch.sh"))
        XCTAssertTrue(script.contains("run_live_deadline_guarded_stress.sh"))
        XCTAssertTrue(script.contains("live_multi_device_admin_batch.sh"))
        XCTAssertTrue(script.contains("live_ntfs_full_validation.sh"))
        XCTAssertTrue(script.contains("live_ntfs_metadata_package_matrix.sh"))
        XCTAssertTrue(script.contains("live_ntfs_filename_matrix.sh"))
        XCTAssertTrue(script.contains("live_ntfs_remount_churn.sh"))
        XCTAssertTrue(script.contains("live_ntfs_guided_unplug_replug.sh"))
        XCTAssertTrue(script.contains("live_ntfs_guided_sleep_wake.sh"))
        XCTAssertTrue(script.contains("live_ntfs_multi_volume_flow.sh"))
        XCTAssertTrue(script.contains("live_ntfs_overnight_stress.sh"))
        XCTAssertTrue(script.contains("live_ntfs_filesystem_soak.sh"))
        XCTAssertTrue(script.contains("\"$SUPPORT_INSTALL_SCRIPTS/$script\""))
        XCTAssertTrue(script.contains("\"$SUPPORT_INSTALL_SCRIPTS/install_live_job_support.sh\""))
        XCTAssertTrue(script.contains("\"$SUPPORT_INSTALL_LAUNCHDAEMONS/com.ntfsaccess.livejob.plist\""))
        XCTAssertTrue(script.contains("\"$SUPPORT_INSTALL_ROOT/.build/release/ntfsaccessctl\""))
        XCTAssertTrue(script.contains("safe_chmod 755 \"$STAGE_ROOT\" \"$STAGE_ROOT/logs\""))
        XCTAssertFalse(script.contains("chmod -R a+rX \"$STAGE_ROOT\""))
        XCTAssertTrue(script.contains("NTFSACCESS_LARGE_FILE_MIB=64"))
        XCTAssertTrue(script.contains("NTFSACCESS_RANDOM_FILE_COUNT=4"))
        XCTAssertTrue(script.contains("NTFSACCESS_RANDOM_FILE_MIB=16"))
        XCTAssertTrue(script.contains("NTFSACCESS_MULTI_SOURCE_MIB=32"))
        XCTAssertTrue(script.contains("DEADLINE_DATE=\"$(/bin/date +%Y-%m-%d)\""))
        XCTAssertTrue(script.contains("DEADLINE_DATE=\"$(/bin/date -v+1d +%Y-%m-%d)\""))
        XCTAssertTrue(script.contains("/bin/bash '$STAGE_SCRIPTS/run_live_multi_device_admin_batch.sh' --dry-run"))
        XCTAssertTrue(script.contains("/bin/bash '$STAGE_SCRIPTS/run_live_user_validation_batch.sh' --remount-cycles 12 --soak-cycles 40 --multi-cycles 12"))
        XCTAssertTrue(script.contains("/bin/bash '$STAGE_SCRIPTS/live_ntfs_guided_unplug_replug.sh' /dev/diskXsY EXPECTED_VOLUME_NAME"))
        XCTAssertTrue(script.contains("/bin/bash '$STAGE_SCRIPTS/live_ntfs_guided_sleep_wake.sh' /dev/diskXsY EXPECTED_VOLUME_NAME"))
        XCTAssertTrue(script.contains("/bin/bash '$STAGE_SCRIPTS/run_live_deadline_guarded_stress.sh' /dev/disk13s2 HP_NTFS_A /dev/disk13s3 HP_NTFS_B"))
        XCTAssertFalse(script.contains("touch \"$STAGE_ROOT/live-job.trigger\""))
        XCTAssertTrue(script.contains("--skip-install"))
        XCTAssertTrue(script.contains("with administrator privileges"))
    }

    func testPromptSafeLiveJobRunnerIsPackagedIntoApplicationSupport() throws {
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(packageScript.contains("live_job_runner.sh"))
        XCTAssertTrue(packageScript.contains("$PKGROOT/Library/Application Support/NTFSAccess/live_job_runner.sh"))
        XCTAssertTrue(packageScript.contains("$PKGROOT/Library/Application Support/NTFSAccess/live-tests/scripts"))
        XCTAssertTrue(packageScript.contains("Packaging/LaunchDaemons/com.ntfsaccess.livejob.plist"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live_job_runner.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_multi_device_admin_batch.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_user_validation_batch.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/run_live_deadline_guarded_stress.sh"))
        XCTAssertTrue(verifier.contains("/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_overnight_stress.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_metadata_package_matrix.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_filename_matrix.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_unplug_replug.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_sleep_wake.sh"))
    }

    func testLiveJobRunnerUsesSharedStagingAndDoesNotTriggerNestedAuthPrompts() throws {
        let runner = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_job_runner.sh"), encoding: .utf8)

        XCTAssertTrue(runner.contains("/Users/Shared/NTFSAccessLiveBatch"))
        XCTAssertTrue(runner.contains("SUPPORT_ROOT=\"/Library/Application Support/NTFSAccess\""))
        XCTAssertTrue(runner.contains("INSTALLED_LIVE_ROOT=\"$SUPPORT_ROOT/live-tests\""))
        XCTAssertTrue(runner.contains("NTFSACCESS_FORCE_SKIP_INSTALL"))
        XCTAssertTrue(runner.contains("NTFSACCESS_REQUIRE_LIVEJOB_TRIGGER"))
        XCTAssertTrue(runner.contains("require_live_job_trigger_if_needed"))
        XCTAssertTrue(runner.contains("No live-job trigger found; ignoring launchd wake."))
        XCTAssertTrue(runner.contains("Consumed live-job trigger"))
        XCTAssertTrue(runner.contains("take_lock"))
        XCTAssertTrue(runner.contains("NTFSACCESS_REMOUNT_CYCLES"))
        XCTAssertTrue(runner.contains("NTFSACCESS_SOAK_CYCLES"))
        XCTAssertTrue(runner.contains("NTFSACCESS_MULTI_CYCLES"))
        XCTAssertTrue(runner.contains("NTFSACCESS_LARGE_FILE_MIB"))
        XCTAssertTrue(runner.contains("NTFSACCESS_RANDOM_FILE_COUNT"))
        XCTAssertTrue(runner.contains("NTFSACCESS_RANDOM_FILE_MIB"))
        XCTAssertTrue(runner.contains("NTFSACCESS_MULTI_SOURCE_MIB"))
        XCTAssertTrue(runner.contains("export NTFSACCESS_LARGE_FILE_MIB=\"$LARGE_FILE_MIB\""))
        XCTAssertTrue(runner.contains("export NTFSACCESS_MULTI_SOURCE_MIB=\"$MULTI_SOURCE_MIB\""))
        XCTAssertTrue(runner.contains("--skip-install"))
        XCTAssertTrue(runner.contains("run_live_multi_device_admin_batch.sh"))
        XCTAssertTrue(runner.contains("fail \"Installed live-test script missing or not executable: $RUN_SCRIPT\""))
        XCTAssertFalse(runner.contains("STAGE_ROOT/scripts/run_live_multi_device_admin_batch.sh"))
        XCTAssertFalse(runner.contains("STRICT_INSTALLED"))
        XCTAssertFalse(runner.localizedCaseInsensitiveContains("osascript"))
        XCTAssertFalse(runner.localizedCaseInsensitiveContains("security "))
        XCTAssertFalse(runner.localizedCaseInsensitiveContains("keychain"))
        XCTAssertFalse(runner.contains("/Users/weimingchen/Documents"))
    }

    func testCLIExposesPromptReductionLiveJobCommands() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("case \"preflight-live\""))
        XCTAssertTrue(source.contains("case \"stage-live-job\""))
        XCTAssertTrue(source.contains("case \"live-job-status\""))
        XCTAssertTrue(source.contains("case \"retry-mounts\""))
        XCTAssertTrue(source.contains("runPreflightLive"))
        XCTAssertTrue(source.contains("runStageLiveJob"))
        XCTAssertTrue(source.contains("runLiveJobStatus"))
        XCTAssertTrue(source.contains("runRetryMounts"))
        XCTAssertTrue(source.contains("Shared user-session validator"))
        XCTAssertTrue(source.contains("run_live_user_validation_batch.sh"))
        XCTAssertTrue(source.contains("--start"))
        XCTAssertTrue(source.contains("retry-mounts [--wait]"))
        XCTAssertTrue(source.contains("--large-file-mib"))
        XCTAssertTrue(source.contains("--random-file-count"))
        XCTAssertTrue(source.contains("--random-file-mib"))
        XCTAssertTrue(source.contains("--multi-source-mib"))
        XCTAssertTrue(source.contains("NTFSACCESS_LARGE_FILE_MIB=\\(largeFileMiB)"))
        XCTAssertTrue(source.contains("NTFSACCESS_MULTI_SOURCE_MIB=\\(multiSourceMiB)"))
        XCTAssertTrue(source.contains("triggerLiveJob"))
        XCTAssertTrue(source.contains("setSharedDirectoryPermissionsIfOwned(path: stagedRoot.path"))
        XCTAssertTrue(source.contains("geteuid() == 0"))
        XCTAssertTrue(source.contains("owner.uint32Value == geteuid()"))
        XCTAssertTrue(source.contains("retryMountsSync"))
        XCTAssertTrue(source.contains("live-job.trigger"))
        XCTAssertTrue(source.contains("/Users/Shared/NTFSAccessLiveBatch"))
    }

    func testCLIExposesDurabilityModeAndStatusWarnings() throws {
        let source = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)
        let protocolSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessShared/XPCProtocol.swift"), encoding: .utf8)
        let clientSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessShared/XPCClient.swift"), encoding: .utf8)

        XCTAssertTrue(source.contains("case \"durability\""))
        XCTAssertTrue(source.contains("durability [status|performance|conservative]"))
        XCTAssertTrue(source.contains("durabilityMode=\\(state.durabilityModeRawValue)"))
        XCTAssertTrue(source.contains("lastWarning=\\(state.lastWarning)"))
        XCTAssertTrue(source.contains("setDurabilityModeSync(.conservative)"))
        XCTAssertTrue(protocolSource.contains("func setDurabilityMode(_ modeRawValue: String"))
        XCTAssertTrue(clientSource.contains("public func setDurabilityMode("))
    }

    func testFullValidationLogsFlushEvidenceAfterSyncAndRemount() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_full_validation.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("durability=flush-evidence phase=pre-remount sync=ok"))
        XCTAssertTrue(script.contains("durability=flush-evidence phase=post-remount sync=ok remount=ok sha256=ok md5=ok"))
    }

    func testNativeReadOnlyRecoveryScriptDoesNotDeletePreexistingDisabledBundle() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/recover_native_readonly_mount.sh"), encoding: .utf8)

        XCTAssertFalse(script.contains("rm -rf \"$DISABLED\""))
        XCTAssertTrue(script.contains("Refusing to delete existing disabled bundle path"))
        XCTAssertTrue(script.contains("exit 78"))
    }

    func testXPCProtocolExposesRetryMountsForPrivacyRecovery() throws {
        let protocolSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessShared/XPCProtocol.swift"), encoding: .utf8)
        let clientSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessShared/XPCClient.swift"), encoding: .utf8)
        let cliSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)

        XCTAssertTrue(protocolSource.contains("func retryMounts(_ reply: @escaping (OperationResultDTO) -> Void)"))
        XCTAssertTrue(clientSource.contains("public func retryMounts("))
        XCTAssertTrue(clientSource.contains("proxy.retryMounts"))
        XCTAssertTrue(clientSource.contains("public func retryMountsSync"))
        XCTAssertTrue(clientSource.contains("public func retryMountsBlocking("))
        XCTAssertTrue(clientSource.contains("public func retryMountsBlockingSync"))
        XCTAssertTrue(protocolSource.contains("func retryMountsBlocking(_ reply: @escaping (OperationResultDTO) -> Void)"))
        XCTAssertTrue(cliSource.contains("Unknown retry-mounts option"))
        XCTAssertTrue(cliSource.contains("wait ? client.retryMountsBlockingSync() : client.retryMountsSync()"))
    }

    func testMountDaemonAuthorizesAndRateLimitsMutatingXPC() throws {
        let daemonSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMountDaemonCore/MountDaemonProcess.swift"), encoding: .utf8)
        let protocolSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessShared/XPCProtocol.swift"), encoding: .utf8)

        XCTAssertTrue(protocolSource.contains("Read-only status calls"))
        XCTAssertTrue(protocolSource.contains("Mutating calls"))
        XCTAssertTrue(daemonSource.contains("connection.exportedObject = MountdXPCSession("))
        XCTAssertTrue(daemonSource.contains("XPCClientIdentity(connection: connection)"))
        XCTAssertTrue(daemonSource.contains("connection.effectiveUserIdentifier"))
        XCTAssertTrue(daemonSource.contains("connection.effectiveGroupIdentifier"))
        XCTAssertTrue(daemonSource.contains("MutatingXPCAuthorizer"))
        XCTAssertTrue(daemonSource.contains("requires root, the signed-in console user, or an admin user"))
        XCTAssertTrue(daemonSource.contains("XPCMutationRateLimiter"))
        XCTAssertTrue(daemonSource.contains("Rate limited:"))
        XCTAssertTrue(daemonSource.contains("case setDurabilityMode"))
    }

    func testDoctorReportsRunningMountDaemonIdentityForFullDiskAccessTroubleshooting() throws {
        let cliSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)
        let dependencySource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSAccessCore/DependencyChecker.swift"), encoding: .utf8)

        XCTAssertTrue(cliSource.contains("Running mount daemon: \\(report.runningMountDaemonProgram ?? \"not running\")"))
        XCTAssertTrue(cliSource.contains("Running mount daemon signature: \\(report.runningMountDaemonSignatureDescription)"))
        XCTAssertTrue(dependencySource.contains("launchctl\", [\"print\", \"system/com.ntfsaccess.mountd\"]"))
        XCTAssertTrue(dependencySource.contains("program = "))
        XCTAssertTrue(dependencySource.contains("signatureDescription(forPath: runningMountDaemonProgram)"))
    }

    func testMultiDeviceAdminBatchFailsWhenTargetsNeverBecomeReadWrite() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("READWRITE_TARGET_COUNT=0"))
        XCTAssertTrue(script.contains("record_readwrite_target"))
        XCTAssertTrue(script.contains("NO_READWRITE_TARGETS"))
        XCTAssertTrue(script.contains("retry-mounts --wait"))
        XCTAssertTrue(script.contains("run_with_timeout 120 \"$NTFSACCESSCTL\" retry-mounts --wait"))
        XCTAssertTrue(script.contains("run_with_timeout 120 \"$NTFSACCESSCTL\" scan-now --wait"))
        XCTAssertTrue(script.contains("for attempt in 1 2; do"))
        XCTAssertTrue(script.contains("/bin/sleep 4"))
        let rawWaitLines = script.split(separator: "\n").filter { line in
            let text = String(line)
            return (text.contains("\"$NTFSACCESSCTL\" retry-mounts --wait") || text.contains("\"$NTFSACCESSCTL\" scan-now --wait"))
                && !text.contains("run_with_timeout")
                && !text.contains("XCTAssert")
        }
        XCTAssertTrue(rawWaitLines.isEmpty, "admin scan waits must be bounded by run_with_timeout: \(rawWaitLines)")
        XCTAssertTrue(script.contains("BLOCKED_RAW_ACCESS_OR_MOUNT"))
        XCTAssertTrue(script.contains("exit 75"))
        XCTAssertFalse(script.contains("SKIP validators for $device ($name): not readWrite\"\n    return 0"))
    }

    func testMultiDeviceAdminBatchPerformsOnePromptInstallIdentityRepairAndDaemonReload() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("repair_installed_identity_for_daemon"))
        XCTAssertTrue(script.contains("reload_mount_daemon"))
        XCTAssertTrue(script.contains("wait_for_mount_daemon_unloaded"))
        XCTAssertTrue(script.contains("bootstrap_mount_daemon_with_retry"))
        XCTAssertTrue(script.contains("wait_for_mount_daemon_ready"))
        XCTAssertTrue(script.contains("chown -R root:wheel \"$APP_PATH\""))
        XCTAssertTrue(script.contains("xattr -cr \"$APP_PATH\""))
        XCTAssertTrue(script.contains("launchctl bootout system/com.ntfsaccess.mountd"))
        XCTAssertTrue(script.contains("launchd bootstrap attempt $attempt/$max_attempts"))
        XCTAssertTrue(script.contains("launchctl bootstrap system \"$DAEMON_PLIST\""))
        XCTAssertTrue(script.contains("launchctl print system/com.ntfsaccess.mountd"))
        XCTAssertTrue(script.contains("mount-daemon-reload"))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "repair_installed_identity_for_daemon")?.lowerBound),
            try XCTUnwrap(script.range(of: "request_scans")?.lowerBound)
        )
    }

    func testNoPasswordLiveJobDaemonRunsInstalledRunnerOnlyOnSharedTrigger() throws {
        let plist = try readPlist("Packaging/LaunchDaemons/com.ntfsaccess.livejob.plist")
        let postinstall = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Scripts/postinstall"), encoding: .utf8)
        let uninstall = try String(contentsOf: repositoryRoot().appendingPathComponent("Packaging/Scripts/uninstall.sh"), encoding: .utf8)

        XCTAssertEqual(plist["Label"] as? String, "com.ntfsaccess.livejob")
        XCTAssertEqual(
            plist["ProgramArguments"] as? [String],
            [
                "/Library/Application Support/NTFSAccess/live_job_runner.sh",
                "/Users/Shared/NTFSAccessLiveBatch/requests/live-job.conf"
            ]
        )
        XCTAssertEqual(plist["WatchPaths"] as? [String], ["/Users/Shared/NTFSAccessLiveBatch/requests/live-job.trigger"])
        let environment = try XCTUnwrap(plist["EnvironmentVariables"] as? [String: String])
        XCTAssertNil(environment["NTFSACCESS_STRICT_INSTALLED_LIVE_SCRIPTS"])
        XCTAssertEqual(environment["NTFSACCESS_FORCE_SKIP_INSTALL"], "1")
        XCTAssertEqual(environment["NTFSACCESS_REQUIRE_LIVEJOB_TRIGGER"], "1")

        XCTAssertTrue(postinstall.contains("com.ntfsaccess.livejob.plist"))
        XCTAssertTrue(postinstall.contains("bootstrap_system_service_with_retry com.ntfsaccess.livejob \"$LIVEJOB_PLIST\""))
        XCTAssertTrue(postinstall.contains("prepare_livejob_directory \"$LIVEJOB_STAGE\" 755"))
        XCTAssertTrue(postinstall.contains("prepare_livejob_directory \"$LIVEJOB_STAGE/requests\" 1777"))
        XCTAssertTrue(postinstall.contains("prepare_livejob_directory \"$LIVEJOB_STAGE/logs\" 755"))
        XCTAssertTrue(postinstall.contains("consume_stale_live_job_trigger"))
        XCTAssertTrue(postinstall.contains("rm -f \"$LIVEJOB_STAGE/requests/live-job.trigger\""))
        XCTAssertLessThan(
            try XCTUnwrap(postinstall.range(of: "consume_stale_live_job_trigger")?.lowerBound),
            try XCTUnwrap(postinstall.range(of: "bootstrap_system_service_with_retry com.ntfsaccess.livejob \"$LIVEJOB_PLIST\"")?.lowerBound)
        )
        XCTAssertTrue(postinstall.contains("chown root:wheel \"$path\""))
        XCTAssertFalse(postinstall.contains("chmod 777"))
        XCTAssertFalse(postinstall.contains("chmod 666"))
        XCTAssertFalse(postinstall.contains("touch \"$LIVEJOB_STAGE/live-job.trigger\""))
        XCTAssertTrue(uninstall.contains("com.ntfsaccess.livejob.plist"))
        XCTAssertTrue(uninstall.contains("launchctl bootout system \"$LIVEJOB_PLIST\""))
    }

    func testLiveJobSupportInstallerAvoidsReplacingInstalledAppBundle() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/install_live_job_support.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("Installed NTFS Access live-job support without replacing /Applications/NTFS Access.app"))
        XCTAssertTrue(script.contains("/Library/Application Support/NTFSAccess"))
        XCTAssertTrue(script.contains("/Library/LaunchDaemons/com.ntfsaccess.livejob.plist"))
        XCTAssertTrue(script.contains("/usr/local/bin/ntfsaccessctl"))
        XCTAssertTrue(script.contains("run_live_user_validation_batch.sh"))
        XCTAssertTrue(script.contains("run_live_deadline_guarded_stress.sh"))
        XCTAssertTrue(script.contains("live_ntfs_guided_unplug_replug.sh"))
        XCTAssertTrue(script.contains("live_ntfs_guided_sleep_wake.sh"))
        XCTAssertTrue(script.contains("REQUEST_ROOT=\"$STAGE_ROOT/requests\""))
        XCTAssertTrue(script.contains("prepare_root_directory \"$STAGE_ROOT\" 755"))
        XCTAssertTrue(script.contains("prepare_root_directory \"$REQUEST_ROOT\" 1777"))
        XCTAssertTrue(script.contains("prepare_root_directory \"$STAGE_ROOT/logs\" 755"))
        XCTAssertTrue(script.contains("rm -f \"$REQUEST_ROOT/live-job.trigger\""))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "rm -f \"$REQUEST_ROOT/live-job.trigger\"")?.lowerBound),
            try XCTUnwrap(script.range(of: "/bin/launchctl bootstrap system \"$LIVEJOB_PLIST\"")?.lowerBound)
        )
        XCTAssertTrue(script.contains("chown root:wheel \"$path\""))
        XCTAssertFalse(script.contains("chmod 777"))
        XCTAssertFalse(script.contains("chmod 666"))
        XCTAssertFalse(script.contains("touch \"$STAGE_ROOT/live-job.conf\" \"$STAGE_ROOT/live-job.trigger\""))
        XCTAssertTrue(script.contains("launchctl bootstrap system \"$LIVEJOB_PLIST\""))
        XCTAssertFalse(script.contains("/Applications/NTFS Access.app/Contents/MacOS/NTFSMenuApp"))
        XCTAssertFalse(script.contains("NTFS Access.app\" \"$"))
    }

    func testGuidedPhysicalLifecycleValidatorsArePackagedAndInteractiveOnly() throws {
        let replug = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_guided_unplug_replug.sh"), encoding: .utf8)
        let sleepWake = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_guided_sleep_wake.sh"), encoding: .utf8)
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        for script in [replug, sleepWake] {
            XCTAssertTrue(script.contains("must run as the logged-in user, not root"))
            XCTAssertTrue(script.contains("guided prompt requires an interactive terminal"))
            XCTAssertTrue(script.contains("signed-in user cannot enter mount root"))
            XCTAssertTrue(script.contains("signed-in user cannot write mount root"))
            XCTAssertTrue(script.contains("expected exactly one ntfs-3g process"))
            XCTAssertTrue(script.contains("/usr/bin/shasum -a 256"))
            XCTAssertTrue(script.contains("/sbin/md5 -q"))
            XCTAssertTrue(script.contains("retry-mounts --wait"))
            XCTAssertTrue(script.contains("macFUSE-backed"))
            XCTAssertTrue(script.contains("readWrite"))
            XCTAssertFalse(script.localizedCaseInsensitiveContains("osascript"))
            XCTAssertFalse(script.localizedCaseInsensitiveContains("keychain"))
        }

        XCTAssertTrue(replug.contains("Unplug the physical NTFS drive now"))
        XCTAssertTrue(replug.contains("Replug the same physical NTFS drive now"))
        XCTAssertTrue(sleepWake.contains("pmset sleepnow"))
        XCTAssertTrue(sleepWake.contains("Sleep the Mac now, wake it"))
        XCTAssertTrue(packageScript.contains("live_ntfs_guided_unplug_replug.sh"))
        XCTAssertTrue(packageScript.contains("live_ntfs_guided_sleep_wake.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_unplug_replug.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_guided_sleep_wake.sh"))
    }

    func testLiveJobRunnerValidatesRootConsumedRequestsAndCreatesSafeLogs() throws {
        let runner = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_job_runner.sh"), encoding: .utf8)
        let cliSource = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)
        let stageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/stage_live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(runner.contains("umask 077"))
        XCTAssertTrue(runner.contains("REQUEST_ROOT=\"$STAGE_ROOT/requests\""))
        XCTAssertTrue(runner.contains("validate_regular_file_for_root_read \"$CONFIG_PATH\" \"Config\""))
        XCTAssertTrue(runner.contains("TRIGGER_PATH=\"$REQUEST_ROOT/live-job.trigger\""))
        XCTAssertTrue(runner.contains("validate_regular_file_for_root_read \"$TRIGGER_PATH\" \"Trigger\""))
        XCTAssertTrue(runner.contains("/bin/rm -f \"$TRIGGER_PATH\""))
        XCTAssertTrue(runner.contains("require_live_job_trigger_if_needed"))
        XCTAssertTrue(runner.contains("[[ ! -L \"$path\" ]]"))
        XCTAssertTrue(runner.contains("[[ -f \"$path\" ]]"))
        XCTAssertTrue(runner.contains("file_type=\"$(/usr/bin/stat -f '%HT' \"$path\""))
        XCTAssertTrue(runner.contains("owner uid $owner is not root or console uid"))
        XCTAssertTrue(runner.contains("must not be world-writable"))
        XCTAssertTrue(runner.contains("LOG_PATH=\"$(/usr/bin/mktemp \"$LOG_ROOT/live-job-$RUN_ID.XXXXXX\")\""))
        XCTAssertTrue(runner.contains("validate_executable_for_root_run \"$RUN_SCRIPT\" \"Live run script\""))
        XCTAssertTrue(runner.contains("must not be group/world-writable"))
        XCTAssertTrue(runner.contains("owner uid $owner is not root"))
        XCTAssertTrue(runner.contains("ln -s \"$LOG_PATH\" \"$LATEST_LOG\""))
        XCTAssertFalse(runner.contains(": > \"$LATEST_LOG\""))
        XCTAssertFalse(runner.contains(": > \"$LOG_PATH\""))
        XCTAssertFalse(runner.contains("chmod -R a+rX \"$STAGE_ROOT\""))
        XCTAssertFalse(runner.contains("chmod 777"))
        XCTAssertFalse(runner.contains("chmod 666"))
        XCTAssertTrue(cliSource.contains("appendingPathComponent(\"requests\", isDirectory: true)"))
        XCTAssertTrue(cliSource.contains("0o1777"))
        XCTAssertTrue(cliSource.contains("[\"644\", configURL.path]"))
        XCTAssertTrue(cliSource.contains("[\"644\", triggerURL.path]"))
        XCTAssertFalse(cliSource.contains("FileManager.default.createFile(\n                atPath: requestRoot.appendingPathComponent(\"live-job.trigger\").path"))
        XCTAssertTrue(stageScript.contains("REQUEST_ROOT=\"$STAGE_ROOT/requests\""))
        XCTAssertTrue(stageScript.contains("chmod 1777 \"$REQUEST_ROOT\""))
        XCTAssertFalse(stageScript.contains("chmod 777"))
        XCTAssertFalse(stageScript.contains("chmod 666"))
    }

    func testMultiDeviceAdminBatchHasConfigurableValidatorLoopSizes() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("REMOUNT_CYCLES=\"${NTFSACCESS_REMOUNT_CYCLES:-8}\""))
        XCTAssertTrue(script.contains("SOAK_CYCLES=\"${NTFSACCESS_SOAK_CYCLES:-20}\""))
        XCTAssertTrue(script.contains("MULTI_CYCLES=\"${NTFSACCESS_MULTI_CYCLES:-8}\""))
        XCTAssertTrue(script.contains("\"$REMOUNT_VALIDATOR\" \"$device\" \"$name\" \"$REMOUNT_CYCLES\""))
        XCTAssertTrue(script.contains("\"$SOAK_VALIDATOR\" \"$device\" \"$name\" \"$SOAK_CYCLES\""))
        XCTAssertTrue(script.contains("\"$MULTI_VALIDATOR\""))
        XCTAssertTrue(script.contains("\"$MULTI_CYCLES\""))
    }

    func testMultiDeviceAdminBatchRunsWriteHeavyValidatorsAsConsoleUserInsideGuiSession() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_multi_device_admin_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail"))
        XCTAssertTrue(script.contains("--run-write-validators"))
        XCTAssertTrue(script.contains("RUN_WRITE_VALIDATORS=0"))
        XCTAssertTrue(script.contains("RUN_WRITE_VALIDATORS=1"))
        XCTAssertTrue(script.contains("runWriteValidators=$RUN_WRITE_VALIDATORS"))
        XCTAssertTrue(script.contains("== console-user-gui validator ($CONSOLE_USER uid=$CONSOLE_UID) $* =="))
        XCTAssertTrue(script.contains("/bin/launchctl asuser \"$CONSOLE_UID\" /usr/bin/sudo -u \"$CONSOLE_USER\" /usr/bin/env"))
        XCTAssertTrue(script.contains("return \"$status\""))
        XCTAssertTrue(script.contains("record_validator_failure"))
        XCTAssertTrue(script.contains("FAILED_VALIDATOR_COUNT=$FAILURES"))
        XCTAssertTrue(script.contains("exit 75"))
        XCTAssertTrue(script.contains("take_validation_lock"))
        XCTAssertTrue(script.contains("VALIDATION_LOCK_DIR=\"${NTFSACCESS_VALIDATION_LOCK_DIR:-/Users/Shared/NTFSAccessLiveBatch/.validation.lock}\""))
        XCTAssertTrue(script.contains("if [[ \"$RUN_WRITE_VALIDATORS\" -eq 1 ]]; then"))
        XCTAssertTrue(script.contains("SKIP write-heavy validators in admin/root batch"))
        let wrapperStart = try XCTUnwrap(script.range(of: "run_in_console_user_gui_session_allow_fail()")?.lowerBound)
        let wrapperEnd = try XCTUnwrap(script.range(of: "take_validation_lock()", range: wrapperStart..<script.endIndex)?.lowerBound)
        let wrapperBody = String(script[wrapperStart..<wrapperEnd])
        XCTAssertFalse(wrapperBody.contains("return 0"))
        XCTAssertFalse(script.contains("/bin/launchctl asuser \"$CONSOLE_UID\" \"$@\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$FULL_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$METADATA_PACKAGE_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$FILENAME_MATRIX_VALIDATOR\" \"$device\" \"$name\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$REMOUNT_VALIDATOR\" \"$device\" \"$name\" \"$REMOUNT_CYCLES\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$SOAK_VALIDATOR\" \"$device\" \"$name\" \"$SOAK_CYCLES\""))
        XCTAssertTrue(script.contains("run_in_console_user_gui_session_allow_fail \"$MULTI_VALIDATOR\""))
        XCTAssertFalse(script.contains("== root validator $* =="))
    }

    func testUserValidationBatchRunsWriteHeavyValidatorsOutsideRootDaemon() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_user_validation_batch.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("must run as the logged-in user, not root"))
        XCTAssertTrue(script.contains("if [[ \"$EUID\" -eq 0 ]]; then"))
        XCTAssertTrue(script.contains("direct_user_write_probe"))
        XCTAssertTrue(script.contains("take_validation_lock"))
        XCTAssertTrue(script.contains("VALIDATION_LOCK_DIR=\"${NTFSACCESS_VALIDATION_LOCK_DIR:-$STAGE_ROOT/.validation.lock}\""))
        XCTAssertTrue(script.contains("Another NTFS Access live validation is already running as pid $existing_pid"))
        XCTAssertTrue(script.contains("request_scan()"))
        XCTAssertTrue(script.contains("run_with_timeout 120 \"$NTFSACCESSCTL\" scan-now --wait"))
        let rawScanLines = script.split(separator: "\n").filter { line in
            line.contains("\"$NTFSACCESSCTL\" scan-now") && !line.contains("run_with_timeout")
        }
        XCTAssertTrue(rawScanLines.isEmpty, "run_live_user_validation_batch.sh scan-now calls must go through request_scan timeout wrapper: \(rawScanLines)")
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$FULL_VALIDATOR\" \"$device\" \"$name\" || break"))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$METADATA_PACKAGE_VALIDATOR\" \"$device\" \"$name\" || break"))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$FILENAME_MATRIX_VALIDATOR\" \"$device\" \"$name\" || break"))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$REMOUNT_VALIDATOR\" \"$device\" \"$name\" \"$REMOUNT_CYCLES\" || break"))
        XCTAssertTrue(script.contains("run_validator_stop_on_fail \"$SOAK_VALIDATOR\" \"$device\" \"$name\" \"$SOAK_CYCLES\" || break"))
        XCTAssertTrue(script.contains("run_validator_allow_fail \"$MULTI_VALIDATOR\""))
        XCTAssertTrue(script.contains("STOP: destructive validator failed; stopping this batch to avoid cascading stale mount state"))
        XCTAssertTrue(script.contains("SKIP two-volume flow: an earlier destructive validator failed"))
        XCTAssertTrue(script.contains("latest-user-validation.log"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("osascript"))
        XCTAssertFalse(script.contains("sudo -u"))
        XCTAssertFalse(script.contains("launchctl asuser"))
    }

    func testDeadlineGuardedStressStopsBeforeDeadlineAndPreservesApfsTomorrow() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_deadline_guarded_stress.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("must run as the logged-in user, not root"))
        XCTAssertTrue(script.contains("STOP_BUFFER_SECONDS=\"${NTFSACCESS_STOP_BUFFER_SECONDS:-900}\""))
        XCTAssertTrue(script.contains("deadline guard stopping"))
        XCTAssertTrue(script.contains("apfsTomorrow=$([[ -d /Volumes/APFS_TOMORROW ]] && printf ready || printf missing)"))
        XCTAssertTrue(script.contains("purge_transient_test_dirs"))
        XCTAssertTrue(script.contains("\"$OVERNIGHT_VALIDATOR\" \"$DEVICE_A\" \"$NAME_A\" 1"))
        XCTAssertTrue(script.contains("\"$OVERNIGHT_VALIDATOR\" \"$DEVICE_B\" \"$NAME_B\" 1"))
        XCTAssertTrue(script.contains("\"$MULTI_VALIDATOR\" \"$DEVICE_A\" \"$NAME_A\" \"$DEVICE_B\" \"$NAME_B\" 1"))
        XCTAssertTrue(script.contains("NTFSAccess_overnight_*"))
        XCTAssertTrue(script.contains("NTFSAccess_filesystem_soak_*"))
        XCTAssertTrue(script.contains("NTFSAccess_remount_churn_*"))
        XCTAssertTrue(script.contains("STOPPED_BEFORE_DEADLINE"))
        XCTAssertFalse(script.localizedCaseInsensitiveContains("osascript"))
        XCTAssertFalse(script.contains("diskutil erase"))
        XCTAssertFalse(script.contains("/dev/disk12"))
    }

    func testTwoPhysicalStressCleansAllKnownLargeTransientValidationTrees() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_two_physical_user_stress.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("purge_transient_test_dirs"))
        XCTAssertTrue(script.contains("multi-flow-*"))
        XCTAssertTrue(script.contains("NTFSAccess_user_write_probe_*"))
        XCTAssertTrue(script.contains("NTFSAccess_overnight_*"))
        XCTAssertTrue(script.contains("NTFSAccess_filesystem_soak_*"))
        XCTAssertTrue(script.contains("NTFSAccess_remount_churn_*"))
        XCTAssertFalse(script.contains("/bin/rm -rf \"$mount_point\"/multi-flow-* \"$mount_point\"/NTFSAccess_user_write_probe_*"))
    }

    func testApfsRestoreGuardVerifiesMountedApfsBelongsToTargetWholeDisk() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/run_live_apfs_restore_guard.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("apfs_volume_matches_target_disk"))
        XCTAssertTrue(script.contains("diskutil info -plist \"$mount_point\""))
        XCTAssertTrue(script.contains("ParentWholeDisk"))
        XCTAssertTrue(script.contains("[[ \"$whole_disk\" == \"$EXPECTED_WHOLE_DISK_ID\" ]] || return 1"))
        XCTAssertTrue(script.contains("[[ \"$fs_type\" == \"apfs\" || \"$fs_type\" == \"APFS\" ]] || return 1"))
        XCTAssertTrue(script.contains("if apfs_volume_matches_target_disk; then"))
        XCTAssertFalse(script.contains("[[ -d \"/Volumes/$APFS_NAME\" ]] && /sbin/mount | /usr/bin/grep -Fq \"/Volumes/$APFS_NAME\""))
    }

    func testLiveFullValidationSizesLargeFileFromAvailableCapacity() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_full_validation.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("large_file_size_mib"))
        XCTAssertTrue(script.contains("df -k \"$MOUNT_POINT\""))
        XCTAssertTrue(script.contains("NTFSACCESS_LARGE_FILE_MIB"))
        XCTAssertTrue(script.contains("large-${LARGE_MIB}m.bin"))
        XCTAssertTrue(script.contains("/usr/sbin/mkfile \"${LARGE_MIB}m\" \"$LARGE_SRC\""))
        XCTAssertTrue(script.contains("copy ${LARGE_MIB}MiB file"))
        XCTAssertTrue(script.contains("large file checksum changed after remount"))
        XCTAssertFalse(script.contains("mkfile 1g"))
        XCTAssertFalse(script.contains("large-1g.bin"))
    }

    func testLiveFullValidationCanCapRandomFileWorkForSmallDrives() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_full_validation.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("random_file_count"))
        XCTAssertTrue(script.contains("random_file_size_mib"))
        XCTAssertTrue(script.contains("small_file_count"))
        XCTAssertTrue(script.contains("CLEANUP_TIMEOUT_SECONDS=\"${NTFSACCESS_CLEANUP_TIMEOUT_SECONDS:-60}\""))
        XCTAssertTrue(script.contains("NTFSACCESS_RANDOM_FILE_COUNT"))
        XCTAssertTrue(script.contains("NTFSACCESS_RANDOM_FILE_MIB"))
        XCTAssertTrue(script.contains("NTFSACCESS_SMALL_FILE_COUNT"))
        XCTAssertTrue(script.contains("RANDOM_FILE_COUNT=\"$(random_file_count)\""))
        XCTAssertTrue(script.contains("RANDOM_FILE_MIB=\"$(random_file_size_mib)\""))
        XCTAssertTrue(script.contains("SMALL_FILE_COUNT=\"$(small_file_count)\""))
        XCTAssertTrue(script.contains("randomFileCount=$RANDOM_FILE_COUNT"))
        XCTAssertTrue(script.contains("randomFileMiB=$RANDOM_FILE_MIB"))
        XCTAssertTrue(script.contains("smallFileCount=$SMALL_FILE_COUNT"))
        XCTAssertTrue(script.contains("for i in $(/usr/bin/jot \"$RANDOM_FILE_COUNT\"); do"))
        XCTAssertTrue(script.contains("/usr/sbin/mkfile \"${RANDOM_FILE_MIB}m\" \"$src\""))
        XCTAssertTrue(script.contains("for i in $(/usr/bin/jot \"$SMALL_FILE_COUNT\"); do"))
        XCTAssertTrue(script.contains("expected $SMALL_FILE_COUNT small files"))
        XCTAssertTrue(script.contains("cleanup=deferred path=$STRESS_DIR reason=timeout-after-${CLEANUP_TIMEOUT_SECONDS}s"))
        XCTAssertTrue(script.contains("for i in $(/usr/bin/jot 50); do"))
        XCTAssertTrue(script.contains("file-$(printf '%04d' \"$i\").txt"))
        XCTAssertFalse(script.contains("for i in $(/usr/bin/jot 1500); do"))
        XCTAssertFalse(script.contains("file-00{01..50}.txt"))
        XCTAssertFalse(script.contains("for i in $(/usr/bin/jot 8); do"))
        XCTAssertFalse(script.contains("/usr/sbin/mkfile 64m \"$src\""))
    }

    func testLiveFullValidationIgnoresAppleDoubleSidecarsDuringRoundtripTreeCompare() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_full_validation.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("assert_tree_shape_ignoring_appledouble"))
        XCTAssertTrue(script.contains("compare APFS NTFS roundtrip ignoring AppleDouble metadata"))
        XCTAssertTrue(script.contains("/usr/bin/find \"$actual\" -name '._*' -print"))
        XCTAssertTrue(script.contains("appledouble_count label=$label count=$appledouble_count"))
        XCTAssertTrue(script.contains("unexpected non-AppleDouble entry"))
        XCTAssertTrue(script.contains("/usr/bin/cmp \"$path\" \"$counterpart\""))
        XCTAssertTrue(script.contains("/usr/bin/find \"$STRESS_DIR/many-small\" -name '._*' -prune -o -type f -print"))
        XCTAssertFalse(script.contains("run_step \"diff APFS NTFS roundtrip\" /usr/bin/diff -qr"))
    }

    func testLiveValidatorsParseTabDelimitedVolumeStateAndSanitizedNTFS3GVolumeNames() throws {
        let scriptNames = [
            "live_ntfs_full_validation.sh",
            "live_ntfs_remount_churn.sh",
            "live_ntfs_multi_volume_flow.sh",
            "live_ntfs_overnight_stress.sh",
            "live_ntfs_filesystem_soak.sh",
            "live_ntfs_guided_unplug_replug.sh",
            "live_ntfs_guided_sleep_wake.sh",
            "live_ntfs_finder_workflow_probe.sh",
            "live_ntfs_metadata_package_matrix.sh",
            "live_ntfs_filename_matrix.sh",
            "live_ntfs_finder_metadata_probe.sh",
            "live_ntfs_downloads_copy_probe.sh",
            "live_ntfs_performance_probe.sh"
        ]

        for scriptName in scriptNames {
            let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/\(scriptName)"), encoding: .utf8)
            if script.contains("list-volumes") {
                XCTAssertTrue(script.contains("awk -F '\\t'"), scriptName)
            }
            XCTAssertFalse(script.contains("awk -v id=\"$DEVICE_ID\" '$1 == id"), scriptName)
            XCTAssertFalse(script.contains("awk -v id=\"$id\" '$1 == id"), scriptName)
            XCTAssertFalse(script.contains("awk '{ print $4 }'"), scriptName)
        }

        for scriptName in [
            "live_ntfs_full_validation.sh",
            "live_ntfs_remount_churn.sh",
            "live_ntfs_overnight_stress.sh",
            "live_ntfs_filesystem_soak.sh",
            "live_ntfs_guided_unplug_replug.sh",
            "live_ntfs_guided_sleep_wake.sh"
        ] {
            let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/\(scriptName)"), encoding: .utf8)
            XCTAssertTrue(script.contains("ntfs3g_volname_for"), scriptName)
            XCTAssertFalse(script.contains("volname=$EXPECTED_NAME"), scriptName)
        }
    }

    func testPerformanceProbeIsPackagedForLiveValidation() throws {
        let packageScript = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/package_pkg.sh"), encoding: .utf8)
        let verifier = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/verify_install.sh"), encoding: .utf8)

        XCTAssertTrue(packageScript.contains("live_ntfs_performance_probe.sh"))
        XCTAssertTrue(verifier.contains("/Library/Application Support/NTFSAccess/live-tests/scripts/live_ntfs_performance_probe.sh"))
    }

    func testPerformanceProbeUsesIntegrityChecksCapsTimeoutsAndSummaryPath() throws {
        let script = try String(contentsOf: repositoryRoot().appendingPathComponent("scripts/live_ntfs_performance_probe.sh"), encoding: .utf8)

        XCTAssertTrue(script.contains("/tmp/ntfsaccess-performance-probe-$STAMP"))
        XCTAssertTrue(script.contains("summary.txt"))
        XCTAssertTrue(script.contains("/usr/bin/shasum -a 256"))
        XCTAssertTrue(script.contains("/sbin/md5 -q"))
        XCTAssertTrue(script.contains("available_mib"))
        XCTAssertTrue(script.contains("cap_mib"))
        XCTAssertTrue(script.contains("NTFSACCESS_PERF_MAX_MIB"))
        XCTAssertTrue(script.contains("NTFSACCESS_PERF_MIN_FREE_MIB"))
        XCTAssertTrue(script.contains("run_with_timeout"))
        XCTAssertTrue(script.contains("timeout after ${seconds}s"))
        XCTAssertTrue(script.contains("live_ntfs_performance_probe.sh must run as the logged-in user, not root"))
        XCTAssertFalse(script.contains("sudo "))
    }

    func testMenuAppContainsDashboardAndRecoveryGuidanceStrings() throws {
        let appController = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/AppController.swift"), encoding: .utf8)
        let dashboard = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/VolumeDashboardWindowController.swift"), encoding: .utf8)
        let viewModel = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/NTFSMenuApp/VolumeStatusViewModel.swift"), encoding: .utf8)

        XCTAssertTrue(appController.contains("showDashboard"))
        XCTAssertTrue(dashboard.contains("No external NTFS drives connected."))
        XCTAssertTrue(dashboard.contains("DriveGroupView"))
        XCTAssertTrue(dashboard.contains("Healthy"))
        XCTAssertFalse(dashboard.contains("NSProgressIndicator"))
        XCTAssertFalse(dashboard.contains("operationLabel"))
        XCTAssertTrue(dashboard.contains("window.maxSize = NSSize(width: DashboardLayout.windowMaxWidth, height: DashboardLayout.windowMaxHeight)"))
        XCTAssertTrue(dashboard.contains("static let windowWidth: CGFloat = 720"))
        XCTAssertTrue(dashboard.contains("static let windowMaxWidth: CGFloat = 900"))
        XCTAssertTrue(dashboard.contains("compactMessage"))
        XCTAssertTrue(dashboard.contains("compactReason"))
        XCTAssertTrue(dashboard.contains("maximumNumberOfLines = 1"))
        XCTAssertTrue(dashboard.contains("Rescan"))
        XCTAssertTrue(dashboard.contains("Open in Finder"))
        XCTAssertTrue(dashboard.contains("Eject"))
        XCTAssertTrue(dashboard.contains("Details"))
        XCTAssertTrue(dashboard.contains("handleEject"))
        XCTAssertTrue(dashboard.contains("autohidesScrollers = true"))
        XCTAssertTrue(dashboard.contains("widthAnchor.constraint(equalTo: rowsStack.widthAnchor)"))
        XCTAssertTrue(dashboard.contains("renderedRowsSignature"))
        XCTAssertTrue(dashboard.contains("renderedRowsMinimumHeight"))
        XCTAssertTrue(dashboard.contains("guard signature != renderedRowsSignature else"))
        XCTAssertTrue(dashboard.contains("DashboardLayout.documentHeight(for: groups)"))
        XCTAssertTrue(dashboard.contains("minimumContentHeight"))
        XCTAssertTrue(dashboard.contains("max(rowsStack.fittingSize.height, renderedRowsMinimumHeight)"))
        XCTAssertFalse(dashboard.contains("rowsStack.bottomAnchor.constraint(equalTo: rowsDocumentView.bottomAnchor)"))
        XCTAssertTrue(dashboard.contains("heightAnchor.constraint(greaterThanOrEqualToConstant: DashboardLayout.volumeRowMinHeight)"))
        XCTAssertTrue(dashboard.contains("widthAnchor.constraint(equalToConstant: DashboardLayout.statusButtonWidth)"))
        XCTAssertTrue(dashboard.contains("widthAnchor.constraint(equalToConstant: DashboardLayout.openButtonWidth)"))
        XCTAssertTrue(dashboard.contains("widthAnchor.constraint(equalToConstant: DashboardLayout.ejectButtonWidth)"))
        XCTAssertTrue(dashboard.contains("widthAnchor.constraint(equalToConstant: DashboardLayout.detailsButtonWidth)"))
        XCTAssertTrue(viewModel.contains("Full Disk Access"))
        XCTAssertTrue(viewModel.contains("remove it from the list"))
        XCTAssertTrue(viewModel.contains("new privacy identity"))
        XCTAssertTrue(viewModel.contains("macFUSE"))
        XCTAssertTrue(viewModel.contains("Windows cleanup"))
        XCTAssertTrue(viewModel.contains("repairVolume"))
        XCTAssertTrue(viewModel.contains("ejectVolume"))
        XCTAssertTrue(viewModel.contains("return \"Fix\""))
        let cli = try String(contentsOf: repositoryRoot().appendingPathComponent("Sources/ntfsaccessctl/main.swift"), encoding: .utf8)
        XCTAssertTrue(cli.contains("list-volumes --verbose") || cli.contains("PARENT_WHOLE_DISK_NAME"))
        XCTAssertTrue(cli.contains("repair-volume"))
        XCTAssertTrue(cli.contains("eject-volume"))
        XCTAssertTrue(cli.contains("repairVolumeSync"))
        XCTAssertTrue(cli.contains("ejectVolumeSync"))
        XCTAssertFalse(viewModel.localizedCaseInsensitiveContains("keychain"))
        XCTAssertFalse(dashboard.localizedCaseInsensitiveContains("keychain"))
    }

    private func readPlist(_ relativePath: String) throws -> [String: Any] {
        let data = try Data(contentsOf: repositoryRoot().appendingPathComponent(relativePath))
        return try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
