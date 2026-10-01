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

    private static let controlsInset: CGFloat = 14

    private let model = LargeDictationOverlayModel()
    private var panel: NSPanel?
    /// Small clickable child panel for the close/retry buttons. The main panel stays
    /// click-through so the big HUD never blocks the app underneath.
    private var controlsPanel: NSPanel?
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

    var isVisible: Bool { self.isPresented }

    /// Cancels an in-progress recording (discarding it) or dismisses the overlay,
    /// e.g. when it was left up after an AI enhancement failure.
    func cancel() {
        let content = NotchContentState.shared
        let isPreview = self.model.previewText != nil
        if !isPreview {
            content.clearAIProcessingFailure()
            content.clearTextDeliveryFailure()
            content.onCancelRequested?()
            NotchOverlayManager.shared.hide()
        }
        self.hide()
    }

    func retryAIProcessing() {
        let content = NotchContentState.shared
        content.clearAIProcessingFailure()
        content.onReprocessLastRequested?()
    }

    /// When on, the large overlay stands in for the pill/notch. Command mode keeps
    /// the pill because its expanded output and actions live there.
    func replacesPill(for mode: OverlayMode) -> Bool {
        SettingsStore.shared.largeDictationOverlayEnabled && mode != .command
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

        let controlsPanel = self.controlsPanel
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
            controlsPanel?.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor [weak self] in
                guard let self, self.hideGeneration == generation, !self.isPresented else { return }
                controlsPanel?.orderOut(nil)
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
        self.controlsPanel?.alphaValue = 0
        self.controlsPanel?.orderOut(nil)
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
            self.controlsPanel?.alphaValue = 0
        }
        panel.orderFrontRegardless()
        self.controlsPanel?.orderFrontRegardless()
        panel.invalidateShadow()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            panel.animator().alphaValue = 1
            self.controlsPanel?.animator().alphaValue = 1
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
        self.positionControlsPanel()
    }

    /// Pins the controls to the overlay's top-right corner, sized to fit the buttons.
    private func positionControlsPanel() {
        guard let panel = self.panel, let controlsPanel = self.controlsPanel,
              let contentView = controlsPanel.contentView
        else { return }
        let size = contentView.fittingSize
        let frame = panel.frame
        let origin = NSPoint(
            x: (frame.maxX - Self.controlsInset - size.width).rounded(),
            y: (frame.maxY - Self.controlsInset - size.height).rounded()
        )
        controlsPanel.setFrame(NSRect(origin: origin, size: size), display: true)
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

        let controlsPanel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        controlsPanel.isFloatingPanel = true
        controlsPanel.level = panel.level
        controlsPanel.collectionBehavior = panel.collectionBehavior
        controlsPanel.isOpaque = false
        controlsPanel.backgroundColor = .clear
        controlsPanel.hasShadow = false
        controlsPanel.hidesOnDeactivate = false
        controlsPanel.animationBehavior = .none
        let controlsView = LargeDictationOverlayControlsHostingView(
            rootView: LargeDictationOverlayControlsView(model: self.model) { [weak self] in
                // Button content changes size (Retry appears/disappears); keep it pinned.
                self?.positionControlsPanel()
            }
        )
        controlsView.sizingOptions = [.intrinsicContentSize]
        controlsPanel.contentView = controlsView
        panel.addChildWindow(controlsPanel, ordered: .above)
        self.controlsPanel = controlsPanel

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
        if self.content.isAIProcessingFailureVisible && !self.content.isProcessing {
            return self.content.aiProcessingFailureMessage
        }
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

// MARK: - Controls

/// Lets the close button respond to the first click without activating FluidVoice.
private final class LargeDictationOverlayControlsHostingView: NSHostingView<LargeDictationOverlayControlsView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct LargeDictationOverlayControlsView: View {
    @ObservedObject var model: LargeDictationOverlayModel
    @ObservedObject private var content = NotchContentState.shared
    let onLayoutChange: () -> Void

    private var showsRetry: Bool {
        self.model.previewText == nil
            && self.content.isAIProcessingFailureVisible
            && self.content.canRetryAIProcessingFailure
            && !self.content.isProcessing
    }

    var body: some View {
        HStack(spacing: 8) {
            if self.showsRetry {
                LargeDictationOverlayControlButton(systemImage: "arrow.clockwise", label: "Retry") {
                    LargeDictationOverlayController.shared.retryAIProcessing()
                }
                .help("Try AI enhancement again")
            }
            LargeDictationOverlayControlButton(systemImage: "xmark", label: nil) {
                LargeDictationOverlayController.shared.cancel()
            }
            .help(self.content.isProcessing ? "Close overlay" : "Cancel dictation and close")
            .accessibilityLabel("Cancel dictation")
        }
        .padding(2)
        .fixedSize()
        .environment(\.colorScheme, .dark)
        .onChange(of: self.showsRetry) { _, _ in
            DispatchQueue.main.async { self.onLayoutChange() }
        }
    }
}

private struct LargeDictationOverlayControlButton: View {
    let systemImage: String
    let label: String?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 5) {
                Image(systemName: self.systemImage)
                    .font(.system(size: 12, weight: .bold))
                if let label {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .foregroundStyle(Color.white.opacity(self.isHovering ? 1 : 0.8))
            .padding(.horizontal, self.label == nil ? 0 : 10)
            .frame(minWidth: 28, minHeight: 28)
            .background(
                Capsule().fill(Color.white.opacity(self.isHovering ? 0.25 : 0.14))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovering = $0 }
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
