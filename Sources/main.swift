import AppKit
import ServiceManagement

let pmsetPath = "/usr/bin/pmset"
let sudoersPath = "/etc/sudoers.d/slop-caffeinate"

func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

enum Mode {
    case awake, asleep

    /// `asleep` puts the Mac back to sleeping after 5 idle minutes on battery.
    var pmsetArgs: [[String]] {
        switch self {
        case .awake: return [["-b", "sleep", "0"], ["-b", "disablesleep", "1"]]
        case .asleep: return [["-b", "sleep", "5"], ["-b", "disablesleep", "0"]]
        }
    }

    var shellCommand: String {
        pmsetArgs.map { ([pmsetPath] + $0).joined(separator: " ") }.joined(separator: " && ")
    }

    static let allCommands = [Mode.awake, .asleep].flatMap { mode in
        mode.pmsetArgs.map { ([pmsetPath] + $0).joined(separator: " ") }
    }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return (-1, error.localizedDescription) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// `SleepDisabled` from `pmset -g` is what keeps the Mac running with the lid closed.
func readSleepDisabled() -> Bool? {
    let output = run(pmsetPath, ["-g"]).output
    for line in output.split(separator: "\n") {
        let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        if parts.count >= 2, parts[0] == "SleepDisabled" {
            return parts[1] == "1"
        }
    }
    return nil
}

func sudoRun(_ mode: Mode) -> Bool {
    mode.pmsetArgs.allSatisfy { run("/usr/bin/sudo", ["-n", pmsetPath] + $0).status == 0 }
}

func sudoAllowed() -> Bool {
    run("/usr/bin/sudo", ["-n", "-l", pmsetPath] + Mode.awake.pmsetArgs[0]).status == 0
}

enum AdminResult { case ok, cancelled, failed(String) }

func adminRun(_ shell: String) -> AdminResult {
    let escaped = shell
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
    var error: NSDictionary?
    NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?
        .executeAndReturnError(&error)
    guard let error else { return .ok }
    if (error[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
    return .failed(error[NSAppleScript.errorMessage] as? String ?? "\(error)")
}

func installSudoersCommand() -> String {
    let rule = "\(NSUserName()) ALL=(root) NOPASSWD: " + Mode.allCommands.joined(separator: ", ")
    return [
        "t=$(/usr/bin/mktemp) || exit 1",
        "printf '%s\\n' '\(rule)' > \"$t\"",
        "if /usr/sbin/visudo -cf \"$t\" >/dev/null; then /usr/bin/install -m 0440 -o root -g wheel \"$t\" \(sudoersPath); r=$?; else r=1; fi",
        "rm -f \"$t\"",
        "[ $r -eq 0 ] || exit $r",
    ].joined(separator: "; ")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let toggle = NSSwitch()
    private let toggleRow = NSStackView()
    private let stateItem = NSMenuItem()
    private let loginItem = NSMenuItem(title: L("Launch at Login"), action: #selector(toggleLogin), keyEquivalent: "")
    private var timer: Timer?
    private var previousApp: NSRunningApplication?

    func applicationDidFinishLaunching(_ notification: Notification) {
        toggle.target = self
        toggle.action = #selector(switchChanged)

        let label = NSTextField(labelWithString: L("Stay Awake with Lid Closed"))
        label.font = .menuFont(ofSize: 0)
        toggle.controlSize = .small
        // The right inset lines the switch up with the key equivalents column.
        // The left one is set in refresh(), since it depends on the checkmark column.
        [label, NSView(), toggle].forEach(toggleRow.addArrangedSubview)
        toggleRow.orientation = .horizontal
        toggleRow.frame = NSRect(x: 0, y: 0, width: 320, height: 30)
        toggleRow.autoresizingMask = .width
        let toggleItem = NSMenuItem()
        toggleItem.view = toggleRow

        stateItem.isEnabled = false
        loginItem.target = self

        menu.delegate = self
        menu.addItem(toggleItem)
        menu.addItem(stateItem)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        refresh()
        // pmset can be changed from the terminal behind our back, so keep polling.
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Controls in an inactive app draw gray, so the switch only gets the accent color
        // while we're active. Hand focus back to whoever had it once the menu closes.
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost == .current ? nil : frontmost
        NSApp.activate(ignoringOtherApps: true)
        refresh()
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let previousApp else { return }
        NSApp.yieldActivation(to: previousApp)
        previousApp.activate()
        self.previousApp = nil
    }

    private func refresh() {
        let disabled = readSleepDisabled()
        let awake = disabled == true

        toggle.state = awake ? .on : .off
        stateItem.title = switch disabled {
        case true: L("Sleep is off, safe to close the lid")
        case false: L("Normal mode, the Mac sleeps when closed")
        default: L("Couldn't read pmset")
        }

        if let button = statusItem.button {
            let symbol = awake ? "cup.and.saucer.fill" : "moon.zzz"
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: awake ? L("Staying awake") : L("Normal sleep"))
            image?.isTemplate = true
            button.image = image
            button.toolTip = awake ? L("SlopCaffeinate: sleep is off") : L("SlopCaffeinate: normal mode")
        }

        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        // macOS drops the checkmark column when no item is checked, which moves the item titles.
        let titleInset: CGFloat = loginItem.state == .on ? 30 : 16
        toggleRow.edgeInsets = NSEdgeInsets(top: 0, left: titleInset, bottom: 0, right: 18)
    }

    @objc private func switchChanged() {
        let mode: Mode = toggle.state == .on ? .awake : .asleep
        if sudoRun(mode) {
            refresh()
            return
        }
        // The password dialog can't be shown over an open menu.
        menu.cancelTracking()
        DispatchQueue.main.async { self.applyWithAdmin(mode) }
    }

    private func applyWithAdmin(_ mode: Mode) {
        defer { refresh() }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Administrator Access Required")
        alert.informativeText = String(
            format: L("sudoers.explanation"),
            Mode.allCommands.joined(separator: "\n"),
            sudoersPath
        )
        alert.addButton(withTitle: L("Allow Without Password"))
        alert.addButton(withTitle: L("Just This Once"))
        alert.addButton(withTitle: L("Cancel"))

        let result: AdminResult
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            result = adminRun(installSudoersCommand() + "; " + mode.shellCommand)
            if case .ok = result, !sudoAllowed() {
                showError(L("sudoers.notIncluded"))
            }
        case .alertSecondButtonReturn:
            result = adminRun(mode.shellCommand)
        default:
            return
        }
        if case .failed(let message) = result { showError(message) }
    }

    @objc private func toggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            }
        } catch {
            showError(error.localizedDescription)
        }
        refresh()
    }

    private func showError(_ message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "SlopCaffeinate"
        alert.informativeText = message
        alert.runModal()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
