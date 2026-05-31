import AppKit

@MainActor
final class VolumeDashboardWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let viewModel: VolumeStatusViewModel
    private let rowsStack = NSStackView()
    private let rowsDocumentView = FlippedDocumentView()
    private let scrollView = NSScrollView()
    private let serviceLabel = NSTextField(labelWithString: "Checking NTFS Access...")
    private let updatedLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No external NTFS drives connected.")
    private var pollTimer: Timer?
    private var rowsDocumentWidthConstraint: NSLayoutConstraint?
    private var rowsDocumentHeightConstraint: NSLayoutConstraint?
    private var renderedRowsSignature: [String]?
    private var renderedRowsMinimumHeight: CGFloat = 0

    init(viewModel: VolumeStatusViewModel = VolumeStatusViewModel()) {
        self.viewModel = viewModel

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "NTFS Drives"
        window.minSize = NSSize(width: 520, height: 300)

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContentView()

        viewModel.onChange = { [weak self] snapshot in
            self?.render(snapshot)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
        viewModel.refresh()
    }

    override func close() {
        stopPolling()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        stopPolling()
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        updateRowsDocumentFrame()
    }

    private func makeContentView() -> NSView {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        root.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: "NTFS Drives")
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)

        let rescanButton = NSButton(title: "Rescan", target: self, action: #selector(handleRescan))
        rescanButton.bezelStyle = .rounded

        let header = NSStackView(views: [titleLabel, NSView(), rescanButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        serviceLabel.textColor = .secondaryLabelColor
        serviceLabel.lineBreakMode = .byTruncatingTail
        updatedLabel.textColor = .tertiaryLabelColor
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center

        let statusLine = NSStackView(views: [serviceLabel, NSView(), updatedLabel])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 8

        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = 8
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        rowsDocumentView.translatesAutoresizingMaskIntoConstraints = false
        rowsDocumentView.addSubview(rowsStack)
        scrollView.documentView = rowsDocumentView

        let widthConstraint = rowsDocumentView.widthAnchor.constraint(equalToConstant: 520)
        let heightConstraint = rowsDocumentView.heightAnchor.constraint(equalToConstant: 220)
        rowsDocumentWidthConstraint = widthConstraint
        rowsDocumentHeightConstraint = heightConstraint

        root.addArrangedSubview(header)
        root.addArrangedSubview(statusLine)
        root.addArrangedSubview(scrollView)

        let contentView = NSView()
        contentView.addSubview(root)

        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            root.topAnchor.constraint(equalTo: contentView.topAnchor),
            root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            header.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            statusLine.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scrollView.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -32),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),
            widthConstraint,
            heightConstraint,
            rowsStack.leadingAnchor.constraint(equalTo: rowsDocumentView.leadingAnchor),
            rowsDocumentView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor),
            rowsStack.topAnchor.constraint(equalTo: rowsDocumentView.topAnchor)
        ])

        return contentView
    }

    private func startPolling() {
        guard pollTimer == nil else {
            return
        }

        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.viewModel.refresh()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func render(_ snapshot: DashboardSnapshot) {
        serviceLabel.stringValue = serviceText(for: snapshot)
        updatedLabel.stringValue = snapshot.updatedAt.map { "Updated \(Self.timeFormatter.string(from: $0))" } ?? ""
        let signature = rowsSignature(for: snapshot.rows)
        guard signature != renderedRowsSignature else {
            return
        }
        renderedRowsSignature = signature
        renderRows(snapshot.rows)
    }

    private func rowsSignature(for rows: [VolumeStatusRow]) -> [String] {
        if rows.isEmpty {
            return ["empty"]
        }

        return rows.map { row in
            [
                row.id,
                row.deviceIdentifier,
                row.parentWholeDisk,
                row.driveGroupTitle,
                row.displayName,
                row.mountPoint,
                row.modeLabel,
                row.reasonLabel,
                row.statusColor.rawValue,
                row.primaryAction.rawValue,
                row.isFixEnabled ? "fix" : "healthy"
            ].joined(separator: "|")
        }
    }

    private func renderRows(_ rows: [VolumeStatusRow]) {
        rowsStack.arrangedSubviews.forEach { view in
            rowsStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard !rows.isEmpty else {
            renderedRowsMinimumHeight = DashboardLayout.emptyRowsHeight
            rowsStack.addArrangedSubview(emptyLabel)
            updateRowsDocumentFrame()
            return
        }

        let groups = DriveGroup.group(rows)
        renderedRowsMinimumHeight = DashboardLayout.documentHeight(for: groups)
        for group in groups {
            rowsStack.addArrangedSubview(DriveGroupView(group: group, target: self))
        }

        updateRowsDocumentFrame()
    }

    private func updateRowsDocumentFrame() {
        let contentWidth = max(scrollView.contentSize.width, 1)
        rowsDocumentWidthConstraint?.constant = contentWidth
        let minimumContentHeight = max(scrollView.contentSize.height, renderedRowsMinimumHeight, 1)
        rowsDocumentHeightConstraint?.constant = minimumContentHeight
        rowsDocumentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: minimumContentHeight)
        rowsStack.layoutSubtreeIfNeeded()

        let fittingHeight = max(rowsStack.fittingSize.height, renderedRowsMinimumHeight)
        let contentHeight = max(scrollView.contentSize.height, fittingHeight, 1)
        rowsDocumentHeightConstraint?.constant = contentHeight
        rowsDocumentView.frame = NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight)
        rowsDocumentView.needsLayout = true
        rowsStack.needsLayout = true
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func serviceText(for snapshot: DashboardSnapshot) -> String {
        if snapshot.serviceMessage.isEmpty {
            return "Service: \(snapshot.serviceHealth.rawValue)"
        }

        return "Service: \(snapshot.serviceHealth.rawValue) - \(snapshot.serviceMessage)"
    }

    @objc private func handleRescan() {
        viewModel.rescan()
    }

    @objc fileprivate func handleFix(_ sender: VolumeRowButton) {
        guard let row = sender.row else {
            return
        }

        viewModel.fix(row: row)
    }

    @objc fileprivate func handleOpenInFinder(_ sender: VolumeRowButton) {
        guard let row = sender.row else {
            return
        }

        viewModel.openInFinder(row: row)
    }

    @objc fileprivate func handleEject(_ sender: VolumeRowButton) {
        guard let row = sender.row else {
            return
        }

        viewModel.eject(row: row)
    }

    @objc fileprivate func handleDetails(_ sender: VolumeRowButton) {
        guard let row = sender.row else {
            return
        }

        let alert = NSAlert()
        alert.messageText = row.displayName
        alert.informativeText = viewModel.detailsMessage(for: row)
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window ?? NSWindow()) { _ in }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}

