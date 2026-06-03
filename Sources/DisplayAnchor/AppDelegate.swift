import AppKit
#if canImport(DisplayAnchorCore)
import DisplayAnchorCore
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = DisplayAnchorController()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let headerView = MenuHeaderView()
    private let permissionMenuItem = NSMenuItem()
    private let snapshotMenuItem = NSMenuItem()
    private let restoreMenuItem = NSMenuItem()
    private let pauseMenuItem = NSMenuItem()
    private let launchAtLoginMenuItem = NSMenuItem()
    private let quitMenuItem = NSMenuItem(title: "Quit Display Anchor", action: #selector(quit), keyEquivalent: "q")

    // Every action row uses the same custom view, so icons, text, and spacing line up by
    // construction rather than by matching the system's private NSMenuItem metrics.
    private let permissionRow = MenuRowView()
    private let snapshotRow = MenuRowView()
    private let restoreRow = MenuRowView()
    private let pauseRow = MenuRowView()
    private let launchRow = MenuRowView()
    private let quitRow = MenuRowView()
    private var allRows: [MenuRowView] { [permissionRow, snapshotRow, restoreRow, pauseRow, launchRow, quitRow] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()

        controller.onStatusChange = { [weak self] status in
            self?.headerView.update(statusText: status.menuText, color: status.indicatorColor)
            self?.updateMenuState()
        }

        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.refreshPermissionState()
        updateMenuState()
        allRows.forEach { $0.resetHighlight() }
    }

    private func configureStatusItem() {
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Display Anchor")
            button.imagePosition = .imageOnly
        }
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        let headerItem = NSMenuItem()
        headerItem.view = headerView
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        permissionRow.onClick = { [weak self] in self?.openAccessibilitySettings() }
        permissionRow.configure(title: "Open Accessibility Settings", iconSymbol: "exclamationmark.shield")
        permissionMenuItem.view = permissionRow
        menu.addItem(permissionMenuItem)
        menu.addItem(NSMenuItem.separator())

        snapshotRow.onClick = { [weak self] in self?.snapshotNow() }
        restoreRow.onClick = { [weak self] in self?.restoreLastSnapshot() }
        pauseRow.onClick = { [weak self] in self?.togglePause() }
        snapshotMenuItem.view = snapshotRow
        restoreMenuItem.view = restoreRow
        pauseMenuItem.view = pauseRow
        menu.addItem(snapshotMenuItem)
        menu.addItem(restoreMenuItem)
        menu.addItem(pauseMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Launch at Login relies on SMAppService (macOS 13+); omit it on older systems.
        if #available(macOS 13.0, *) {
            launchRow.onClick = { [weak self] in self?.toggleLaunchAtLogin() }
            launchAtLoginMenuItem.view = launchRow
            menu.addItem(launchAtLoginMenuItem)
            menu.addItem(NSMenuItem.separator())
        }

        quitRow.onClick = { [weak self] in self?.quit() }
        quitRow.configure(title: "Quit Display Anchor", iconSymbol: "xmark.circle", accessory: .shortcut("⌘Q"))
        quitMenuItem.target = self
        quitMenuItem.view = quitRow
        menu.addItem(quitMenuItem)
    }

    private func updateMenuState() {
        let hasPermission = AccessibilityPermission.isTrusted
        permissionMenuItem.isHidden = hasPermission

        let paused = controller.isPaused()
        snapshotRow.configure(title: "Snapshot Now", iconSymbol: "camera.viewfinder", isEnabled: hasPermission && !paused)
        restoreRow.configure(title: "Restore Last Snapshot", iconSymbol: "arrow.counterclockwise", isEnabled: hasPermission)
        pauseRow.configure(title: paused ? "Resume Automatic Restore" : "Pause Automatic Restore",
                           iconSymbol: paused ? "play.circle" : "pause.circle",
                           isEnabled: hasPermission)

        if #available(macOS 13.0, *) {
            switch LaunchAtLogin.status {
            case .enabled:
                launchRow.configure(title: "Launch at Login", iconSymbol: "power", accessory: .checkmark(true))
            case .notRegistered, .notFound:
                launchRow.configure(title: "Launch at Login", iconSymbol: "power", accessory: .checkmark(false))
            case .requiresApproval:
                launchRow.configure(title: "Approve Launch at Login…", iconSymbol: "power", accessory: .checkmark(false))
            @unknown default:
                launchRow.configure(title: "Launch at Login Unavailable", iconSymbol: "power", accessory: .checkmark(false), isEnabled: false)
            }
        }
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func snapshotNow() {
        controller.snapshotNow()
    }

    @objc private func restoreLastSnapshot() {
        controller.restoreLastSnapshot()
    }

    @objc private func togglePause() {
        controller.setPaused(!controller.isPaused())
    }

    @objc private func toggleLaunchAtLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            switch LaunchAtLogin.status {
            case .enabled:
                try LaunchAtLogin.disable()
            case .notRegistered:
                try LaunchAtLogin.enable()
                if LaunchAtLogin.status == .requiresApproval {
                    LaunchAtLogin.openSystemSettings()
                }
            case .requiresApproval:
                LaunchAtLogin.openSystemSettings()
            case .notFound:
                try LaunchAtLogin.enable()
                if LaunchAtLogin.status == .requiresApproval {
                    LaunchAtLogin.openSystemSettings()
                }
            @unknown default:
                NSSound.beep()
            }
        } catch {
            headerView.update(statusText: "Error: \(error.localizedDescription)", color: .systemRed)
        }

        updateMenuState()
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }
}

