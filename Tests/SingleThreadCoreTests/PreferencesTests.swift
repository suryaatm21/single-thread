import Testing
@testable import SingleThreadCore

@Suite("Preferences and modes")
struct PreferencesTests {
    @Test("Defaults: enabled, full mode, the six supported apps")
    func defaults() {
        let prefs = Preferences()
        #expect(prefs.enabled)
        #expect(prefs.mode == .dimBlurLabel)
        #expect(prefs.supportedBundleIDs.count == 6)
        #expect(prefs.isSupported(bundleID: "com.apple.Terminal"))
        #expect(prefs.isSupported(bundleID: "com.mitchellh.ghostty"))
        #expect(!prefs.isSupported(bundleID: "com.google.Chrome"))
        #expect(!prefs.isSupported(bundleID: nil))
    }

    @Test("Each mode maps to its visual recipe")
    func modeStyles() {
        #expect(OverlayMode.dim.style == OverlayStyle(dimAlpha: 0.55, blur: false, showLabel: false))
        #expect(OverlayMode.dimBlur.style.blur && !OverlayMode.dimBlur.style.showLabel)
        #expect(OverlayMode.dimBlurLabel.style.blur && OverlayMode.dimBlurLabel.style.showLabel)
    }

    @Test("Cycling modes wraps around")
    func cycling() {
        #expect(OverlayMode.dim.next == .dimBlur)
        #expect(OverlayMode.dimBlur.next == .dimBlurLabel)
        #expect(OverlayMode.dimBlurLabel.next == .dim)
    }

    @Test("Toggling and mode changes survive a store/load round trip")
    func roundTrip() {
        var prefs = Preferences()
        prefs.enabled.toggle()
        prefs.mode = .dim
        prefs.keepLastAgentWindowClear = false
        let loaded = Preferences(stored: prefs.storedValues)
        #expect(loaded.enabled == false)
        #expect(loaded.mode == .dim)
        #expect(loaded.keepLastAgentWindowClear == false)
    }

    @Test("Malformed stored values fall back to defaults")
    func malformed() {
        let loaded = Preferences(stored: ["mode": "sparkles", "enabled": "yes", "supportedApps": [1, 2]])
        #expect(loaded == Preferences())
    }

    @Test("The supported-app list comes from storage, and the environment overrides it")
    func appList() {
        let stored: [String: Any] = ["supportedApps": ["com.apple.Terminal", "com.example.Term"]]
        #expect(Preferences(stored: stored).supportedBundleIDs == ["com.apple.Terminal", "com.example.Term"])
        let env = Preferences(stored: stored, environmentApps: " com.apple.Terminal ,, ")
        #expect(env.supportedBundleIDs == ["com.apple.Terminal"])
        #expect(Preferences(stored: stored, environmentApps: "").supportedBundleIDs.count == 2)
    }
}