private struct DriveGroup {
    let title: String
    let subtitle: String
    let rows: [VolumeStatusRow]

    static func group(_ rows: [VolumeStatusRow]) -> [DriveGroup] {
        let grouped = Dictionary(grouping: rows) { row in
            row.parentWholeDisk.isEmpty ? row.driveDisplayName : row.parentWholeDisk
        }

        return grouped.map { _, rows in
            let sortedRows = rows.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            let first = sortedRows[0]
            return DriveGroup(
                title: first.driveGroupTitle,
                subtitle: subtitle(for: first, count: sortedRows.count),
                rows: sortedRows
            )
        }
        .sorted {
            guard let lhsFirst = $0.rows.first,
                  let rhsFirst = $1.rows.first else {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return lhsFirst.driveSortKey.localizedStandardCompare(rhsFirst.driveSortKey) == .orderedAscending
        }
    }

    private static func subtitle(for row: VolumeStatusRow, count: Int) -> String {
        let countLabel = count == 1 ? "1 NTFS partition" : "\(count) NTFS partitions"
        guard !row.parentWholeDisk.isEmpty else {
            return countLabel
        }
        return "\(countLabel)"
    }
}

private final class DriveGroupView: NSView {
    init(group: DriveGroup, target: VolumeDashboardWindowController) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: group.title)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: group.subtitle)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail

        let header = NSStackView(views: [title, NSView(), subtitle])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8

        let rows = NSStackView()
        rows.orientation = .vertical
        rows.alignment = .width
        rows.spacing = 6
        for row in group.rows {
            rows.addArrangedSubview(VolumeStatusRowView(row: row, target: target))
        }

        let stack = NSStackView(views: [header, rows])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setContentCompressionResistancePriority(.required, for: .vertical)

        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        addSubview(stack)
        let groupMinimumHeight = DashboardLayout.driveGroupHeight(rowCount: group.rows.count)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            heightAnchor.constraint(greaterThanOrEqualToConstant: groupMinimumHeight)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class VolumeStatusRowView: NSView {
    init(row: VolumeStatusRow, target: VolumeDashboardWindowController) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 5
        chip.layer?.backgroundColor = row.statusColor.nsColor.cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: row.displayName)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail

        let detail = NSTextField(labelWithString: row.modeLabel)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail

        let reason = NSTextField(labelWithString: row.reasonLabel)
        reason.textColor = .tertiaryLabelColor
        reason.lineBreakMode = .byTruncatingTail

        let textStack = NSStackView(views: row.reasonLabel.isEmpty ? [title, detail] : [title, detail, reason])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let statusButton = row.isFixEnabled
            ? VolumeRowButton(title: row.fixButtonTitle, target: target, action: #selector(VolumeDashboardWindowController.handleFix(_:)), row: row)
            : VolumeRowButton(title: "Healthy", target: nil, action: nil, row: row)
        statusButton.isEnabled = row.isFixEnabled
        statusButton.bezelStyle = .rounded

        let openButton = VolumeRowButton(title: "Open in Finder", target: target, action: #selector(VolumeDashboardWindowController.handleOpenInFinder(_:)), row: row)
        openButton.isEnabled = !row.mountPoint.isEmpty
        openButton.bezelStyle = .rounded

        let ejectButton = VolumeRowButton(title: "Eject", target: target, action: #selector(VolumeDashboardWindowController.handleEject(_:)), row: row)
        ejectButton.isEnabled = !row.mountPoint.isEmpty
        ejectButton.bezelStyle = .rounded

        let detailsButton = VolumeRowButton(title: "Details", target: target, action: #selector(VolumeDashboardWindowController.handleDetails(_:)), row: row)
        detailsButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [statusButton, openButton, ejectButton, detailsButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 6
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)
        buttons.setContentHuggingPriority(.required, for: .horizontal)

        let body = NSStackView(views: [chip, textStack, NSView(), buttons])
        body.orientation = .horizontal
        body.alignment = .centerY
        body.spacing = 10
        body.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        body.translatesAutoresizingMaskIntoConstraints = false

        addSubview(body)
        NSLayoutConstraint.activate([
            chip.widthAnchor.constraint(equalToConstant: 10),
            chip.heightAnchor.constraint(equalToConstant: 10),
            statusButton.widthAnchor.constraint(equalToConstant: DashboardLayout.statusButtonWidth),
            openButton.widthAnchor.constraint(equalToConstant: DashboardLayout.openButtonWidth),
            ejectButton.widthAnchor.constraint(equalToConstant: DashboardLayout.ejectButtonWidth),
            detailsButton.widthAnchor.constraint(equalToConstant: DashboardLayout.detailsButtonWidth),
            body.leadingAnchor.constraint(equalTo: leadingAnchor),
            body.trailingAnchor.constraint(equalTo: trailingAnchor),
            body.topAnchor.constraint(equalTo: topAnchor),
            body.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: DashboardLayout.volumeRowMinHeight)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }
}

private final class VolumeRowButton: NSButton {
    let row: VolumeStatusRow?

    init(title: String, target: AnyObject?, action: Selector?, row: VolumeStatusRow) {
        self.row = row
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
    }

    required init?(coder: NSCoder) {
        self.row = nil
        super.init(coder: coder)
    }
}

private enum DashboardLayout {
    static let groupVerticalPadding: CGFloat = 20
    static let groupHeaderHeight: CGFloat = 20
    static let groupHeaderRowSpacing: CGFloat = 8
    static let driveGroupSpacing: CGFloat = 8
    static let emptyRowsHeight: CGFloat = 28
    static let volumeRowMinHeight: CGFloat = 60
    static let volumeRowSpacing: CGFloat = 6
    static let statusButtonWidth: CGFloat = 76
    static let openButtonWidth: CGFloat = 116
    static let ejectButtonWidth: CGFloat = 72
    static let detailsButtonWidth: CGFloat = 78

    static func documentHeight(for groups: [DriveGroup]) -> CGFloat {
        guard !groups.isEmpty else {
            return emptyRowsHeight
        }

        let groupsHeight = groups.reduce(CGFloat(0)) { total, group in
            total + driveGroupHeight(rowCount: group.rows.count)
        }
        return groupsHeight + (CGFloat(max(0, groups.count - 1)) * driveGroupSpacing)
    }

    static func driveGroupHeight(rowCount: Int) -> CGFloat {
        groupVerticalPadding
            + groupHeaderHeight
            + groupHeaderRowSpacing
            + (CGFloat(rowCount) * volumeRowMinHeight)
            + (CGFloat(max(0, rowCount - 1)) * volumeRowSpacing)
    }
}

private extension VolumeStatusColor {
    var nsColor: NSColor {
        switch self {
        case .green:
            return .systemGreen
        case .yellow:
            return .systemYellow
        case .red:
            return .systemRed
        case .gray:
            return .systemGray
        }
    }
}
