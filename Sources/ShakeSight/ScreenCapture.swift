import AppKit
import ScreenCaptureKit

/// Captures the screen (or a selected region) using ScreenCaptureKit.
/// First use triggers the system Screen Recording permission prompt.
enum ScreenCapture {

    enum CaptureError: Error { case noDisplay }

    /// Capture a region given in global AppKit coordinates (bottom-left origin).
    /// Pass `nil` to capture the whole display under the cursor.
    static func capture(globalRect: CGRect?) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // CoreGraphics global space is top-left origin; flip using the primary screen height.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

        func displayContaining(_ cgPoint: CGPoint) -> SCDisplay? {
            content.displays.first { CGDisplayBounds($0.displayID).contains(cgPoint) }
        }

        var resolved: SCDisplay?
        var sourceRect: CGRect?

        if let r = globalRect {
            // AppKit bottom-left rect -> CoreGraphics top-left rect.
            let cgRect = CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
            resolved = displayContaining(CGPoint(x: cgRect.midX, y: cgRect.midY)) ?? content.displays.first
            if let d = resolved {
                let bounds = CGDisplayBounds(d.displayID)
                sourceRect = cgRect.offsetBy(dx: -bounds.origin.x, dy: -bounds.origin.y)
            }
        } else {
            let mouse = NSEvent.mouseLocation
            let cg = CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
            resolved = displayContaining(cg) ?? content.displays.first
        }

        guard let display = resolved else { throw CaptureError.noDisplay }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false

        if let sr = sourceRect {
            config.sourceRect = sr
            config.width = max(1, Int(sr.width))
            config.height = max(1, Int(sr.height))
        } else {
            config.width = display.width
            config.height = display.height
        }

        let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return pngData(from: cgImage)
    }

    private static func pngData(from cgImage: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
