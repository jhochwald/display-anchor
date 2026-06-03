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
    private let permissionMenuItem = NSMenuItem(title: "Open Accessibility Settings", action: #selector(openAccessibilitySettings), keyEquivalent: "")
    private let snapshotMenuItem = NSMenuItem(title: "Snapshot Now", action: #selector(snapshotNow), keyEquivalent: "")
    private let restoreMenuItem = NSMenuItem(title: "Restore Last Snapshot", action: #selector(restoreLastSnapshot), keyEquivalent: "")
    private let pauseMenuItem = NSMenuItem(title: "Pause Automatic Restore", action: #selector(togglePause), keyEquivalent: "")
    private let launchAtLoginMenuItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

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

        permissionMenuItem.target = self
        permissionMenuItem.image = Self.menuIcon("exclamationmark.shield")
        menu.addItem(permissionMenuItem)
        menu.addItem(NSMenuItem.separator())

        snapshotMenuItem.target = self
        snapshotMenuItem.image = Self.menuIcon("camera.viewfinder")
        restoreMenuItem.target = self
        restoreMenuItem.image = Self.menuIcon("arrow.counterclockwise")
        pauseMenuItem.target = self
        pauseMenuItem.image = Self.menuIcon("pause.circle")
        menu.addItem(snapshotMenuItem)
        menu.addItem(restoreMenuItem)
        menu.addItem(pauseMenuItem)
        menu.addItem(NSMenuItem.separator())

        // Launch at Login relies on SMAppService (macOS 13+); omit it on older systems.
        if #available(macOS 13.0, *) {
            launchAtLoginMenuItem.target = self
            launchAtLoginMenuItem.image = Self.menuIcon("power")
            menu.addItem(launchAtLoginMenuItem)
            menu.addItem(NSMenuItem.separator())
        }

        let quitItem = NSMenuItem(title: "Quit Display Anchor", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        quitItem.image = Self.menuIcon("xmark.circle")
        menu.addItem(quitItem)
    }

    private static func menuIcon(_ symbolName: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    private func updateMenuState() {
        let hasPermission = AccessibilityPermission.isTrusted
        permissionMenuItem.isHidden = hasPermission
        snapshotMenuItem.isEnabled = hasPermission && !controller.isPaused()
        restoreMenuItem.isEnabled = hasPermission
        pauseMenuItem.isEnabled = hasPermission

        let paused = controller.isPaused()
        pauseMenuItem.title = paused ? "Resume Automatic Restore" : "Pause Automatic Restore"
        pauseMenuItem.image = Self.menuIcon(paused ? "play.circle" : "pause.circle")

        if #available(macOS 13.0, *) {
            switch LaunchAtLogin.status {
            case .enabled:
                launchAtLoginMenuItem.title = "Launch at Login"
                launchAtLoginMenuItem.state = .on
                launchAtLoginMenuItem.isEnabled = true
            case .notRegistered:
                launchAtLoginMenuItem.title = "Launch at Login"
                launchAtLoginMenuItem.state = .off
                launchAtLoginMenuItem.isEnabled = true
            case .requiresApproval:
                launchAtLoginMenuItem.title = "Approve Launch at Login..."
                launchAtLoginMenuItem.state = .off
                launchAtLoginMenuItem.isEnabled = true
            case .notFound:
                launchAtLoginMenuItem.title = "Launch at Login"
                launchAtLoginMenuItem.state = .off
                launchAtLoginMenuItem.isEnabled = true
            @unknown default:
                launchAtLoginMenuItem.title = "Launch at Login Unavailable"
                launchAtLoginMenuItem.state = .off
                launchAtLoginMenuItem.isEnabled = false
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
    private let titleLabel = NSTextField(labelWithString: "Display Anchor ⚓️")
    private let statusDot = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "Starting")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
        setupSubviews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubviews() {
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 16, y: 27, width: 210, height: 18)
        addSubview(titleLabel)

        // Status row spans the full width for maximum room.
        let dotConfig = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        statusDot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(dotConfig)
        statusDot.image?.isTemplate = true
        statusDot.contentTintColor = .systemGreen
        statusDot.frame = NSRect(x: 17, y: 10, width: 9, height: 9)
        addSubview(statusDot)

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 30, y: 7, width: 196, height: 15)
        addSubview(statusLabel)
    }

    func update(statusText: String, color: NSColor) {
        statusLabel.stringValue = statusText
        statusDot.contentTintColor = color
    }
}
