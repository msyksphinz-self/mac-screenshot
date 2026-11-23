import AppKit
import SwiftUI

/// One editor window per screenshot.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private let image: LoadedImage
    private let model: AnnotationModel
    private let canvas: EditorCanvasView
    private let window: NSWindow
    private let onClosed: (EditorWindowController) -> Void

    init(image: LoadedImage, onClosed: @escaping (EditorWindowController) -> Void) {
        let model = AnnotationModel(imageScale: image.scale)
        let canvas = EditorCanvasView(model: model, image: image)
        self.image = image
        self.model = model
        self.canvas = canvas
        self.onClosed = onClosed

        let toolbarHeight: CGFloat = 46
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(image.pointSize.width + 32, 520), visible.width * 0.85)
        let height = min(max(image.pointSize.height + 32 + toolbarHeight, 320), visible.height * 0.85)

        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()

        window.title = "QuickMark"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 520, height: 320)

        canvas.onCopy = { [weak self] in self?.copyAndClose() }
        canvas.onClose = { [weak self] in self?.window.close() }

        window.contentView = NSHostingView(rootView: EditorRootView(
            model: model,
            canvas: canvas,
            onCopy: { [weak self] in self?.copyAndClose() },
            onClose: { [weak self] in self?.window.close() }
        ))
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    /// Composite at original pixel size → pasteboard → close.
    func copyAndClose() {
        canvas.commitTextEditing()
        guard let output = ImageExporter.render(image: image.cgImage, annotations: model.annotations),
              ImageExporter.copyToPasteboard(output, scale: image.scale) else {
            NSSound.beep()
            return
        }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        onClosed(self)
    }
}

private struct EditorRootView: View {
    @ObservedObject var model: AnnotationModel
    let canvas: EditorCanvasView
    let onCopy: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Picker("ツール", selection: $model.tool) {
                    ForEach(Tool.allCases) { tool in
                        Image(systemName: tool.symbolName)
                            .help(tool.helpText)
                            .tag(tool)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()

                HStack(spacing: 6) {
                    ForEach(Palette.colors.indices, id: \.self) { i in
                        let c = Palette.colors[i]
                        let isCurrent = model.color == c
                        Button { model.applyColor(c) } label: {
                            Circle()
                                .fill(Color(nsColor: c))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().stroke(isCurrent ? Color.accentColor : Color.gray.opacity(0.6),
                                                         lineWidth: isCurrent ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("取り消す (⌘Z)")
                    .disabled(!model.canUndo)
                Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                    .help("やり直す (⇧⌘Z)")
                    .disabled(!model.canRedo)

                Button("閉じる", action: onClose)
                    .help("Esc")
                Button(action: onCopy) {
                    Label("コピーして閉じる", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .help("⌘C")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            CanvasRepresentable(canvas: canvas)
        }
    }
}

private struct CanvasRepresentable: NSViewRepresentable {
    let canvas: EditorCanvasView
    func makeNSView(context: Context) -> EditorCanvasView { canvas }
    func updateNSView(_ nsView: EditorCanvasView, context: Context) {}
}
