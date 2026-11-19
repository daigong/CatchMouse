import AppKit
import Darwin

/// Briefly enlarges the system pointer after a display jump so the move is easy
/// to spot. The cursor keeps its native shape, hotspots and movement; it simply
/// grows, holds, then shrinks back. This uses the WindowServer cursor-scale API
/// — the same one behind the Accessibility pointer-size setting.
enum CursorPulse {
    private static let multiplier: Float = 3.5
    private static let maximumScale: Float = 4
    private static let growSeconds: TimeInterval = 0.15
    private static let holdUntilSeconds: TimeInterval = 0.5
    private static let lifetime: TimeInterval = 0.6
    private static let savedScaleKey = "cursorPulse.originalScale"

    private static var timer: Timer?
    private static var startedAt: CFTimeInterval = 0
    private static var baseScale: Float?
    private static var targetScale: Float = 1

    static func show() {
        finish(restore: true)
        guard let base = CursorScaler.current() else { return }
        baseScale = base
        targetScale = min(base * multiplier, max(maximumScale, base))
        startedAt = CACurrentMediaTime()
        // Remember the user's setting so a crash can be recovered on next launch.
        UserDefaults.standard.set(Double(base), forKey: savedScaleKey)
        CursorScaler.set(base)

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in CursorPulse.tick() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
    }

    /// Restore the pointer if a previous run exited before shrinking it back.
    static func restoreStaleScale() {
        guard let saved = UserDefaults.standard.object(forKey: savedScaleKey) as? Double else { return }
        CursorScaler.set(Float(saved))
        UserDefaults.standard.removeObject(forKey: savedScaleKey)
    }

    static func cancel() { finish(restore: true) }

    private static func tick() {
        guard let base = baseScale else { finish(restore: false); return }
        let elapsed = CACurrentMediaTime() - startedAt
        guard elapsed < lifetime else { finish(restore: true); return }
        CursorScaler.set(scale(at: elapsed, base: base))
    }

    private static func scale(at elapsed: TimeInterval, base: Float) -> Float {
        if elapsed < growSeconds {
            // Slight bounce: overshoot, dip, settle.
            let times: [TimeInterval] = [0, 0.05, 0.09, growSeconds]
            let values: [Float] = [base, targetScale * 1.07, targetScale * 0.98, targetScale]
            for index in 1 ..< times.count where elapsed <= times[index] {
                let p = (elapsed - times[index - 1]) / (times[index] - times[index - 1])
                return mix(values[index - 1], values[index], p)
            }
            return targetScale
        }
        if elapsed < holdUntilSeconds { return targetScale }
        let p = (elapsed - holdUntilSeconds) / (lifetime - holdUntilSeconds)
        return mix(targetScale, base, p)
    }

    private static func mix(_ from: Float, _ to: Float, _ progress: Double) -> Float {
        let eased = progress * progress * (3 - 2 * progress)
        return from + (to - from) * Float(eased)
    }

    private static func finish(restore: Bool) {
        timer?.invalidate()
        timer = nil
        if restore, let base = baseScale {
            CursorScaler.set(base)
            UserDefaults.standard.removeObject(forKey: savedScaleKey)
        }
        baseScale = nil
    }
}

/// Thin wrapper over the private WindowServer cursor-scale functions.
private enum CursorScaler {
    typealias MainConnection = @convention(c) () -> Int32
    typealias GetScale = @convention(c) (Int32, UnsafeMutablePointer<Float>) -> Int32
    typealias SetScale = @convention(c) (Int32, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        ?? dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)
    private static let mainConnection: MainConnection? = symbol("CGSMainConnectionID")
    private static let getScale: GetScale? = symbol("CGSGetCursorScale")
    private static let setScale: SetScale? = symbol("CGSSetCursorScale")

    static func current() -> Float? {
        guard let connection = mainConnection?(), let get = getScale else { return nil }
        var scale: Float = 1
        guard get(connection, &scale) == 0 else { return nil }
        return scale
    }

    static func set(_ scale: Float) {
        guard let connection = mainConnection?(), let set = setScale else { return }
        _ = set(connection, scale)
    }

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
