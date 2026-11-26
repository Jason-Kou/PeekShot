import AppKit
import ServiceManagement
import SwiftUI

@MainActor
enum SettingsWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let created = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 520),
                                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
            created.title = "PeekShot 设置"
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
        TabView {
            GeneralSettings().tabItem { Label("通用", systemImage: "gearshape") }
            ShortcutSettings().tabItem { Label("快捷键", systemImage: "keyboard") }
        }
        .frame(width: 520, height: 520)
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
            Section("截图后") {
                Toggle("显示悬浮预览", isOn: $showQuickAccess)
                Toggle("复制到剪贴板", isOn: $copyAfterCapture)
                Toggle("保存到文件夹", isOn: $saveAfterCapture)
                Toggle("播放快门声", isOn: $playSound)
            }
            Section("保存") {
                LabeledContent("保存位置") {
                    HStack {
                        Text((saveDirectory as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("选择…", action: chooseDirectory)
                    }
                }
                Picker("图片格式", selection: $imageFormat) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
            }
            Section("截图") {
                Toggle("显示放大镜", isOn: $showMagnifier)
                Toggle("窗口截图带阴影", isOn: $windowShadow)
                Stepper("延时截图：\(timerSeconds) 秒", value: $timerSeconds, in: 1...30)
            }
            Section("悬浮预览与历史") {
                Picker("预览位置", selection: $overlayPosition) {
                    ForEach(OverlayPosition.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("自动关闭预览", selection: $overlayAutoClose) {
                    Text("不自动关闭").tag(0)
                    Text("5 秒").tag(5)
                    Text("10 秒").tag(10)
                    Text("30 秒").tag(30)
                }
                Picker("历史保留", selection: $historyDays) {
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                    Text("永久").tag(0)
                }
            }
            Section {
                Toggle("登录时启动", isOn: $launchAtLogin)
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
                Text("点击后按下新的组合键（需包含 ⌘、⌃ 或 ⌥）。按 Delete 清除，按 Esc 取消。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("选区内") {
                LabeledContent("切换区域 / 窗口模式", value: "空格")
                LabeledContent("拖动时移动选区", value: "按住空格")
                LabeledContent("正方形 / 从中心拉伸", value: "⇧ / ⌥")
                LabeledContent("取消", value: "Esc 或右键")
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
        title = Prefs.keyCombo(for: hotKeyAction)?.displayString ?? "未设置"
    }

    @objc private func toggleRecording() {
        monitor == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        title = "按下快捷键…"
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
