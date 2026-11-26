import AppKit

/// Toolbar state shared between the SwiftUI controls and the canvas.
final class EditorState: ObservableObject {
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1), // orange
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.20, green: 0.78, blue: 0.35, alpha: 1), // green
        NSColor(srgbRed: 0.00, green: 0.48, blue: 1.00, alpha: 1), // blue
        NSColor(srgbRed: 0.69, green: 0.32, blue: 0.87, alpha: 1), // purple
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1),
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
    ]

    @Published var tool: ToolKind = .arrow
    @Published var color: NSColor = EditorState.palette[0]
    @Published var size: CGFloat = 4
    @Published var filled = false
    @Published var canUndo = false
    @Published var canRedo = false
}

/// The drawing surface. Its coordinate space is image points with a top-left origin;
/// the enclosing scroll view provides zooming.
final class CanvasView: NSView, NSTextViewDelegate {
    let state: EditorState
    let scale: CGFloat
    private(set) var baseImage: CGImage
    private(set) var annotations: [Annotation] = []
    /// Called after a crop or undo changed the canvas size.
    var onCanvasResized: (() -> Void)?

    private struct Snapshot {
        let image: CGImage
        let annotations: [Annotation]
    }

    private enum Drag {
        case none
        case creating
        case moving(last: CGPoint)
        case resizingSegment(isStart: Bool)
        case resizingBox(fixed: CGPoint)
        case cropping(origin: CGPoint)
    }

    private let renderer = AnnotationRenderer()
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var savedUndoDepth = 0
    private var drag = Drag.none
    private var dragDidPushUndo = false
    private var draft: Annotation?
    private var cropDraft: CGRect?
    private var selectedID: UUID?
    private var textView: NSTextView?
    private var editingID: UUID?
    /// True while the canvas itself writes selection values into `state`.
    private var isSyncingState = false
    private var lastStyleUndo: (id: UUID, time: Date)?

    init(image: CGImage, scale: CGFloat, state: EditorState) {
        baseImage = image
        self.scale = scale
        self.state = state
        super.init(frame: .zero)
        setFrameSize(imagePointSize)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var imagePointSize: CGSize {
        CGSize(width: CGFloat(baseImage.width) / scale, height: CGFloat(baseImage.height) / scale)
    }

    /// Whether there are edits that were not yet written back through `markSaved`.
    var hasUnsavedChanges: Bool { undoStack.count != savedUndoDepth || textView != nil }

    func markSaved() { savedUndoDepth = undoStack.count }

    func renderedImage() -> CGImage {
        commitText()
        return renderer.flatten(annotations, base: baseImage, scale: scale) ?? baseImage
    }

    // MARK: Undo

    private func pushUndo() {
        undoStack.append(Snapshot(image: baseImage, annotations: annotations))
        redoStack.removeAll()
        syncUndoState()
    }

    func undo() {
        commitText()
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(Snapshot(image: baseImage, annotations: annotations))
        restore(snapshot)
    }

    func redo() {
        commitText()
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(Snapshot(image: baseImage, annotations: annotations))
        restore(snapshot)
    }

    private func restore(_ snapshot: Snapshot) {
        let resized = snapshot.image.width != baseImage.width || snapshot.image.height != baseImage.height
        baseImage = snapshot.image
        annotations = snapshot.annotations
        selectedID = nil
        lastStyleUndo = nil
        if resized {
            setFrameSize(imagePointSize)
            onCanvasResized?()
        }
        syncUndoState()
        needsDisplay = true
    }

    private func syncUndoState() {
        state.canUndo = !undoStack.isEmpty
        state.canRedo = !redoStack.isEmpty
    }

    // MARK: Selection and style

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return annotations.firstIndex { $0.id == selectedID }
    }

    private func select(_ id: UUID?) {
        selectedID = id
        if let index = selectedIndex {
            let annotation = annotations[index]
            isSyncingState = true
            state.color = annotation.color
            state.size = annotation.size
            state.filled = annotation.filled
            isSyncingState = false
        }
        needsDisplay = true
    }

    /// Applies toolbar style changes to the text being typed or to the selected object.
    func applyStyle(color: NSColor, size: CGFloat, filled: Bool) {
        guard !isSyncingState else { return }
        if let textView {
            textView.textColor = color
            textView.insertionPointColor = color
            textView.font = Annotation(kind: .text, at: .zero, color: color, size: size).font
            textView.sizeToFit()
            return
        }
        guard let index = selectedIndex else { return }
        let current = annotations[index]
        guard current.color != color || current.size != size || current.filled != filled else { return }
        // Collapse a slider drag into one undo step.
        if let last = lastStyleUndo, last.id == current.id, Date().timeIntervalSince(last.time) < 1 {
            lastStyleUndo = (current.id, Date())
        } else {
            pushUndo()
            lastStyleUndo = (current.id, Date())
        }
        annotations[index].color = color
        annotations[index].size = size
        annotations[index].filled = filled
        needsDisplay = true
    }

