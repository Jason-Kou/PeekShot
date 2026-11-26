import AppKit
import SwiftUI

@MainActor
enum HistoryWindowController {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let created = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 880, height: 580),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
            created.title = "截图历史"
            created.isReleasedWhenClosed = false
            created.contentViewController = NSHostingController(rootView: HistoryView())
            created.setContentSize(CGSize(width: 880, height: 580))
            created.center()
            window = created
        }
        HistoryStore.shared.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct HistoryView: View {
    @ObservedObject private var store = HistoryStore.shared
    @State private var confirmingClear = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.entries.count) 张截图").foregroundStyle(.secondary)
                Spacer()
                Button("清空历史") { confirmingClear = true }
                    .disabled(store.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if store.entries.isEmpty {
                Spacer()
                Text("还没有截图").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 16)], spacing: 16) {
                        ForEach(store.entries) { entry in
                            HistoryCell(entry: entry, dateText: Self.dateFormatter.string(from: entry.date))
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .confirmationDialog("清空全部截图历史？", isPresented: $confirmingClear) {
            Button("清空", role: .destructive) { store.deleteAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 PeekShot 历史里的副本，已另存到其他位置的文件不受影响。")
        }
    }
}

private struct HistoryCell: View {
    let entry: HistoryEntry
    let dateText: String
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06))
                if let image = ThumbnailCache.shared.image(for: entry.url) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                }
            }
            .frame(height: 130)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isHovering ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: isHovering ? 2 : 1))
            Text(dateText).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2) { withItem(CaptureActions.edit) }
        .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
        .contextMenu {
            Button("复制") { withItem(CaptureActions.copy) }
            Button("保存") { withItem { CaptureActions.save($0) } }
            Button("标注") { withItem(CaptureActions.edit) }
            Button("贴图到屏幕") { withItem(CaptureActions.pin) }
            Button("在访达中显示") { withItem(CaptureActions.revealInFinder) }
            Divider()
            Button("删除", role: .destructive) { HistoryStore.shared.delete(entry) }
        }
        .help("双击打开标注，拖拽可导出文件")
    }

    private func withItem(_ action: (CaptureItem) -> Void) {
        guard let item = ImageCodec.load(entry.url) else { return }
        action(item)
    }
}
