import AppKit
import Combine

/// Shows the image scaled to fit and handles mouse input for drawing.
/// Converts between view points and image pixels; annotations are always
/// stored in image pixels so the export is full resolution.
@MainActor
final class EditorCanvasView: NSView, NSTextFieldDelegate, NSMenuItemValidation {
    private let model: AnnotationModel
    private let image: LoadedImage
    private let nsImage: NSImage
    private var cancellables: Set<AnyCancellable> = []

    var onCopy: (() -> Void)?
    var onClose: (() -> Void)?

    private enum DragState {
        case none
        case creating(start: CGPoint)
        case moving(id: UUID, last: CGPoint, undoRegistered: Bool)
    }
    private var drag: DragState = .none
    private var preview: Annotation?

    // Text editing
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero      // image pixels
    private var editingID: UUID?                 // existing text being edited

    private let padding: CGFloat = 16

    init(model: AnnotationModel, image: LoadedImage) {
        self.model = model
        self.image = image
        self.nsImage = NSImage(cgImage: image.cgImage, size: image.pointSize)
        super.init(frame: .zero)

        model.objectWillChange
            .sink { [weak self] _ in
                // objectWillChange fires before the change lands; redraw on the next turn.
                DispatchQueue.main.async { self?.modelDidChange() }
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func modelDidChange() {
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        if let textField {
            textField.textColor = model.color
        } else if window?.firstResponder !== self {
            window?.makeFirstResponder(self)
        }
    }

    // MARK: Geometry

    /// View points per image pixel. Never enlarges beyond the image's native point size.
    private var displayScale: CGFloat {
        let px = image.pixelSize
        let available = bounds.insetBy(dx: padding, dy: padding)
        let fit = min(available.width / px.width, available.height / px.height)
        return max(0.01, min(fit, 1 / image.scale))
    }

    private var imageRect: CGRect {
        let s = displayScale
        let w = image.pixelSize.width * s, h = image.pixelSize.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    private func toImage(_ viewPoint: CGPoint) -> CGPoint {
        let r = imageRect, s = displayScale
        return CGPoint(x: (viewPoint.x - r.minX) / s, y: (viewPoint.y - r.minY) / s)
    }

    private func toView(_ imageRectValue: CGRect) -> CGRect {
        let r = imageRect, s = displayScale
        return CGRect(x: r.minX + imageRectValue.minX * s, y: r.minY + imageRectValue.minY * s,
                      width: imageRectValue.width * s, height: imageRectValue.height * s)
    }

    private func imagePoint(for event: NSEvent) -> CGPoint {
        toImage(convert(event.locationInWindow, from: nil))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.underPageBackgroundColor.setFill()
        bounds.fill()

        let r = imageRect
        nsImage.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true,
                     hints: [.interpolation: NSNumber(value: NSImageInterpolation.high.rawValue)])

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var list = model.annotations.filter { $0.id != editingID }
        if let preview { list.append(preview) }

        ctx.saveGState()
        ctx.clip(to: r)
        ctx.translateBy(x: r.minX, y: r.minY)
        ctx.scaleBy(x: displayScale, y: displayScale)
        AnnotationRenderer.draw(list, in: ctx)
        ctx.restoreGState()

        if let selected = model.selected, selected.id != editingID {
            let path = NSBezierPath(rect: toView(selected.bounds).insetBy(dx: -3, dy: -3))
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        case .arrow, .rectangle: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if textField != nil {
            // A click outside the text field finishes the text.
            commitTextEditing()
            return
        }
        window?.makeFirstResponder(self)

        let p = imagePoint(for: event)
        let tolerance = 6 / displayScale

        switch model.tool {
        case .select:
            if let hit = model.hitTest(p, tolerance: tolerance) {
                model.selectedID = hit.id
                if event.clickCount == 2, case .text = hit.kind {
                    beginTextEditing(existing: hit)
                    return
                }
                drag = .moving(id: hit.id, last: p, undoRegistered: false)
            } else {
                model.selectedID = nil
            }
        case .arrow, .rectangle:
            model.selectedID = nil
            drag = .creating(start: p)
        case .text:
            if let hit = model.hitTest(p, tolerance: tolerance), case .text = hit.kind {
                beginTextEditing(existing: hit)
            } else {
                model.selectedID = nil
                beginTextEditing(at: p)
            }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(for: event)
        switch drag {
        case .none:
            return
        case let .creating(start):
            switch model.tool {
            case .arrow:
                preview = model.make(.arrow(start: start, end: p))
            case .rectangle:
                preview = model.make(.rectangle(CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                                       width: abs(p.x - start.x), height: abs(p.y - start.y))))
            default:
                break
            }
        case let .moving(id, last, undoRegistered):
            if !undoRegistered { model.registerUndoPoint() }
            model.move(id: id, by: CGSize(width: p.x - last.x, height: p.y - last.y))
            drag = .moving(id: id, last: p, undoRegistered: true)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .creating = drag, let preview {
            let b: CGRect
            switch preview.kind {
            case let .arrow(s, e): b = CGRect(x: s.x, y: s.y, width: abs(e.x - s.x), height: abs(e.y - s.y))
            default: b = preview.bounds
            }
            // Ignore accidental clicks.
            let minSize = 4 / displayScale
            if b.width > minSize || b.height > minSize {
                model.add(preview)
            }
        }
        preview = nil
        drag = .none
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if mods.isEmpty {
            switch event.keyCode {
            case 51, 117: // delete, forward delete
                model.deleteSelected()
                return
            case 53: // esc
                onClose?()
                return
            default:
                break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "v": model.tool = .select; return
            case "a": model.tool = .arrow; return
            case "r": model.tool = .rectangle; return
            case "t": model.tool = .text; return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    // Edit-menu actions (⌘Z, ⇧⌘Z, ⌘C) reach here through the responder chain.
    // While a text field is active, its field editor handles copy first; undo is
    // disabled for annotations so it doesn't undo shapes mid-typing.

    @objc func undo(_ sender: Any?) {
        guard textField == nil else { return }
        model.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard textField == nil else { return }
        model.redo()
    }

    @objc func copy(_ sender: Any?) {
        onCopy?()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case Selector(("undo:")): return textField == nil && model.canUndo
        case Selector(("redo:")): return textField == nil && model.canRedo
        case #selector(copy(_:)): return true
        default: return false
        }
    }

    // MARK: Text editing

    private func beginTextEditing(at origin: CGPoint) {
        startTextField(origin: origin, text: "", font: model.make(.text("", origin: origin)).font,
                       color: model.color, editing: nil)
    }

    private func beginTextEditing(existing annotation: Annotation) {
        guard case let .text(text, origin) = annotation.kind else { return }
        model.selectedID = annotation.id
        startTextField(origin: origin, text: text, font: annotation.font,
                       color: annotation.color, editing: annotation.id)
    }

    private func startTextField(origin: CGPoint, text: String, font: NSFont, color: NSColor, editing: UUID?) {
        textOrigin = origin
        editingID = editing

        let s = displayScale
        let viewFont = NSFont.boldSystemFont(ofSize: max(font.pointSize * s, 8))
        let field = NSTextField(string: text)
        field.font = viewFont
        field.textColor = color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.6)
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "テキスト"

        let r = imageRect
        // NSTextField insets its text by ~2pt; shift so the text lands where it will be drawn.
        field.frame = CGRect(x: r.minX + origin.x * s - 2, y: r.minY + origin.y * s,
                             width: 200, height: ceil(viewFont.ascender - viewFont.descender + viewFont.leading) + 4)
        resizeTextField(field)

        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    private func resizeTextField(_ field: NSTextField) {
        let fitting = field.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: field.frame.height))
        field.setFrameSize(NSSize(width: max(fitting.width + 12, 80), height: field.frame.height))
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === textField {
            resizeTextField(field)
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if let field = obj.object as? NSTextField, field === textField {
            commitTextEditing()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishTextEditing(commit: false)
            return true
        }
        return false
    }

    /// Commits any in-progress text. Safe to call when nothing is being edited.
    func commitTextEditing() {
        finishTextEditing(commit: true)
    }

    private func finishTextEditing(commit: Bool) {
        guard let field = textField else { return }
        // Clear state first: removing the field triggers controlTextDidEndEditing again.
        textField = nil
        field.delegate = nil
        let text = field.stringValue
        let editing = editingID
        editingID = nil
        field.removeFromSuperview()

        if commit {
            let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let editing {
                if isEmpty { model.remove(id: editing) } else { model.updateText(id: editing, to: text) }
            } else if !isEmpty {
                model.add(model.make(.text(text, origin: textOrigin)))
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}
