//
//  SettingsStore+LargeDictationOverlay.swift
//  Fluid
//
//  Fork-local settings for the large, screen-filling live dictation overlay.
//  Kept in its own file so upstream merges into SettingsStore.swift stay clean.
//

import Foundation

extension SettingsStore {
    static let largeDictationOverlayScreenFractionRange: ClosedRange<Double> = 0.3...0.95
    static let largeDictationOverlayFontSizeRange: ClosedRange<Double> = 24...96
    static let largeDictationOverlayOpacityRange: ClosedRange<Double> = 0.4...0.95

    static let defaultLargeDictationOverlayScreenFraction = 0.6
    static let defaultLargeDictationOverlayFontSize = 44.0
    static let defaultLargeDictationOverlayOpacity = 0.78

    static let largeDictationOverlayChangedNotification = NSNotification.Name("LargeDictationOverlayChanged")

    private enum LargeDictationOverlayKeys {
        static let enabled = "LargeDictationOverlayEnabled"
        static let screenFraction = "LargeDictationOverlayScreenFraction"
        static let fontSize = "LargeDictationOverlayFontSize"
        static let opacity = "LargeDictationOverlayOpacity"
    }

    /// Shows live dictation in a large, centered HUD in addition to the normal pill or notch.
    var largeDictationOverlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: LargeDictationOverlayKeys.enabled) }
        set {
            guard newValue != self.largeDictationOverlayEnabled else { return }
            objectWillChange.send()
            UserDefaults.standard.set(newValue, forKey: LargeDictationOverlayKeys.enabled)
            NotificationCenter.default.post(name: Self.largeDictationOverlayChangedNotification, object: nil)
        }
    }

    /// Fraction of the screen's width and height the overlay occupies.
    var largeDictationOverlayScreenFraction: Double {
        get {
            self.largeDictationOverlayValue(
                forKey: LargeDictationOverlayKeys.screenFraction,
                default: Self.defaultLargeDictationOverlayScreenFraction,
                range: Self.largeDictationOverlayScreenFractionRange
            )
        }
        set {
            self.setLargeDictationOverlayValue(
                newValue,
                forKey: LargeDictationOverlayKeys.screenFraction,
                range: Self.largeDictationOverlayScreenFractionRange
            )
        }
    }

    /// Point size of the overlay's text.
    var largeDictationOverlayFontSize: Double {
        get {
            self.largeDictationOverlayValue(
                forKey: LargeDictationOverlayKeys.fontSize,
                default: Self.defaultLargeDictationOverlayFontSize,
                range: Self.largeDictationOverlayFontSizeRange
            )
        }
        set {
            self.setLargeDictationOverlayValue(
                newValue,
                forKey: LargeDictationOverlayKeys.fontSize,
                range: Self.largeDictationOverlayFontSizeRange
            )
        }
    }

    /// Opacity of the gray background (text always stays fully opaque).
    var largeDictationOverlayOpacity: Double {
        get {
            self.largeDictationOverlayValue(
                forKey: LargeDictationOverlayKeys.opacity,
                default: Self.defaultLargeDictationOverlayOpacity,
                range: Self.largeDictationOverlayOpacityRange
            )
        }
        set {
            self.setLargeDictationOverlayValue(
                newValue,
                forKey: LargeDictationOverlayKeys.opacity,
                range: Self.largeDictationOverlayOpacityRange
            )
        }
    }

    private func largeDictationOverlayValue(forKey key: String, default defaultValue: Double, range: ClosedRange<Double>) -> Double {
        guard let stored = UserDefaults.standard.object(forKey: key) as? NSNumber else { return defaultValue }
        let value = stored.doubleValue
        return value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : defaultValue
    }

    private func setLargeDictationOverlayValue(_ newValue: Double, forKey key: String, range: ClosedRange<Double>) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, range.lowerBound), range.upperBound)
        objectWillChange.send()
        UserDefaults.standard.set(clamped, forKey: key)
        NotificationCenter.default.post(name: Self.largeDictationOverlayChangedNotification, object: nil)
    }
}
