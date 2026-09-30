//
//  LargeDictationOverlay.swift
//  Fluid
//
//  Fork-local feature: a large, semi-transparent HUD that shows live dictation
//  in the middle of the screen. It runs alongside the normal pill/notch overlay
//  and reads the same shared transcription state, so upstream overlay code only
//  needs a few one-line hooks (see NotchOverlayManager).
//

import AppKit
import Combine
import SwiftUI

// MARK: - Controller

@MainActor
final class LargeDictationOverlayController {
    static let shared = LargeDictationOverlayController()

    private static let fadeInDuration: TimeInterval = 0.16
    private static let fadeOutDuration: TimeInterval = 0.12
    private static let previewDuration: TimeInterval = 4

    private let model = LargeDictationOverlayModel()
    private var panel: NSPanel?
    private var isPresented = false
    private var hideGeneration: UInt64 = 0
    private var previewHideWorkItem: DispatchWorkItem?

    private init() {
        NotificationCenter.default.addObserver(
            forName: SettingsStore.largeDictationOverlayChangedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.settingsDidChange()
            }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isPresented else { return }
                self.positionPanel(on: self.panel?.screen)
            }
        }
    }

    /// Shows the overlay for a live recording. No-op when the setting is off.
    func show() {
        guard SettingsStore.shared.largeDictationOverlayEnabled else { return }
        self.cancelPreviewTimer()
        self.model.previewText = nil
        self.present()
    }

    /// Shows the overlay with sample text so the user can judge size and opacity.
    func showPreview() {
        guard !self.isPresented || self.model.previewText != nil else { return }
        self.model.previewText = LargeDictationOverlayModel.samplePreviewText
        self.present()

        self.cancelPreviewTimer()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.model.previewText != nil else { return }
                self.hide()
            }
        }
        self.previewHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.previewDuration, execute: workItem)
    }

    func hide() {
        guard self.isPresented, let panel = self.panel else { return }
        self.cancelPreviewTimer()
        self.isPresented = false
        self.hideGeneration &+= 1
        let generation = self.hideGeneration

        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.hideGeneration == generation, !self.isPresented else { return }
                panel.orderOut(nil)
                self.model.previewText = nil
            }
        }
    }

    func hideImmediately() {
        guard self.isPresented || self.panel?.isVisible == true else { return }
        self.cancelPreviewTimer()
        self.isPresented = false
        self.hideGeneration &+= 1
        self.panel?.alphaValue = 0
        self.panel?.orderOut(nil)
        self.model.previewText = nil
    }

    // MARK: Private

    private func present() {
        let panel = self.panel ?? self.makePanel()
        self.panel = panel
        self.hideGeneration &+= 1

        self.positionPanel(on: OverlayScreenResolver.screenForCurrentPointer())

        let wasPresented = self.isPresented
        self.isPresented = true
        guard !wasPresented || panel.alphaValue < 1 else { return }

        if !panel.isVisible {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1
        }
    }

    private func settingsDidChange() {
        guard self.isPresented else { return }
        if SettingsStore.shared.largeDictationOverlayEnabled || self.model.previewText != nil {
            self.positionPanel(on: self.panel?.screen)
        } else {
            self.hide()
        }
    }

    private func cancelPreviewTimer() {
        self.previewHideWorkItem?.cancel()
        self.previewHideWorkItem = nil
    }

    private func positionPanel(on screen: NSScreen?) {
        guard let panel = self.panel,
              let screen = screen ?? NSScreen.main ?? NSScreen.screens.first
        else { return }

        let visible = screen.visibleFrame
        let fraction = CGFloat(SettingsStore.shared.largeDictationOverlayScreenFraction)
        let size = NSSize(
            width: (visible.width * fraction).rounded(),
            height: (visible.height * fraction).rounded()
        )
        let origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.invalidateShadow()
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        // One step below the pill/notch so they stay on top if the two overlap.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true // Clicks pass straight through to the app underneath.
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: LargeDictationOverlayView(model: self.model))
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear
        panel.contentView = hostingView

        return panel
    }
}

// MARK: - Model

@MainActor
final class LargeDictationOverlayModel: ObservableObject {
    static let samplePreviewText = "This is how your live dictation will look. "
        + "Words appear here as you speak, and older lines scroll up and fade out "
        + "so the most recent sentence always sits right in front of you."

    @Published var previewText: String?
}

// MARK: - View

struct LargeDictationOverlayView: View {
    @ObservedObject var model: LargeDictationOverlayModel
    @ObservedObject private var content = NotchContentState.shared
    @ObservedObject private var settings = SettingsStore.shared

    private static let statusTexts: Set<String> = [
        "Transcribing", "Refining", "Thinking", "Working",
        "Transcribing...", "Refining...", "Thinking...", "Working...", "Reprocessing...",
    ]

    private static let cornerRadius: CGFloat = 26

    private var fontSize: CGFloat {
        CGFloat(self.settings.largeDictationOverlayFontSize)
    }

    private var trimmedTranscript: String {
        self.content.transcriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var statusText: String? {
        if self.model.previewText != nil { return "Preview" }
        if Self.statusTexts.contains(self.trimmedTranscript) { return self.trimmedTranscript }
        if self.content.isProcessing { return "Processing..." }
        return nil
    }

    private var bodyText: String {
        if let preview = self.model.previewText { return preview }
        let transcript = self.trimmedTranscript
        return Self.statusTexts.contains(transcript) ? "" : transcript
    }

    var body: some View {
        ZStack {
            self.background
            VStack(alignment: .leading, spacing: self.fontSize * 0.4) {
                self.header
                self.transcript
            }
            .padding(.horizontal, self.fontSize * 1.1)
            .padding(.vertical, self.fontSize * 0.8)
        }
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .environment(\.colorScheme, .dark)
    }

    private var background: some View {
        ZStack {
            LargeDictationOverlayBlurView()
                .opacity(self.settings.largeDictationOverlayOpacity)
            Color(white: 0.13)
                .opacity(self.settings.largeDictationOverlayOpacity * 0.7)
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(self.statusText == nil ? Color.red : Color.white.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(self.statusText ?? "Listening")
                .font(.system(size: 13, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Color.white.opacity(0.6))
                .textCase(.uppercase)
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    /// Text is bottom-anchored and clipped at the top, so the newest words stay
    /// in view and older lines scroll up and fade out like a teleprompter.
    private var transcript: some View {
        ZStack(alignment: .bottomLeading) {
            if self.bodyText.isEmpty {
                Text(self.content.isProcessing ? "" : "Start speaking...")
                    .foregroundStyle(Color.white.opacity(0.35))
            } else {
                Text(self.bodyText)
                    .foregroundStyle(Color.white)
            }
        }
        .font(.system(size: self.fontSize, weight: .medium))
        .lineSpacing(self.fontSize * 0.18)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black, location: 0.18),
                    .init(color: .black, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

/// Standard macOS HUD blur (the same material as system volume/brightness HUDs).
private struct LargeDictationOverlayBlurView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active // Panels never become key; keep the blur live anyway.
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
