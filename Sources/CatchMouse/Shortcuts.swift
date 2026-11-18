import Carbon.HIToolbox

/// Default shortcuts and the logic that resolves a display's effective combo
/// (user-chosen binding from the store, falling back to a positional default).
///
/// Displays are ordered left → right, so default index 0 is the left-most.
enum Shortcuts {
    /// Positional defaults for the left / centre / right displays:
    /// `⌃⌘,` `⌃⌘.` `⌃⌘/` (three adjacent keys, no system-shortcut clash —
    /// macOS Help is ⇧⌘/, not ⌃⌘/).
    static let defaultJump: [KeyCombo] = [
        KeyCombo(keyCode: kVK_ANSI_Comma,  carbonModifiers: controlKey | cmdKey),
        KeyCombo(keyCode: kVK_ANSI_Period, carbonModifiers: controlKey | cmdKey),
        KeyCombo(keyCode: kVK_ANSI_Slash,  carbonModifiers: controlKey | cmdKey),
    ]
    static let defaultNext = KeyCombo(keyCode: kVK_RightArrow, carbonModifiers: controlKey | optionKey)
    static let defaultPrev = KeyCombo(keyCode: kVK_LeftArrow,  carbonModifiers: controlKey | optionKey)
    static let defaultMaximize = KeyCombo(keyCode: kVK_Return, carbonModifiers: controlKey | optionKey)
    static let defaultFullScreen = KeyCombo(keyCode: kVK_ANSI_F, carbonModifiers: controlKey | optionKey)
    static let defaultGolden = KeyCombo(keyCode: kVK_ANSI_G, carbonModifiers: controlKey | optionKey)

    /// Effective jump combo for the display at `index` (left→right): the stored
    /// per-display binding if any, otherwise the positional default (first three
    /// displays only). Returns `nil` when the user disabled it or the display
    /// has no default.
    static func jumpCombo(index: Int, displayKey: String, store: HotKeyStore) -> KeyCombo? {
        switch store.binding(forDisplay: displayKey) {
        case .bound(let combo): return combo
        case .disabled: return nil
        case .unset: return index < defaultJump.count ? defaultJump[index] : nil
        }
    }

    static func nextCombo(_ store: HotKeyStore) -> KeyCombo? { resolve(store.nextBinding(), defaultNext) }
    static func prevCombo(_ store: HotKeyStore) -> KeyCombo? { resolve(store.prevBinding(), defaultPrev) }
    static func maximizeCombo(_ store: HotKeyStore) -> KeyCombo? { resolve(store.maximizeBinding(), defaultMaximize) }
    static func fullScreenCombo(_ store: HotKeyStore) -> KeyCombo? { resolve(store.fullScreenBinding(), defaultFullScreen) }
    static func goldenCombo(_ store: HotKeyStore) -> KeyCombo? { resolve(store.goldenBinding(), defaultGolden) }

    private static func resolve(_ binding: StoredBinding, _ fallback: KeyCombo) -> KeyCombo? {
        switch binding {
        case .unset: return fallback
        case .disabled: return nil
        case .bound(let combo): return combo
        }
    }
}
