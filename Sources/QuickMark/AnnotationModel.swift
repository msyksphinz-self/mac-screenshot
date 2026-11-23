import AppKit
import Combine

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, rectangle, text

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        }
    }

    var helpText: String {
        switch self {
        case .select: return "選択・移動 (V)"
        case .arrow: return "矢印 (A)"
        case .rectangle: return "四角 (R)"
        case .text: return "テキスト (T)"
        }
    }
}

enum Palette {
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.95, green: 0.20, blue: 0.20, alpha: 1), // red
        NSColor(srgbRed: 1.00, green: 0.70, blue: 0.00, alpha: 1), // yellow
        NSColor(srgbRed: 0.15, green: 0.70, blue: 0.30, alpha: 1), // green
        NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1), // blue
        NSColor(srgbRed: 0.00, green: 0.00, blue: 0.00, alpha: 1), // black
        NSColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1), // white
    ]
}

/// One annotation. All coordinates are in the ORIGINAL IMAGE PIXEL space
/// (origin top-left, y down), independent of the on-screen zoom.
struct Annotation: Identifiable {
    enum Kind {
        case arrow(start: CGPoint, end: CGPoint)
        case rectangle(CGRect)
        case text(String, origin: CGPoint)
    }

    let id = UUID()
    var kind: Kind
    var color: NSColor
    var lineWidth: CGFloat
    var fontSize: CGFloat

    var font: NSFont { .boldSystemFont(ofSize: fontSize) }

    var bounds: CGRect {
        switch kind {
        case let .arrow(s, e):
            return CGRect(x: min(s.x, e.x), y: min(s.y, e.y),
                          width: abs(e.x - s.x), height: abs(e.y - s.y))
                .insetBy(dx: -lineWidth * 2, dy: -lineWidth * 2)
        case let .rectangle(r):
            return r.insetBy(dx: -lineWidth / 2, dy: -lineWidth / 2)
        case let .text(string, origin):
            let size = NSAttributedString(string: string, attributes: [.font: font]).size()
            return CGRect(origin: origin, size: size)
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch kind {
        case let .arrow(s, e):
            return distance(from: p, toSegment: s, e) <= tolerance + lineWidth / 2
        case let .rectangle(r):
            // Only the border is clickable so things inside stay selectable.
            let t = tolerance + lineWidth / 2
            let outer = r.insetBy(dx: -t, dy: -t)
            let inner = r.insetBy(dx: t, dy: t)
            return outer.contains(p) && (inner.isNull || inner.isEmpty || !inner.contains(p))
        case .text:
            return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    func offset(by d: CGSize) -> Annotation {
        var copy = self
        switch kind {
        case let .arrow(s, e):
            copy.kind = .arrow(start: s.offset(d), end: e.offset(d))
        case let .rectangle(r):
            copy.kind = .rectangle(r.offsetBy(dx: d.width, dy: d.height))
        case let .text(string, origin):
            copy.kind = .text(string, origin: origin.offset(d))
        }
        return copy
    }
}

extension CGPoint {
    func offset(_ d: CGSize) -> CGPoint { CGPoint(x: x + d.width, y: y + d.height) }
}

private func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Holds the annotations separately from the image, plus undo/redo history.
@MainActor
final class AnnotationModel: ObservableObject {
    @Published private(set) var annotations: [Annotation] = []
    @Published var tool: Tool = .arrow
    @Published private(set) var color: NSColor = Palette.colors[0]
    @Published var selectedID: UUID?
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    /// Default sizes in image pixels, scaled so they look the same on Retina captures.
    let defaultLineWidth: CGFloat
    let defaultFontSize: CGFloat

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []

    init(imageScale: CGFloat) {
        defaultLineWidth = 3 * imageScale
        defaultFontSize = 20 * imageScale
    }

    var selected: Annotation? {
        guard let selectedID else { return nil }
        return annotations.first { $0.id == selectedID }
    }

    func make(_ kind: Annotation.Kind) -> Annotation {
        Annotation(kind: kind, color: color, lineWidth: defaultLineWidth, fontSize: defaultFontSize)
    }

    // MARK: Undo

    /// Call before a change that should be undoable as one step.
    func registerUndoPoint() {
        undoStack.append(annotations)
        redoStack.removeAll()
        updateUndoFlags()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = previous
        dropStaleSelection()
        updateUndoFlags()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = next
        dropStaleSelection()
        updateUndoFlags()
    }

    private func updateUndoFlags() {
        canUndo = !undoStack.isEmpty
        canRedo = !redoStack.isEmpty
    }

    private func dropStaleSelection() {
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    // MARK: Edits

    func add(_ annotation: Annotation) {
        registerUndoPoint()
        annotations.append(annotation)
    }

    func remove(id: UUID) {
        guard annotations.contains(where: { $0.id == id }) else { return }
        registerUndoPoint()
        annotations.removeAll { $0.id == id }
        dropStaleSelection()
    }

    func deleteSelected() {
        if let selectedID { remove(id: selectedID) }
    }

    /// Moves without registering undo; the caller registers once per drag.
    func move(id: UUID, by d: CGSize) {
        guard let i = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[i] = annotations[i].offset(by: d)
    }

    func updateText(id: UUID, to text: String) {
        guard let i = annotations.firstIndex(where: { $0.id == id }),
              case let .text(old, origin) = annotations[i].kind, old != text else { return }
        registerUndoPoint()
        annotations[i].kind = .text(text, origin: origin)
    }

    /// Sets the color for new annotations, and recolors the selection if any.
    func applyColor(_ newColor: NSColor) {
        color = newColor
        if let selectedID, let i = annotations.firstIndex(where: { $0.id == selectedID }) {
            registerUndoPoint()
            annotations[i].color = newColor
        }
    }

    func hitTest(_ p: CGPoint, tolerance: CGFloat) -> Annotation? {
        annotations.reversed().first { $0.hitTest(p, tolerance: tolerance) }
    }
}