/// Custom header shown at the top of the menu: app glyph, name, and a colored status line.
@MainActor
final class MenuHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Display Anchor")
    private let anchorView = NSImageView()
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Starting")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 260, height: 52))
        autoresizingMask = [.width]
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        // Anchor the header type scale to the system menu font the rows below use,
        // so the custom view and the standard NSMenuItem rows read as one hierarchy.
        let menuSize = NSFont.menuFont(ofSize: 0).pointSize

        // Title sits one step above the row text in size and weight — the top of the hierarchy.
        let titleFont = NSFont.systemFont(ofSize: menuSize + 1, weight: .semibold)
        let titleX: CGFloat = 16
        let titleY: CGFloat = 26
        let titleH: CGFloat = 20
        titleLabel.font = titleFont
        titleLabel.textColor = .labelColor

        // The "D" has a left side bearing, so its ink starts slightly right of the frame origin.
        // Use the true ink bounds (not optical bounds) so the status dot's left edge can sit exactly
        // under the visible left edge of the letter.
        let titleAttr = NSAttributedString(string: titleLabel.stringValue, attributes: [.font: titleFont])
        let titleLeftBearing = max(0, CTLineGetImageBounds(
            CTLineCreateWithAttributedString(titleAttr), nil).origin.x)
        // Pad the measured width slightly: NSTextField needs a touch more than the exact glyph
        // run or it clips the trailing character.
        let titleWidth = ceil((titleLabel.stringValue as NSString).size(withAttributes: [.font: titleFont]).width) + 4
        titleLabel.frame = NSRect(x: titleX, y: titleY, width: titleWidth, height: titleH)
        addSubview(titleLabel)

        // Anchor glyph sits just after the name, sized to the title's cap height and centered on the
        // text's optical midline (same frame-center/cap-center midpoint used for the status dot).
        let anchorSize = ceil(titleFont.capHeight * 1.6)
        let titleFrameCenterY = titleY + titleH / 2
        let titleCapCenterY = titleFrameCenterY + (titleFont.capHeight / 2 + titleFont.descender / 2)
        let anchorCenterY = (titleFrameCenterY + titleCapCenterY) / 2
        anchorView.image = AnchorAsset.image
        anchorView.imageScaling = .scaleProportionallyUpOrDown
        anchorView.frame = NSRect(x: titleLabel.frame.maxX + 6,
                                  y: anchorCenterY - anchorSize / 2,
                                  width: anchorSize, height: anchorSize)
        addSubview(anchorView)

        // Status row: quiet secondary text with a colored state dot. The dot's left edge lines up
        // with the title's first letter above, and it is vertically centered on the label.
        let leftMargin = titleX + titleLeftBearing + 2
        let dotSize: CGFloat = 8
        let dotGap: CGFloat = 6
        let labelY: CGFloat = 7
        let labelH: CGFloat = 16

        let statusFont = NSFont.systemFont(ofSize: menuSize - 2, weight: .regular)
        statusLabel.font = statusFont
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: leftMargin + dotSize + dotGap, y: labelY, width: 195, height: labelH)
        addSubview(statusLabel)

        // Center the dot on the text's optical midline. The frame center sits at the text's bottom
        // and the cap-height center at its top, so the visual middle is the midpoint of the two.
        let frameCenterY = labelY + labelH / 2
        let capCenterY = frameCenterY + (statusFont.capHeight / 2 + statusFont.descender / 2)
        let textCenterY = (frameCenterY + capCenterY) / 2

        // Draw the dot as a template circle that fills its frame exactly, so the frame's left edge
        // is the circle's left edge (unlike the SF "circle.fill" symbol, which has its own padding).
        let dotImage = NSImage(size: NSSize(width: dotSize, height: dotSize), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
        dotImage.isTemplate = true
        statusDot.image = dotImage
        statusDot.imageScaling = .scaleNone
        statusDot.contentTintColor = .systemGreen
        statusDot.frame = NSRect(x: leftMargin, y: textCenterY - dotSize / 2, width: dotSize, height: dotSize)
        addSubview(statusDot)
    }

    func update(statusText: String, color: NSColor) {
        statusLabel.stringValue = statusText
        statusDot.contentTintColor = color
    }
}

