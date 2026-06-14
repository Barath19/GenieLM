import AppKit
import ApplicationServices

/// One actionable UI element from the accessibility tree.
struct UIElement {
    let id: Int
    let role: String
    let label: String
    let frame: CGRect   // screen coords, CoreGraphics top-left origin
    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// Walks the frontmost app's accessibility tree and serializes actionable
/// elements (with on-screen coordinates) to text — the input for text-based
/// UI grounding. Needs Accessibility permission.
@MainActor
enum AccessibilityDumper {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestPermission() {
        // Literal value of kAXTrustedCheckOptionPrompt (avoids the non-Sendable global).
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    private static let actionableRoles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem", "AXMenuButton",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXTab",
        "AXDisclosureTriangle", "AXSlider", "AXSegmentedControl", "AXSearchField"
    ]

    /// Actionable elements of the frontmost (non-GenieLM) app.
    static func dumpFrontmost(maxElements: Int = 150) -> (app: String, elements: [UIElement]) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ("?", []) }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var out: [UIElement] = []
        var counter = 0
        walk(axApp, depth: 0, out: &out, counter: &counter, maxElements: maxElements)
        return (app.localizedName ?? "?", out)
    }

    static func serialize(_ els: [UIElement]) -> String {
        els.map { e in
            let role = e.role.hasPrefix("AX") ? String(e.role.dropFirst(2)) : e.role
            return "[\(e.id)] \(role) \"\(e.label)\" center=(\(Int(e.center.x)),\(Int(e.center.y)))"
        }.joined(separator: "\n")
    }

    // MARK: - Tree walk

    private static func attr(_ el: AXUIElement, _ a: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, a as CFString, &v) == .success ? v : nil
    }
    private static func str(_ el: AXUIElement, _ a: String) -> String? { attr(el, a) as? String }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let posV = attr(el, kAXPositionAttribute as String),
              let sizeV = attr(el, kAXSizeAttribute as String) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func walk(_ el: AXUIElement, depth: Int, out: inout [UIElement], counter: inout Int, maxElements: Int) {
        if out.count >= maxElements || depth > 40 { return }

        if let role = str(el, kAXRoleAttribute as String), actionableRoles.contains(role) {
            let label = str(el, kAXTitleAttribute as String)
                ?? str(el, kAXDescriptionAttribute as String)
                ?? (attr(el, "AXLabel") as? String)
                ?? str(el, kAXValueAttribute as String)
                ?? ""
            if let f = frame(el), f.width > 0, f.height > 0, !label.isEmpty {
                out.append(UIElement(id: counter, role: role, label: label, frame: f))
                counter += 1
            }
        }
        if let kids = attr(el, kAXChildrenAttribute as String) as? [AXUIElement] {
            for k in kids { walk(k, depth: depth + 1, out: &out, counter: &counter, maxElements: maxElements) }
        }
    }
}
