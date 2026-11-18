import AppKit
import ApplicationServices
import QuartzCore

/// Resizes the focused window of the frontmost application to the visible
/// frame (menu bar and Dock excluded) of the screen the window occupies.
///
/// This uses the Accessibility API, so CatchMouse needs the user to grant
/// Accessibility permission — unlike cursor warping, there is no
/// permission-free public API for manipulating other apps' windows.
enum WindowMaximizer {
    private static let messagingTimeout: Float = 0.25
    private static let fullScreenAttribute = "AXFullScreen"
    private static let goldenRatio: CGFloat = (1 + CGFloat(5).squareRoot()) / 2
    private static let goldenWidthRatio: CGFloat = 2.0 / 3.0
    private static let goldenMaxHeightRatio: CGFloat = 0.85

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Ask macOS to show the Accessibility permission prompt. This also adds
    /// CatchMouse to the Accessibility list in System Settings.
    @discardableResult
    static func requestAccess() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Maximize the focused (or main) window of `pid`, falling back to the
    /// frontmost application. Returns `false` when there is no suitable
    /// window, the window is minimized or full screen, or Accessibility is
    /// not granted.
    @discardableResult
    static func maximize(pid: pid_t? = nil) -> Bool {
        guard isTrusted,
              let window = window(pid: pid ?? frontmostPid()),
              !boolAttribute(window, kAXMinimizedAttribute),
              !boolAttribute(window, fullScreenAttribute),
              isSettable(window, kAXSizeAttribute),
              let axFrame = frame(of: window),
              let screen = screen(containing: flip(axFrame))
        else { return false }

        let target = flip(screen.visibleFrame)
        guard axFrame != target else { return true }
        setFrame(target, on: window)
        return true
    }

    /// Resize the focused (or main) window of `pid` to a centered golden
    /// rectangle (width : height = 1.618…), no wider than 2/3 of the visible
    /// width and no taller than 85% of the visible height. The move is animated
    /// unless `animate` is false (the CLI exits before a timer could run).
    @discardableResult
    static func goldenResize(pid: pid_t? = nil, animate: Bool = true) -> Bool {
        guard isTrusted,
              let window = window(pid: pid ?? frontmostPid()),
              !boolAttribute(window, kAXMinimizedAttribute),
              !boolAttribute(window, fullScreenAttribute),
              isSettable(window, kAXSizeAttribute),
              let axFrame = frame(of: window),
              let screen = screen(containing: flip(axFrame))
        else { return false }

        let visible = screen.visibleFrame
        let size = goldenSize(in: visible)
        let target = flip(CGRect(x: visible.midX - size.width / 2,
                                 y: visible.midY - size.height / 2,
                                 width: size.width,
                                 height: size.height))
        guard axFrame != target else { return true }
        if animate {
            animateFrame(from: axFrame, to: target, on: window)
        } else {
            setFrame(target, on: window)
        }
        return true
    }

    /// Toggle native full screen for the focused (or main) window of `pid`,
    /// falling back to the frontmost application.
    @discardableResult
    static func toggleFullScreen(pid: pid_t? = nil) -> Bool {
        guard isTrusted,
              let window = window(pid: pid ?? frontmostPid()),
              !boolAttribute(window, kAXMinimizedAttribute),
              let isFullScreen = optionalBoolAttribute(window, fullScreenAttribute),
              isSettable(window, fullScreenAttribute)
        else { return false }

        let value: CFTypeRef = isFullScreen ? kCFBooleanFalse : kCFBooleanTrue
        return AXUIElementSetAttributeValue(window, fullScreenAttribute as CFString, value) == .success
    }

