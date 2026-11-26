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
            created.title = "Capture History"
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
                Text(store.entries.count == 1 ? "1 capture" : "\(store.entries.count) captures").foregroundStyle(.secondary)
                Spacer()
                Button("Clear History") { confirmingClear = true }
                    .disabled(store.entries.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            Divider()
            if store.entries.isEmpty {
                Spacer()
                Text("No captures yet").foregroundStyle(.secondary)
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
        .confirmationDialog("Clear the entire capture history?", isPresented: $confirmingClear) {
            Button("Clear", role: .destructive) { store.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only the copies in PeekShot's history are deleted. Files you saved elsewhere are not affected.")
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
            Button("Copy") { withItem(CaptureActions.copy) }
            Button("Save") { withItem { CaptureActions.save($0) } }
            Button("Annotate") { withItem(CaptureActions.edit) }
            Button("Pin to Screen") { withItem(CaptureActions.pin) }
            Button("Show in Finder") { withItem(CaptureActions.revealInFinder) }
            Divider()
            Button("Delete", role: .destructive) { HistoryStore.shared.delete(entry) }
        }
        .help("Double-click to annotate, drag to export the file")
    }

    private func withItem(_ action: (CaptureItem) -> Void) {
        guard let item = ImageCodec.load(entry.url) else { return }
        action(item)
    }
}
