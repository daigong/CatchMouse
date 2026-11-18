import Foundation

/// How a shortcut is stored: never configured (use the default), explicitly
/// cleared (the action has no hotkey), or a user-chosen combo.
enum StoredBinding {
    case unset
    case disabled
    case bound(KeyCombo)
}

/// Persists user-chosen shortcuts in `UserDefaults`.
///
/// Per-display bindings are keyed by a stable display UUID (see
/// `DisplayManager.stableKey`) so they survive reconnects and reordering.
/// Clearing a binding stores an explicit `null`, which disables the shortcut
/// instead of reverting to the default; removing the stored value (Reset to
/// Defaults) restores the defaults.
final class HotKeyStore {
    static let shared = HotKeyStore()

    private struct SingleBinding: Codable {
        var combo: KeyCombo?
    }

    private let defaults = UserDefaults.standard
    private let perDisplayKey = "perDisplayBindings.v1"
    private let nextKey = "nextBinding.v1"
    private let prevKey = "prevBinding.v1"
    private let maximizeKey = "maximizeBinding.v1"
    private let fullScreenKey = "fullScreenBinding.v1"
    private let goldenKey = "goldenBinding.v1"

    // MARK: - Per-display bindings

    private func perDisplayMap() -> [String: KeyCombo?] {
        guard let data = defaults.data(forKey: perDisplayKey) else { return [:] }
        if let map = try? JSONDecoder().decode([String: KeyCombo?].self, from: data) { return map }
        if let legacy = try? JSONDecoder().decode([String: KeyCombo].self, from: data) { return legacy }
        return [:]
    }

    func binding(forDisplay key: String) -> StoredBinding {
        guard let stored = perDisplayMap()[key] else { return .unset }
        guard let combo = stored else { return .disabled }
        return .bound(combo)
    }

    func setBinding(_ combo: KeyCombo?, forDisplay key: String) {
        var map = perDisplayMap()
        map.updateValue(combo, forKey: key)   // nil stores an explicit null
        if let data = try? JSONEncoder().encode(map) { defaults.set(data, forKey: perDisplayKey) }
    }

    // MARK: - Cycle and window bindings

    private func binding(forKey key: String) -> StoredBinding {
        guard let data = defaults.data(forKey: key) else { return .unset }
        // Legacy data is a bare KeyCombo; new data is a SingleBinding wrapper
        // that can also represent an explicit null.
        if let legacy = try? JSONDecoder().decode(KeyCombo.self, from: data) {
            return .bound(legacy)
        }
        if let stored = try? JSONDecoder().decode(SingleBinding.self, from: data) {
            guard let combo = stored.combo else { return .disabled }
            return .bound(combo)
        }
        return .unset
    }

    private func setBinding(_ combo: KeyCombo?, forKey key: String) {
        guard let data = try? JSONEncoder().encode(SingleBinding(combo: combo)) else { return }
        defaults.set(data, forKey: key)
    }

    func nextBinding() -> StoredBinding { binding(forKey: nextKey) }
    func prevBinding() -> StoredBinding { binding(forKey: prevKey) }
    func maximizeBinding() -> StoredBinding { binding(forKey: maximizeKey) }
    func fullScreenBinding() -> StoredBinding { binding(forKey: fullScreenKey) }
    func goldenBinding() -> StoredBinding { binding(forKey: goldenKey) }
    func setNext(_ combo: KeyCombo?) { setBinding(combo, forKey: nextKey) }
    func setPrev(_ combo: KeyCombo?) { setBinding(combo, forKey: prevKey) }
    func setMaximize(_ combo: KeyCombo?) { setBinding(combo, forKey: maximizeKey) }
    func setFullScreen(_ combo: KeyCombo?) { setBinding(combo, forKey: fullScreenKey) }
    func setGolden(_ combo: KeyCombo?) { setBinding(combo, forKey: goldenKey) }

    // MARK: - Reset

    func resetAll() {
        defaults.removeObject(forKey: perDisplayKey)
        defaults.removeObject(forKey: nextKey)
        defaults.removeObject(forKey: prevKey)
        defaults.removeObject(forKey: maximizeKey)
        defaults.removeObject(forKey: fullScreenKey)
        defaults.removeObject(forKey: goldenKey)
    }
}