    private static func frontmostPid() -> pid_t? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return nil }
        return app.processIdentifier
    }

    // MARK: - Window lookup

    private static func window(pid: pid_t?) -> AXUIElement? {
        guard let pid else { return nil }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        return windowElement(in: application)
    }

    private static func windowElement(in application: AXUIElement) -> AXUIElement? {
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = elementAttribute(application, attribute) { return window }
        }
        return arrayAttribute(application, kAXWindowsAttribute)?.first
    }

    private static func elementAttribute(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private static func arrayAttribute(_ element: AXUIElement, _ attribute: String) -> [AXUIElement]? {
        guard let value = attributeValue(element, attribute) else { return nil }
        return value as? [AXUIElement]
    }

    private static func boolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool {
        optionalBoolAttribute(element, attribute) ?? false
    }

    private static func optionalBoolAttribute(_ element: AXUIElement, _ attribute: String) -> Bool? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == CFBooleanGetTypeID()
        else { return nil }
        return CFBooleanGetValue((value as! CFBoolean))
    }

    private static func attributeValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value
    }

    private static func isSettable(_ element: AXUIElement, _ attribute: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, attribute as CFString, &settable) == .success
            && settable.boolValue
    }

    // MARK: - Frame

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(window, kAXPositionAttribute),
              let sizeValue = axValue(window, kAXSizeAttribute)
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    private static func axValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        guard let value = attributeValue(element, attribute),
              CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }

    /// macOS clamps a resize to the window's current display, so a window
    /// moving to another screen must be resized, moved, then resized again.
    private static func setFrame(_ frame: CGRect, on window: AXUIElement) {
        var size = frame.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        if isSettable(window, kAXPositionAttribute) {
            var origin = frame.origin
            if let value = AXValueCreate(.cgPoint, &origin) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
            }
        }
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    // MARK: - Frame animation

    private static var animator: FrameAnimator?

    /// The Accessibility API has no built-in animation, so step the frame
    /// towards the target from a 60 Hz timer with an ease-out curve.
    private static func animateFrame(from start: CGRect, to target: CGRect, on window: AXUIElement) {
        animator?.cancel()
        let animation = FrameAnimator(from: start, to: target, window: window)
        animator = animation
        animation.begin()
    }

    private static func setFrameStep(_ frame: CGRect, on window: AXUIElement) {
        var size = frame.size
        if let value = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
        var origin = frame.origin
        if let value = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    private final class FrameAnimator {
        private let window: AXUIElement
        private let start: CGRect
        private let target: CGRect
        private let startedAt = CACurrentMediaTime()
        private let duration: TimeInterval = 0.28
        private var timer: Timer?

        init(from start: CGRect, to target: CGRect, window: AXUIElement) {
            self.start = start
            self.target = target
            self.window = window
        }

        func begin() {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                self?.tick()
            }
            timer.tolerance = 0.002
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        func cancel() {
            timer?.invalidate()
            timer = nil
        }

        private func tick() {
            let t = min(max((CACurrentMediaTime() - startedAt) / duration, 0), 1)
            guard t < 1 else {
                WindowMaximizer.setFrame(target, on: window)
                timer?.invalidate()
                timer = nil
                if WindowMaximizer.animator === self { WindowMaximizer.animator = nil }
                return
            }
            let progress = CGFloat(1 - pow(1 - t, 3))
            let frame = CGRect(
                x: start.minX + (target.minX - start.minX) * progress,
                y: start.minY + (target.minY - start.minY) * progress,
                width: start.width + (target.width - start.width) * progress,
                height: start.height + (target.height - start.height) * progress)
            WindowMaximizer.setFrameStep(frame, on: window)
        }
    }

    // MARK: - Geometry

    /// Size of the centered golden rectangle for a visible frame: a true
    /// 1.618… aspect, capped at 2/3 of the width and 85% of the height.
    static func goldenSize(in visibleFrame: CGRect) -> CGSize {
        let width = min(visibleFrame.width * goldenWidthRatio,
                        visibleFrame.height * goldenMaxHeightRatio * goldenRatio)
        return CGSize(width: width, height: width / goldenRatio)
    }

    /// Convert between the Accessibility/CoreGraphics space (top-left origin)
    /// and the AppKit screen space (bottom-left origin). The transform is its
    /// own inverse.
    static func flip(_ rect: CGRect, primaryMaxY: CGFloat = NSScreen.screens.first?.frame.maxY ?? 0) -> CGRect {
        guard !rect.isNull else { return rect }
        return CGRect(x: rect.minX, y: primaryMaxY - rect.maxY, width: rect.width, height: rect.height)
    }

    /// Index of the screen with the largest overlap with `windowFrame`, or
    /// `nil` when the window lies entirely off screen.
    static func bestScreenIndex(for windowFrame: CGRect, in screenFrames: [CGRect]) -> Int? {
        var bestIndex: Int?
        var bestArea: CGFloat = 0
        for (index, screenFrame) in screenFrames.enumerated() {
            let intersection = screenFrame.intersection(windowFrame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                bestIndex = index
            }
        }
        return bestIndex
    }

    private static func screen(containing appKitFrame: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let index = bestScreenIndex(for: appKitFrame, in: screens.map(\.frame)) {
            return screens[index]
        }
        let mouse = NSEvent.mouseLocation
        return screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main ?? screens.first
    }
}
