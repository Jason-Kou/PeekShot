import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let created = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 566),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "PeekShot Settings"
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: SettingsView())
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            TabView {
                GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
                ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "keyboard") }
            }
            Divider()
            // The same entries as the menu bar icon, for when that icon is not reachable.
            HStack {
                Button("Capture History") { HistoryWindowController.show() }
                Spacer()
                Button("Quit PeekShot") { NSApp.terminate(nil) }
            }
            .padding(.horizontal, 16)
            .frame(height: 46)
        }
        .frame(width: 520, height: 566)
    }
}

private struct GeneralSettings: View {
    @AppStorage(PrefKey.playSound) private var playSound = true
    @AppStorage(PrefKey.showQuickAccess) private var showQuickAccess = true
    @AppStorage(PrefKey.copyAfterCapture) private var copyAfterCapture = false
    @AppStorage(PrefKey.saveAfterCapture) private var saveAfterCapture = false
    @AppStorage(PrefKey.saveDirectory) private var saveDirectory = Prefs.saveDirectory.path
    @AppStorage(PrefKey.imageFormat) private var imageFormat = ImageFormat.png.rawValue
    @AppStorage(PrefKey.overlayPosition) private var overlayPosition = OverlayPosition.left.rawValue
    @AppStorage(PrefKey.overlayAutoClose) private var overlayAutoClose = 0
    @AppStorage(PrefKey.historyDays) private var historyDays = 30
    @AppStorage(PrefKey.windowShadow) private var windowShadow = true
    @AppStorage(PrefKey.showMagnifier) private var showMagnifier = true
    @AppStorage(PrefKey.timerSeconds) private var timerSeconds = 5
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("After Capture") {
                Toggle("Show Quick Access overlay", isOn: $showQuickAccess)
                Toggle("Copy to clipboard", isOn: $copyAfterCapture)
                Toggle("Save to folder", isOn: $saveAfterCapture)
                Toggle("Play shutter sound", isOn: $playSound)
            }
            Section("Saving") {
                LabeledContent("Save location") {
                    HStack {
                        Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseDirectory)
                    }
                }
                Picker("Image format", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("Capture") {
                Toggle("Show magnifier", isOn: $showMagnifier)
                Toggle("Add shadow to window captures", isOn: $windowShadow)
                Stepper("Self-timer: \(timerSeconds) s", value: $timerSeconds, in: 1...30)
            }
            Section("Quick Access & History") {
                Picker("Overlay position", selection: $overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Auto-close overlay", selection: $overlayAutoClose) {
                    Text("Never").tag(0)
                    Text("After 5 seconds").tag(5)
                    Text("After 10 seconds").tag(10)
                    Text("After 30 seconds").tag(30)
                }
                Picker("Keep history for", selection: $historyDays) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("Forever").tag(0)
                }
            }
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: saveDirectory)
        if panel.runModal() == .OK, let url = panel.url {
            saveDirectory = url.path
        }
    }
}

private struct ShortcutSettings: View {
    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        ShortcutRecorder(action: action).frame(width: 150, height: 24)
                    }
                }
            } footer: {
                Text("Click a shortcut, then press the new combination (it must include ⌘, ⌃ or ⌥). Press Delete to clear it, Esc to cancel.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("While Selecting") {
                LabeledContent("Switch between area and window", value: "Space")
                LabeledContent("Move the selection while dragging", value: "Hold Space")
                LabeledContent("Square / resize from center", value: "⇧ / ⌥")
                LabeledContent("Cancel", value: "Esc or right-click")
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    let action: HotKeyAction

    func makeNSView(context: Context) -> ShortcutRecorderButton { ShortcutRecorderButton(action: action) }
    func updateNSView(_ nsView: ShortcutRecorderButton, context: Context) {}
}

final class ShortcutRecorderButton: NSButton {
    private let hotKeyAction: HotKeyAction
    private var monitor: Any?

    init(action: HotKeyAction) {
        hotKeyAction = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        target = self
        self.action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func refreshTitle() {
        title = Prefs.keyCombo(for: hotKeyAction)?.displayString ?? "Not Set"
    }

    @objc private func toggleRecording() {
        monitor == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        title = "Press shortcut…"
        // Global shortcuts would swallow the keys being recorded.
        HotKeyCenter.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53: // escape cancels
                break
            case 51, 117: // delete clears
                Prefs.setKeyCombo(nil, for: self.hotKeyAction)
            default:
                guard let combo = KeyCombo.from(event: event) else {
                    NSSound.beep()
                    return nil
                }
                Prefs.setKeyCombo(combo, for: self.hotKeyAction)
            }
            self.stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        HotKeyCenter.shared.reload()
        refreshTitle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, monitor != nil { stopRecording() }
    }
}
