import AppKit

/// Detects a deliberate mouse "shake": several rapid horizontal direction
/// reversals within a short window. Mirrors the macOS "shake to find cursor"
/// gesture so it feels native and is hard to trigger by accident.
@MainActor
final class ShakeDetector {
    /// Called on the main thread when a shake is recognized.
    var onShake: (() -> Void)?

    // Tuning knobs.
    private let reversalsToTrigger = 4        // direction flips needed
    private let windowSeconds: TimeInterval = 0.6
    private let minSpeed: CGFloat = 6.0       // px per event; ignores slow drift
    private let cooldown: TimeInterval = 1.5  // ignore shakes right after a trigger

    private var lastPoint: CGPoint?
    private var lastDirection: CGFloat = 0     // -1, 0, +1 on the X axis
    private var reversalTimes: [TimeInterval] = []
    private var lastTriggerTime: TimeInterval = 0
    private var monitor: Any?

    func start() {
        // Passive global monitor: observes movement everywhere without
        // consuming events. Mouse-move observation does not need an entitlement,
        // but the app must be running as a foreground-capable agent.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            // Global monitors are delivered on the main run loop.
            MainActor.assumeIsolated { self?.handle(event) }
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    private func handle(_ event: NSEvent) {
        // Ignore motion while ⌘ is held — that's the snip gesture, not a shake.
        if event.modifierFlags.contains(.command) { lastPoint = nil; return }

        let p = NSEvent.mouseLocation
        defer { lastPoint = p }
        guard let last = lastPoint else { return }

        let dx = p.x - last.x
        guard abs(dx) >= minSpeed else { return }

        let dir: CGFloat = dx > 0 ? 1 : -1
        let t = now()

        if lastDirection != 0 && dir != lastDirection {
            reversalTimes.append(t)
            reversalTimes.removeAll { t - $0 > windowSeconds }

            if reversalTimes.count >= reversalsToTrigger, t - lastTriggerTime > cooldown {
                lastTriggerTime = t
                reversalTimes.removeAll()
                onShake?()
            }
        }
        lastDirection = dir
    }
}