/// A single fully custom menu row: leading icon, title, and an optional trailing accessory
/// (a checkmark for toggles, or a key-equivalent string). Every action row uses this same view,
/// so icons, text, and spacing line up by construction instead of having to match the private
/// metrics of the system-drawn NSMenuItem rows.
@MainActor
final class MenuRowView: NSView {
    enum Accessory: Equatable {
        case none
        case checkmark(Bool)
        case shortcut(String)
    }

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let checkView = NSImageView()
    private let shortcutLabel = NSTextField(labelWithString: "")

    var onClick: (() -> Void)?
    private var rowEnabled = true
    private var hovering = false
    private var accessory: Accessory = .none

    private let rowWidth: CGFloat = 260
    private let rowHeight: CGFloat = 22
    private let iconLeading: CGFloat = 16     // matches the header's left margin
    private let iconColumn: CGFloat = 16      // fixed glyph box: every title starts at the same x
    private let iconTitleGap: CGFloat = 8
    private let trailingInset: CGFloat = 14
    private let accessoryGap: CGFloat = 6
    private let checkSize: CGFloat = 13
    private let highlightInset: CGFloat = 5

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
        autoresizingMask = [.width]
        // Scale down only (never up) so glyphs match the visual size of standard menu rows.
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignLeft
        checkView.imageScaling = .scaleProportionallyDown
        checkView.imageAlignment = .alignRight
        titleLabel.font = .menuFont(ofSize: 0)
        shortcutLabel.font = .menuFont(ofSize: 0)
        addSubview(iconView)
        addSubview(titleLabel)
        addSubview(checkView)
        addSubview(shortcutLabel)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, iconSymbol: String, accessory: Accessory = .none, isEnabled: Bool = true) {
        self.accessory = accessory
        rowEnabled = isEnabled
        titleLabel.stringValue = title
        iconView.image = Self.templateImage(iconSymbol)

        switch accessory {
        case .none:
            checkView.image = nil
            shortcutLabel.stringValue = ""
        case .checkmark(let on):
            checkView.image = on ? Self.templateImage("checkmark") : nil
            shortcutLabel.stringValue = ""
        case .shortcut(let text):
            checkView.image = nil
            shortcutLabel.stringValue = text
        }
        applyColors()
        needsLayout = true
        needsDisplay = true
    }

    private static func templateImage(_ symbol: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private var highlighted: Bool { rowEnabled && hovering }

    private func applyColors() {
        let primary: NSColor = !rowEnabled ? .disabledControlTextColor
            : (highlighted ? .selectedMenuItemTextColor : .labelColor)
        titleLabel.textColor = primary
        iconView.contentTintColor = primary
        checkView.contentTintColor = primary
        shortcutLabel.textColor = !rowEnabled ? .disabledControlTextColor
            : (highlighted ? .selectedMenuItemTextColor : .secondaryLabelColor)
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        // Center each glyph inside a fixed-width column and clamp oversized symbols (e.g. "power")
        // down to it. This keeps every icon at one optical size and lets all titles start at the
        // same x, instead of each title being shifted by its own glyph's native width.
        let nativeW = iconView.image?.size.width ?? iconColumn
        let nativeH = iconView.image?.size.height ?? iconColumn
        let scale = min(1, min(iconColumn / nativeW, iconColumn / nativeH))
        let imageW = nativeW * scale
        let imageH = nativeH * scale
        iconView.frame = NSRect(x: iconLeading + (iconColumn - imageW) / 2,
                                y: (h - imageH) / 2, width: imageW, height: imageH)

        var trailingReserve = trailingInset
        switch accessory {
        case .none:
            break
        case .checkmark:
            checkView.frame = NSRect(x: bounds.width - trailingInset - checkSize, y: (h - checkSize) / 2, width: checkSize, height: checkSize)
            trailingReserve = trailingInset + checkSize + accessoryGap
        case .shortcut:
            shortcutLabel.sizeToFit()
            let w = shortcutLabel.frame.width
            shortcutLabel.frame = NSRect(x: bounds.width - trailingInset - w, y: (h - shortcutLabel.frame.height) / 2, width: w, height: shortcutLabel.frame.height)
            trailingReserve = trailingInset + w + accessoryGap
        }

        let titleX = iconLeading + iconColumn + iconTitleGap
        titleLabel.sizeToFit()
        let titleH = titleLabel.frame.height
        let titleW = max(0, bounds.width - titleX - trailingReserve)
        titleLabel.frame = NSRect(x: titleX, y: (h - titleH) / 2, width: titleW, height: titleH)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard highlighted else { return }
        let rect = bounds.insetBy(dx: highlightInset, dy: 1)
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovering = false; refresh() }

    /// Clears any stale hover state, e.g. when the menu closed while the cursor was over this row.
    func resetHighlight() {
        hovering = false
        refresh()
    }

    private func refresh() {
        applyColors()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard rowEnabled else { return }
        enclosingMenuItem?.menu?.cancelTracking()
        onClick?()
    }
}