    func toolChanged() {
        commitText()
        cropDraft = nil
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    func deleteSelection() {
        guard let index = selectedIndex else { return }
        pushUndo()
        annotations.remove(at: index)
        selectedID = nil
        needsDisplay = true
    }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: state.tool == .select ? .arrow : .crosshair)
    }

    // MARK: Mouse

    private var handleRadius: CGFloat { 5 / (enclosingScrollView?.magnification ?? 1) }

    private func handleIndex(of annotation: Annotation, at point: CGPoint) -> Int? {
        let reach = handleRadius * 1.8
        return annotation.handles.firstIndex { hypot($0.x - point.x, $0.y - point.y) <= reach }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if textView != nil {
            // A click outside the text box finishes typing.
            commitText()
            if state.tool == .text { return }
        }
        window?.makeFirstResponder(self)
        dragDidPushUndo = false
        drag = .none

        if state.tool == .select, event.clickCount == 2,
           let hit = annotations.last(where: { $0.kind == .text && $0.hitTest(point) }) {
            select(hit.id)
            beginTextEditing(at: hit.start, existing: hit)
            return
        }

        // The selected object can be adjusted with any tool active.
        if let index = selectedIndex {
            let selected = annotations[index]
            if let handle = handleIndex(of: selected, at: point) {
                if selected.isSegment {
                    drag = .resizingSegment(isStart: handle == 0)
                } else {
                    drag = .resizingBox(fixed: selected.handles[(handle + 2) % 4])
                }
                return
            }
            if selected.hitTest(point) {
                drag = .moving(last: point)
                return
            }
        }

        switch state.tool {
        case .select:
            if let hit = annotations.last(where: { $0.hitTest(point) }) {
                select(hit.id)
                drag = .moving(last: point)
            } else {
                select(nil)
            }
        case .crop:
            select(nil)
            drag = .cropping(origin: point)
            cropDraft = CGRect(origin: point, size: .zero)
        case .text:
            select(nil)
            let probe = Annotation(kind: .text, at: point, color: state.color, size: state.size)
            beginTextEditing(at: CGPoint(x: point.x, y: point.y - probe.fontSize * 0.6))
        case .counter:
            pushUndo()
            dragDidPushUndo = true
            var counter = Annotation(kind: .counter, at: point, color: state.color, size: state.size)
            counter.number = (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1
            annotations.append(counter)
            selectedID = counter.id
            drag = .moving(last: point)
        default:
            guard let kind = state.tool.annotationKind else { return }
            selectedID = nil
            var annotation = Annotation(kind: kind, at: point, color: state.color, size: state.size,
                                        filled: state.filled)
            if annotation.isFreehand { annotation.points = [point] }
            draft = annotation
            drag = .creating
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case .none:
            return
        case .creating:
            guard var annotation = draft else { return }
            if annotation.isFreehand {
                annotation.points.append(point)
            } else if annotation.isSegment {
                annotation.end = shift ? Geometry.snapAngle(from: annotation.start, to: point) : point
            } else {
                annotation.end = shift ? squareCorner(from: annotation.start, to: point) : point
            }
            draft = annotation
        case let .moving(last):
            guard let index = selectedIndex else { return }
            pushUndoOnceForDrag()
            annotations[index].translate(dx: point.x - last.x, dy: point.y - last.y)
            drag = .moving(last: point)
        case let .resizingSegment(isStart):
            guard let index = selectedIndex else { return }
            pushUndoOnceForDrag()
            if isStart {
                annotations[index].start = shift ? Geometry.snapAngle(from: annotations[index].end, to: point) : point
            } else {
                annotations[index].end = shift ? Geometry.snapAngle(from: annotations[index].start, to: point) : point
            }
        case let .resizingBox(fixed):
            guard let index = selectedIndex else { return }
            pushUndoOnceForDrag()
            annotations[index].start = fixed
            annotations[index].end = shift ? squareCorner(from: fixed, to: point) : point
        case let .cropping(origin):
            cropDraft = Geometry.rect(from: origin, to: point, square: shift).intersection(bounds)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .creating:
            if let annotation = draft, annotation.isSubstantial {
                pushUndo()
                annotations.append(annotation)
                // Freehand strokes stay unselected so the next stroke can start on top of them.
                if !annotation.isFreehand { select(annotation.id) }
            }
            draft = nil
        case .cropping:
            if let rect = cropDraft, rect.width >= 8, rect.height >= 8 { applyCrop(rect) }
            cropDraft = nil
        default:
            break
        }
        drag = .none
        needsDisplay = true
    }

    private func pushUndoOnceForDrag() {
        guard !dragDidPushUndo else { return }
        dragDidPushUndo = true
        pushUndo()
    }

    private func squareCorner(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let m = max(abs(b.x - a.x), abs(b.y - a.y))
        return CGPoint(x: a.x + (b.x < a.x ? -m : m), y: a.y + (b.y < a.y ? -m : m))
    }

    private func applyCrop(_ rect: CGRect) {
        let pixelRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                               width: rect.width * scale, height: rect.height * scale).integral
        guard let cropped = ImageCodec.crop(baseImage, toPixelRect: pixelRect) else { return }
        pushUndo()
        baseImage = cropped
        let dx = -pixelRect.minX / scale, dy = -pixelRect.minY / scale
        annotations = annotations.map { annotation in
            var moved = annotation
            moved.translate(dx: dx, dy: dy)
            return moved
        }
        selectedID = nil
        setFrameSize(imagePointSize)
        onCanvasResized?()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
            super.keyDown(with: event)
            return
        }
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            deleteSelection()
        case 53: // escape
            draft = nil
            cropDraft = nil
            drag = .none
            select(nil)
        case 123, 124, 125, 126: // arrow keys nudge the selection
            guard let index = selectedIndex else { return }
            pushUndo()
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0
            annotations[index].translate(dx: dx, dy: dy)
            needsDisplay = true
        default:
            if let character = event.charactersIgnoringModifiers?.lowercased().first,
               let tool = ToolKind.allCases.first(where: { $0.shortcut == character }) {
                state.tool = tool
            } else {
                super.keyDown(with: event)
            }
        }
    }

    // MARK: Text editing

    private func beginTextEditing(at origin: CGPoint, existing: Annotation? = nil) {
        let style = existing ?? Annotation(kind: .text, at: origin, color: state.color, size: state.size)
        let font = style.font
        let lineHeight = ceil(font.ascender - font.descender + font.leading)

        let editor = NSTextView(frame: CGRect(x: origin.x, y: origin.y, width: 40, height: lineHeight))
        editor.drawsBackground = false
        editor.isRichText = false
        editor.allowsUndo = true
        editor.font = font
        editor.textColor = style.color
        editor.insertionPointColor = style.color
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = false
        editor.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude,
                                                     height: CGFloat.greatestFiniteMagnitude)
        editor.isHorizontallyResizable = true
        editor.isVerticallyResizable = true
        editor.minSize = CGSize(width: 40, height: lineHeight)
        editor.maxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.string = existing?.text ?? ""
        editor.delegate = self
        addSubview(editor)
        editor.sizeToFit()
        textView = editor
        editingID = existing?.id
        window?.makeFirstResponder(editor)
        needsDisplay = true
    }

    func commitText() {
        guard let editor = textView else { return }
        textView = nil
        let string = editor.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = editor.frame.origin
        let color = editor.textColor ?? state.color
        editor.delegate = nil
        editor.removeFromSuperview()

        if let id = editingID, let index = annotations.firstIndex(where: { $0.id == id }) {
            if string.isEmpty {
                pushUndo()
                annotations.remove(at: index)
                selectedID = nil
            } else if annotations[index].text != string || annotations[index].color != color
                        || annotations[index].size != state.size {
                pushUndo()
                annotations[index].text = string
                annotations[index].color = color
                annotations[index].size = state.size
            }
        } else if !string.isEmpty {
            pushUndo()
            var annotation = Annotation(kind: .text, at: origin, color: color, size: state.size)
            annotation.text = string
            annotations.append(annotation)
            selectedID = annotation.id
        }
        editingID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            // Return finishes; Shift-Return starts a new line.
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                commitText()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            commitText()
            return true
        }
        return false
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var visible = annotations.filter { $0.id != editingID }
        if let draft { visible.append(draft) }
        renderer.draw(visible, base: baseImage, scale: scale, in: ctx)

        if let cropDraft {
            let path = CGMutablePath()
            path.addRect(bounds)
            path.addRect(cropDraft)
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 0, alpha: 0.5))
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 1))
            ctx.setLineWidth(1)
            ctx.stroke(cropDraft)
        }

        if let index = selectedIndex, annotations[index].id != editingID {
            drawSelection(annotations[index], in: ctx)
        }
    }

    private func drawSelection(_ annotation: Annotation, in ctx: CGContext) {
        let accent = NSColor.controlAccentColor.cgColor
        let zoom = enclosingScrollView?.magnification ?? 1
        ctx.setStrokeColor(accent)
        if annotation.handles.isEmpty {
            ctx.setLineWidth(1 / zoom)
            ctx.setLineDash(phase: 0, lengths: [4 / zoom, 3 / zoom])
            ctx.stroke(annotation.bounds.insetBy(dx: -4, dy: -4))
            ctx.setLineDash(phase: 0, lengths: [])
        }
        let radius = handleRadius
        ctx.setLineWidth(1.5 / zoom)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        for handle in annotation.handles {
            let rect = CGRect(x: handle.x - radius, y: handle.y - radius, width: radius * 2, height: radius * 2)
            ctx.fillEllipse(in: rect)
            ctx.strokeEllipse(in: rect)
        }
    }
}
