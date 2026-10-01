//
//  LargeDictationOverlaySettingsSection.swift
//  Fluid
//
//  Fork-local settings rows for the large live dictation overlay.
//  Embedded in the Overlay card of SettingsView with a single line.
//

import SwiftUI

struct LargeDictationOverlaySettingsSection: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var settings = SettingsStore.shared

    let titleColor: Color
    let secondaryColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Large Dictation Overlay")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.titleColor)
                    Text("Show live dictation in a large box in the middle of the screen, in place of the pill")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.secondaryColor)
                }

                Spacer()

                Toggle("", isOn: self.$settings.largeDictationOverlayEnabled)
                    .labelsHidden()
            }

            if self.settings.largeDictationOverlayEnabled {
                if !self.settings.enableStreamingPreview {
                    Text("Turn on Live Preview above to see words as you speak.")
                        .font(.fluidSystem(.caption))
                        .foregroundStyle(Color.orange)
                }

                self.sliderRow(
                    title: "Size",
                    value: self.$settings.largeDictationOverlayScreenFraction,
                    range: SettingsStore.largeDictationOverlayScreenFractionRange,
                    step: 0.05,
                    label: "\(Int((self.settings.largeDictationOverlayScreenFraction * 100).rounded()))% of screen"
                )

                self.sliderRow(
                    title: "Text Size",
                    value: self.$settings.largeDictationOverlayFontSize,
                    range: SettingsStore.largeDictationOverlayFontSizeRange,
                    step: 2,
                    label: "\(Int(self.settings.largeDictationOverlayFontSize)) pt"
                )

                self.sliderRow(
                    title: "Background",
                    value: self.$settings.largeDictationOverlayOpacity,
                    range: SettingsStore.largeDictationOverlayOpacityRange,
                    step: 0.05,
                    label: "\(Int((self.settings.largeDictationOverlayOpacity * 100).rounded()))% opaque"
                )

                HStack {
                    Spacer()
                    Button("Reset") {
                        self.settings.largeDictationOverlayScreenFraction = SettingsStore.defaultLargeDictationOverlayScreenFraction
                        self.settings.largeDictationOverlayFontSize = SettingsStore.defaultLargeDictationOverlayFontSize
                        self.settings.largeDictationOverlayOpacity = SettingsStore.defaultLargeDictationOverlayOpacity
                    }
                    .fluidOutlinedButton()
                    .controlSize(.small)

                    Button("Preview") {
                        LargeDictationOverlayController.shared.showPreview()
                    }
                    .fluidOutlinedButton()
                    .controlSize(.small)
                }
            }
        }
    }

    private func sliderRow(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        label: String
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.fluidSystem(.caption))
                .foregroundStyle(self.secondaryColor)
                .frame(width: 80, alignment: .leading)

            Slider(value: value, in: range, step: step)
                .controlSize(.regular)

            Text(label)
                .font(.fluidSystem(.caption, design: .monospaced))
                .foregroundStyle(self.secondaryColor)
                .frame(width: 110, alignment: .trailing)
        }
    }
}
