import AppKit

/// A captured / loaded image kept at full pixel resolution.
struct LoadedImage {
    let cgImage: CGImage
    /// Pixels per point (2.0 for a Retina capture).
    let scale: CGFloat

    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    var pointSize: CGSize { CGSize(width: pixelSize.width / scale, height: pixelSize.height / scale) }
}

/// Takes screenshots by delegating to macOS's own `screencapture -i`
/// (standard region selection UI; press Space to switch to window capture).
@MainActor
final class CaptureManager {
    private var isCapturing = false

    func captureInteractive(completion: @escaping @MainActor (LoadedImage) -> Void) {
        guard !isCapturing else { return }
        isCapturing = true

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quickmark-\(UUID().uuidString).png")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i: interactive selection, -x: no sound
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { _ in
            Task { @MainActor [weak self] in
                self?.isCapturing = false
                defer { try? FileManager.default.removeItem(at: url) }
                // No file means the user cancelled with Esc.
                guard let image = ImageLoader.load(url: url) else { return }
                completion(image)
            }
        }

        do {
            try process.run()
        } catch {
            isCapturing = false
            NSLog("QuickMark: failed to run screencapture: \(error)")
        }
    }
}

enum ImageLoader {
    static func load(url: URL) -> LoadedImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return load(data: data)
    }

    static func load(pasteboard: NSPasteboard) -> LoadedImage? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type), let image = load(data: data) {
                return image
            }
        }
        if let nsImage = NSImage(pasteboard: pasteboard),
           let cg = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let scale = nsImage.size.width > 0 ? CGFloat(cg.width) / nsImage.size.width : 1
            return LoadedImage(cgImage: cg, scale: max(scale, 1))
        }
        return nil
    }

    static func load(data: Data) -> LoadedImage? {
        guard let rep = NSBitmapImageRep(data: data), let cg = rep.cgImage else { return nil }
        // A Retina screenshot is saved at 144 dpi, so rep.size (points) is half the pixel size.
        let scale = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        return LoadedImage(cgImage: cg, scale: max(scale, 1))
    }
}
