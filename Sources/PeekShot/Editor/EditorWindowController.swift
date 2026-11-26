import AppKit
import Combine
import SwiftUI

/// Routes ⌘ shortcuts to the editor unless the user is typing into a text annotation.
private final class EditorWindow: NSWindow {
    var commandHandler: ((NSEvent) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, !(firstResponder is NSTextView), commandHandler?(event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Keeps a document that is smaller than the scroll view centered.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        if rect.width > documentView.frame.width {
            rect.origin.x = (documentView.frame.width - rect.width) / 2
        }
        if rect.height > documentView.frame.height {
            rect.origin.y = (documentView.frame.height - rect.height) / 2
        }
        return rect
    }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var openEditors: [EditorWindowController] = []

    static func open(_ item: CaptureItem) {
        let controller = EditorWindowController(item: item)
        openEditors.append(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.canvas)
        controller.zoomToFit()
    }

    private let item: CaptureItem
    private let state = EditorState()
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var cancellables: Set<AnyCancellable> = []

    private static let toolbarHeight: CGFloat = 48
    private static let footerHeight: CGFloat = 46

    private init(item: CaptureItem) {
        self.item = item
        canvas = CanvasView(image: item.image, scale: item.scale, state: state)

        let visible = NSScreen.underMouse.visibleFrame
        let chrome = Self.toolbarHeight + Self.footerHeight
        let width = min(max(item.pointSize.width + 80, 920), visible.width * 0.9)
        let height = min(max(item.pointSize.height + 80 + chrome, 520), visible.height * 0.9)
        let window = EditorWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
        window.title = "PeekShot 标注"
        window.minSize = CGSize(width: 920, height: 420)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(CGPoint(x: visible.midX - width / 2, y: visible.midY - height / 2))
        super.init(window: window)
        window.delegate = self
        window.commandHandler = { [weak self] in self?.handleCommand($0) ?? false }

        buildLayout(in: window)
        bindState()
        canvas.onCanvasResized = { [weak self] in self?.zoomToFit() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildLayout(in window: NSWindow) {
        let toolbar = NSHostingView(rootView: EditorToolbar(state: state))
        let footer = NSHostingView(rootView: EditorFooter(
            state: state,
            onUndo: { [weak self] in self?.canvas.undo() },
            onRedo: { [weak self] in self?.canvas.redo() },
            onPin: { [weak self] in self?.finish { CaptureActions.pin($0) } },
            onSaveAs: { [weak self] in self?.saveAs() },
            onSave: { [weak self] in self?.finish { CaptureActions.save($0) } },
            onCopy: { [weak self] in self?.finish { CaptureActions.copy($0) } }))

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 8
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor

        let container = NSView()
        for view in [toolbar, scrollView, footer] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: Self.toolbarHeight),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Self.footerHeight),
        ])
        window.contentView = container
    }

    private func bindState() {
        Publishers.CombineLatest3(state.$color, state.$size, state.$filled)
            .dropFirst()
            .sink { [weak self] color, size, filled in
                self?.canvas.applyStyle(color: color, size: size, filled: filled)
            }
            .store(in: &cancellables)
        // @Published emits before the value is stored, so let the canvas read it on the next turn.
        state.$tool
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.canvas.toolChanged() }
            .store(in: &cancellables)
    }

    private func zoomToFit() {
        window?.layoutIfNeeded()
        let available = scrollView.frame.size
        let size = canvas.imagePointSize
        let fit = min(1, (available.width - 48) / size.width, (available.height - 48) / size.height)
        scrollView.magnification = max(fit, scrollView.minMagnification)
    }

    // MARK: Commands

    private func handleCommand(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return false }
        let shift = flags.contains(.shift)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z": shift ? canvas.redo() : canvas.undo()
        case "c": finish { CaptureActions.copy($0) }
        case "s": shift ? saveAs() : finish { CaptureActions.save($0) }
        case "w": window?.performClose(nil)
        case "0": zoomToFit()
        case "=", "+": scrollView.magnification *= 1.25
        case "-": scrollView.magnification /= 1.25
        default: return false
        }
        return true
    }

    /// Flattens the annotations into the item and stores it back into history.
    private func commit() {
        guard canvas.hasUnsavedChanges else { return }
        item.image = canvas.renderedImage()
        HistoryStore.shared.update(item)
        canvas.markSaved()
    }

    private func finish(_ action: (CaptureItem) -> Void) {
        commit()
        action(item)
        window?.close()
    }

    private func saveAs() {
        commit()
        CaptureActions.saveAs(item, relativeTo: window)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing keeps the edits: the history entry is updated instead of asking to save.
        commit()
        Self.openEditors.removeAll { $0 === self }
    }
}

// MARK: - SwiftUI bars

struct EditorToolbar: View {
    @ObservedObject var state: EditorState

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(ToolKind.allCases) { tool in
                    Button {
                        state.tool = tool
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 30, height: 28)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .fill(state.tool == tool ? Color.accentColor.opacity(0.28) : Color.clear))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(tool.title)（\(String(tool.shortcut).uppercased())）")
                }
            }
            Divider().frame(height: 22)
            HStack(spacing: 6) {
                ForEach(EditorState.palette.indices, id: \.self) { index in
                    let color = EditorState.palette[index]
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3)
                            .opacity(state.color == color ? 1 : 0))
                        .onTapGesture { state.color = color }
                }
                ColorPicker("", selection: Binding(
                    get: { Color(nsColor: state.color) },
                    set: { state.color = NSColor($0).usingColorSpace(.sRGB) ?? NSColor($0) }))
                    .labelsHidden()
                    .help("自定义颜色")
            }
            Divider().frame(height: 22)
            Image(systemName: "lineweight").foregroundStyle(.secondary)
            Slider(value: $state.size, in: 1...12)
                .frame(width: 90)
                .help("粗细 / 大小")
            Toggle(isOn: $state.filled) {
                Image(systemName: "square.fill")
            }
            .toggleStyle(.button)
            .help("填充矩形和椭圆")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }
}

struct EditorFooter: View {
    @ObservedObject var state: EditorState
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onPin: () -> Void
    let onSaveAs: () -> Void
    let onSave: () -> Void
    let onCopy: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!state.canUndo)
                .help("撤销（⌘Z）")
            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!state.canRedo)
                .help("重做（⇧⌘Z）")
            Spacer()
            Button("贴图", action: onPin)
            Button("另存为…", action: onSaveAs).help("⇧⌘S")
            Button("保存", action: onSave).help("保存到默认文件夹（⌘S）")
            Button("复制", action: onCopy)
                .buttonStyle(.borderedProminent)
                .help("复制并关闭（⌘C）")
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
    }
}
