import AppKit
import ScreenCaptureKit

/// Captures the screen (or a selected region) using ScreenCaptureKit.
/// First use triggers the system Screen Recording permission prompt.
enum ScreenCapture {

    enum CaptureError: Error { case noDisplay }

    /// Capture a region given in global AppKit coordinates (bottom-left origin).
    /// Pass `nil` to capture the whole display under the cursor. Multi-monitor safe.
    static func capture(globalRect: CGRect?) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        // Find the NSScreen the region (or cursor) lives on, in AppKit global coords.
        let screen: NSScreen
        if let r = globalRect {
            screen = NSScreen.screens.first { $0.frame.intersects(r) }
                ?? NSScreen.screens.first { $0.frame.contains(CGPoint(x: r.midX, y: r.midY)) }
                ?? NSScreen.main ?? NSScreen.screens[0]
        } else {
            let m = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(m) } ?? NSScreen.main ?? NSScreen.screens[0]
        }

        // Map that NSScreen to its SCDisplay via the CG display id.
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let displayID = (screen.deviceDescription[key] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID })
                ?? content.displays.first else {
            throw CaptureError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.showsCursor = false
        config.width = display.width
        config.height = display.height
        let full = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        guard let r = globalRect else { return pngData(from: full) }

        // Region → screen-local (bottom-left) → image pixels (top-left).
        let local = CGRect(x: r.minX - screen.frame.minX, y: r.minY - screen.frame.minY,
                           width: r.width, height: r.height)
        let scaleX = Double(full.width) / Double(screen.frame.width)
        let scaleY = Double(full.height) / Double(screen.frame.height)
        let topLeftY = screen.frame.height - local.maxY
        let pxRect = CGRect(x: local.minX * scaleX, y: topLeftY * scaleY,
                            width: local.width * scaleX, height: local.height * scaleY)
        guard let cropped = full.cropping(to: pxRect) else { return pngData(from: full) }
        return pngData(from: cropped)
    }

    private static func pngData(from cgImage: CGImage) -> Data {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
