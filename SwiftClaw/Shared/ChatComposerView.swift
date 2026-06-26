import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct ChatComposerSubmission {
    let text: String
    let model: String
    let isInvestigationEnabled: Bool
    let reasoningEffort: ModelReasoningEffort?
    let imageAttachments: [ImageAttachmentRecord]
    let supportsImages: Bool
}

struct ChatComposerView: View {
    private let controlRowHeight: CGFloat = 28
    private let reasoningControlWidth: CGFloat = 92
    private let modelControlWidth: CGFloat = 132

    var isBusy = false
    var submissionError: String?
    var allowsImageAttachments = true

    /// Called with the message text, model selection, per-message toggles, and
    /// any finalized-ready draft image attachments.
    var onSubmit: (ChatComposerSubmission) -> Bool

    @AppStorage(SettingsKeys.homeModel) private var selectedModel = ""
    @AppStorage(SettingsKeys.homeReasoningEffort)
    private var selectedReasoningEffortRaw = ModelReasoningEffort.off.rawValue
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""
    @AppStorage(SettingsKeys.webSearchEnabled)
    private var webSearchEnabled = SettingsStorage.defaultWebSearchEnabled
    @AppStorage(SettingsKeys.investigationEnabled)
    private var investigationToolEnabled = SettingsStorage.defaultInvestigationEnabled

    @State private var messageText = ""
    @State private var imageAttachments: [ImageAttachmentRecord] = []
    @State private var imageAttachmentError: String?
    @State private var isImageDropTargeted = false
    @State private var previewSelection: ImageAttachmentPreviewSelection?
    @State private var availableModels = SettingsStorage.loadAvailableModels()
    @State private var isInvestigationEnabled = false
    @State private var isInvestigationAvailable = InvestigateTool().isConfigured
    @FocusState private var isMessageFieldFocused: Bool

    private var activeModelSelection: String {
        selectedModel
    }

    private var selectedReasoningEffort: ModelReasoningEffort {
        guard selectedModelSupportsReasoning else {
            return .off
        }

        return ModelReasoningEffort(rawValue: selectedReasoningEffortRaw) ?? .off
    }

    private var selectedModelCapabilities: Set<ModelCapability> {
        guard let effectiveModel else {
            return ModelCapability.defaultCapabilities
        }

        return SettingsStorage.capabilities(for: effectiveModel)
    }

    private var selectedModelSupportsReasoning: Bool {
        selectedModelCapabilities.contains(.reasoning)
    }

    private var selectedModelSupportsTools: Bool {
        selectedModelCapabilities.contains(.tools)
    }

    private var selectedModelSupportsVision: Bool {
        selectedModelCapabilities.contains(.vision)
    }

    private var effectiveReasoningEffort: ModelReasoningEffort? {
        selectedModelSupportsReasoning ? selectedReasoningEffort : nil
    }

    private var selectedModelTitle: String {
        guard !availableModels.isEmpty else {
            return "(N/A)"
        }

        if activeModelSelection == ComposerModelSelection.swiftModel, isSwiftModelAvailable {
            return "Swift Model"
        }

        if activeModelSelection == ComposerModelSelection.clawModel, isClawModelAvailable {
            return "Claw Model"
        }

        return effectiveModel ?? availableModels[0]
    }

    private var effectiveModel: String? {
        if activeModelSelection == ComposerModelSelection.swiftModel {
            return isSwiftModelAvailable ? swiftModel : nil
        }

        if activeModelSelection == ComposerModelSelection.clawModel {
            return isClawModelAvailable ? clawModel : nil
        }

        if !activeModelSelection.isEmpty, availableModels.contains(activeModelSelection) {
            return activeModelSelection
        }

        if !swiftModel.isEmpty, availableModels.contains(swiftModel) {
            return swiftModel
        }

        return availableModels.first
    }

    private var modelSelectionDisabled: Bool {
        availableModels.isEmpty || isBusy
    }

    private var composerControlsDisabled: Bool {
        availableModels.isEmpty || isBusy || effectiveModel == nil
    }

    private var canImportImageAttachments: Bool {
        allowsImageAttachments && !composerControlsDisabled && selectedModelSupportsVision
    }

    private var canSubmitMessage: Bool {
        !composerControlsDisabled && !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSwiftModelAvailable: Bool {
        !swiftModel.isEmpty && availableModels.contains(swiftModel)
    }

    private var isClawModelAvailable: Bool {
        !clawModel.isEmpty && availableModels.contains(clawModel)
    }

    private var canEnableInvestigation: Bool {
        isInvestigationToolEnabled
            && isInvestigationAvailable
            && selectedModelSupportsTools
            && selectedModelSupportsReasoning
            && selectedReasoningEffort.isReasoningEnabled
    }

    private var isInvestigationToolEnabled: Bool {
        webSearchEnabled && investigationToolEnabled
    }

    private var quickModelOptions: [ComposerModelOption] {
        var options: [ComposerModelOption] = []

        if isSwiftModelAvailable {
            options.append(ComposerModelOption(title: "Swift Model", selection: ComposerModelSelection.swiftModel))
        }

        if isClawModelAvailable {
            options.append(ComposerModelOption(title: "Claw Model", selection: ComposerModelSelection.clawModel))
        }

        return options
    }

    private var isQuickModelSelection: Bool {
        activeModelSelection == ComposerModelSelection.swiftModel || activeModelSelection == ComposerModelSelection.clawModel
    }

    private var modelSelectionMenu: some View {
        Menu {
            ForEach(quickModelOptions) { option in
                Button {
                    selectedModel = option.selection
                } label: {
                    if activeModelSelection == option.selection {
                        Label(option.title, systemImage: "checkmark")
                    } else {
                        Text(option.title)
                    }
                }
            }

            if !quickModelOptions.isEmpty {
                Divider()
            }

            ForEach(availableModels, id: \.self) { model in
                Button {
                    selectedModel = model
                } label: {
                    if !isQuickModelSelection, model == effectiveModel {
                        Label(model, systemImage: "checkmark")
                    } else {
                        Text(model)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedModelTitle)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(width: modelControlWidth, height: controlRowHeight, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuIndicator(.hidden)
        .disabled(modelSelectionDisabled)
        .frame(height: controlRowHeight, alignment: .center)
        .pointingHandCursor(isDisabled: modelSelectionDisabled)
    }

    private var reasoningMenu: some View {
        Menu {
            ForEach(ModelReasoningEffort.selectableCases) { effort in
                Button {
                    setReasoningEffort(effort)
                } label: {
                    if selectedReasoningEffort == effort {
                        Label(effort.displayName, systemImage: "checkmark")
                    } else {
                        Text(effort.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text(selectedReasoningEffort.displayName)
                    .font(.caption)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
            .frame(width: reasoningControlWidth, height: controlRowHeight, alignment: .center)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .menuIndicator(.hidden)
        .disabled(composerControlsDisabled || !selectedModelSupportsReasoning)
        .frame(height: controlRowHeight, alignment: .center)
        .pointingHandCursor(isDisabled: composerControlsDisabled || !selectedModelSupportsReasoning)
        .help("Reasoning effort")
        .accessibilityLabel("Reasoning effort \(selectedReasoningEffort.displayName)")
    }

    var body: some View {
        VStack(spacing: 0) {
            if allowsImageAttachments, !imageAttachments.isEmpty {
                ImageAttachmentThumbnailStrip(
                    attachments: imageAttachments,
                    onSelect: {
                        previewSelection = ImageAttachmentPreviewSelection(
                            attachments: imageAttachments,
                            initialIndex: $0
                        )
                    },
                    onRemove: removeImageAttachment
                )
                .padding(.bottom, 8)
            }

            HStack(alignment: .top, spacing: 8) {
                TextField("Message SwiftClaw...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .lineLimit(1...3)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(composerControlsDisabled)
                    .focused($isMessageFieldFocused)
                    .onKeyPress { keyPress in
                        handleKeyPress(keyPress)
                    }
            }
            .onDrop(
                of: ImageDropImporter.supportedContentTypes,
                isTargeted: $isImageDropTargeted,
                perform: handleImageDrop
            )

            Divider()
                .padding(.top, 4)

            HStack(alignment: .center) {
                HStack(spacing: 12) {
                    ComposerIconButton(
                        systemName: "paperclip",
                        size: controlRowHeight,
                        isDisabled: !canImportImageAttachments,
                        helpText: selectedModelSupportsVision ? "Attach images" : "Selected model does not support vision",
                        accessibilityLabel: "Attach images"
                    ) {
                        chooseImageAttachments()
                    }

                    if isInvestigationToolEnabled {
                        ComposerIconButton(
                            systemName: "magnifyingglass",
                            size: controlRowHeight,
                            isSelected: isInvestigationEnabled,
                            isDisabled: composerControlsDisabled || !canEnableInvestigation,
                            helpText: canEnableInvestigation
                                ? "Investigate this message in depth"
                                : "Investigation needs Brave Search plus a selected model with Tools, Reasoning, and reasoning turned on",
                            accessibilityLabel: "Investigation mode"
                        ) {
                            setInvestigation(!isInvestigationEnabled)
                        }
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    if selectedModelSupportsReasoning {
                        reasoningMenu
                    }

                    modelSelectionMenu

                    Button {
                        submitMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .composerControlHoverEffect(
                                width: controlRowHeight,
                                height: controlRowHeight,
                                isDisabled: !canSubmitMessage,
                                hoverScale: 1.08
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmitMessage)
                    .accessibilityLabel("Send message")
                }
            }
            .frame(height: controlRowHeight, alignment: .center)
            .padding(.vertical, 8)

            if let submissionError {
                Text(submissionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
            }

            if let imageAttachmentError {
                Text(imageAttachmentError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .glassEffect(in: .rect(cornerRadius: 16.0))
        .contentShape(Rectangle())
        .onDrop(
            of: ImageDropImporter.supportedContentTypes,
            isTargeted: $isImageDropTargeted,
            perform: handleImageDrop
        )
        .overlay {
            if isImageDropTargeted, canImportImageAttachments {
                imageDropTargetOverlay
            }
        }
        .background {
            ImagePasteKeyMonitor(
                isEnabled: canImportImageAttachments && isMessageFieldFocused,
                onPasteImage: pasteImagesFromClipboard
            )
            .frame(width: 0, height: 0)
        }
        .imageAttachmentPreviewOverlay(selection: $previewSelection)
        .onAppear(perform: refreshModels)
        .onDisappear {
            // Reset the transient one-shot toggle if the composer goes away.
            setInvestigation(false)
            clearDraftImageAttachments()
        }
        .onChange(of: allowsImageAttachments) { _, allowsImageAttachments in
            if !allowsImageAttachments {
                clearDraftImageAttachments()
            }
        }
        .onChange(of: effectiveModel) { _, _ in
            syncCapabilityState()
        }
        .onChange(of: webSearchEnabled) { _, _ in
            syncCapabilityState()
        }
        .onChange(of: investigationToolEnabled) { _, _ in
            syncCapabilityState()
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            refreshModels()
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNotifications.keychainDidChange)) { notification in
            guard notification.userInfo?[SettingsNotifications.changedKey] as? String == SettingsKeys.braveSearchAPIKey else {
                return
            }

            refreshModels()
        }
    }

    private var imageDropTargetOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.accentColor.opacity(0.08))

            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    Color.accentColor.opacity(0.72),
                    style: StrokeStyle(lineWidth: 2, dash: [7, 5])
                )

            Image(systemName: "photo.badge.plus")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.tint)
                .padding(14)
                .background(.regularMaterial, in: Circle())
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        }
        .allowsHitTesting(false)
    }

    private func refreshModels() {
        availableModels = SettingsStorage.loadAvailableModels()
        isInvestigationAvailable = InvestigateTool().isConfigured

        syncCapabilityState()
    }

    private func syncCapabilityState() {
        if !canEnableInvestigation {
            setInvestigation(false)
        }

        if !allowsImageAttachments || !selectedModelSupportsVision {
            clearDraftImageAttachments()
        }
    }

    /// Turns investigation mode on or off for the selected model.
    private func setInvestigation(_ enabled: Bool) {
        guard enabled != isInvestigationEnabled else {
            return
        }

        isInvestigationEnabled = enabled && canEnableInvestigation
    }

    private func setReasoningEffort(_ effort: ModelReasoningEffort) {
        guard selectedModelSupportsReasoning else {
            return
        }

        selectedReasoningEffortRaw = effort.rawValue

        if !canEnableInvestigation {
            setInvestigation(false)
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        if keyPress.key == .return {
            if keyPress.modifiers.contains(.shift) {
                messageText.append("\n")
            } else {
                submitMessage()
            }

            return .handled
        }

        if keyPress.key == "v", keyPress.modifiers.contains(.command) {
            return pasteImagesFromClipboard() ? .handled : .ignored
        }

        return .ignored
    }

    private func pasteImagesFromClipboard() -> Bool {
        guard canImportImageAttachments else {
            return false
        }

        let images = ClipboardImageImporter.imagesForPaste()
        guard !images.isEmpty else {
            return false
        }

        importImageAttachments(images)

        return true
    }

    private func handleImageDrop(_ providers: [NSItemProvider]) -> Bool {
        guard canImportImageAttachments else {
            return false
        }

        Task {
            let images = await ImageDropImporter.images(from: providers)
            guard !images.isEmpty else {
                imageAttachmentError = ImageAttachmentError.noReadableImage.localizedDescription
                return
            }

            importImageAttachments(images)
        }

        return true
    }

    private func chooseImageAttachments() {
        guard canImportImageAttachments else {
            return
        }

        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.prompt = "Attach"

        guard panel.runModal() == .OK else {
            return
        }

        let images = panel.urls.compactMap(NSImage.init(contentsOf:))
        guard !images.isEmpty, images.count == panel.urls.count else {
            imageAttachmentError = ImageAttachmentError.noReadableImage.localizedDescription
            return
        }

        importImageAttachments(images)
        #endif
    }

    private func removeImageAttachment(_ attachment: ImageAttachmentRecord) {
        imageAttachments.removeAll { $0.id == attachment.id }
        ImageAttachmentStore.shared.deleteDraftAttachments([attachment])
    }

    private func clearDraftImageAttachments() {
        ImageAttachmentStore.shared.deleteDraftAttachments(imageAttachments)
        imageAttachments = []
        imageAttachmentError = nil
        previewSelection = nil
    }

    private func importImageAttachments(_ images: [NSImage]) {
        do {
            let newAttachments = try ImageAttachmentStore.shared.importImages(
                images,
                existingAttachments: imageAttachments
            )
            imageAttachments.append(contentsOf: newAttachments)
            imageAttachmentError = nil
        } catch {
            imageAttachmentError = error.localizedDescription
        }
    }

    private func submitMessage() {
        let input = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let model = effectiveModel, !isBusy else {
            return
        }

        let attachments = allowsImageAttachments && selectedModelSupportsVision ? imageAttachments : []
        let submission = ChatComposerSubmission(
            text: input,
            model: model,
            isInvestigationEnabled: isInvestigationEnabled && canEnableInvestigation,
            reasoningEffort: effectiveReasoningEffort,
            imageAttachments: attachments,
            supportsImages: selectedModelSupportsVision
        )

        if onSubmit(submission) {
            messageText = ""
            imageAttachments = []
            imageAttachmentError = nil
            // Investigation is a one-shot toggle: it always resets after the
            // message is submitted.
            setInvestigation(false)
        }
    }
}

private struct ComposerControlHoverEffect: ViewModifier {
    let width: CGFloat
    let height: CGFloat
    var isSelected = false
    var isDisabled = false
    var cornerRadius: CGFloat = 6
    var hoverScale: CGFloat = 1.03

    @State private var isHovering = false

    private var isHoverActive: Bool {
        isHovering && !isDisabled
    }

    private var isActive: Bool {
        !isDisabled && (isHovering || isSelected)
    }

    private var fillOpacity: Double {
        if isSelected {
            return isHoverActive ? 0.26 : 0.18
        }

        return isHoverActive ? 0.12 : 0
    }

    private var strokeOpacity: Double {
        isActive ? 0.22 : 0
    }

    func body(content: Content) -> some View {
        content
            .frame(width: width, height: height, alignment: .center)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.accentColor.opacity(fillOpacity))
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.accentColor.opacity(strokeOpacity), lineWidth: 1)
            }
            .shadow(
                color: Color.accentColor.opacity(isHoverActive ? 0.14 : 0),
                radius: isHoverActive ? 6 : 0,
                x: 0,
                y: isHoverActive ? 2 : 0
            )
            .scaleEffect(isHoverActive ? hoverScale : 1)
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius))
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

private extension View {
    func composerControlHoverEffect(
        width: CGFloat,
        height: CGFloat,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        hoverScale: CGFloat = 1.03
    ) -> some View {
        modifier(
            ComposerControlHoverEffect(
                width: width,
                height: height,
                isSelected: isSelected,
                isDisabled: isDisabled,
                hoverScale: hoverScale
            )
        )
    }

    func pointingHandCursor(isDisabled: Bool = false) -> some View {
        modifier(PointingHandCursor(isDisabled: isDisabled))
    }
}

private struct PointingHandCursor: ViewModifier {
    let isDisabled: Bool

    @State private var didPushCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isInside in
                updateCursor(isInside: isInside)
            }
            .onChange(of: isDisabled) { _, isDisabled in
                if isDisabled {
                    popCursorIfNeeded()
                }
            }
            .onDisappear {
                popCursorIfNeeded()
            }
    }

    private func updateCursor(isInside: Bool) {
        #if os(macOS)
        if isInside, !isDisabled {
            guard !didPushCursor else {
                return
            }

            NSCursor.pointingHand.push()
            didPushCursor = true
        } else {
            popCursorIfNeeded()
        }
        #endif
    }

    private func popCursorIfNeeded() {
        #if os(macOS)
        guard didPushCursor else {
            return
        }

        NSCursor.pop()
        didPushCursor = false
        #endif
    }
}

private struct ComposerIconButton: View {
    let systemName: String
    let size: CGFloat
    var isSelected = false
    var isDisabled = false
    let helpText: String
    let accessibilityLabel: String
    let action: () -> Void

    private var foregroundStyle: AnyShapeStyle {
        isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .foregroundStyle(foregroundStyle)
                .composerControlHoverEffect(
                    width: size,
                    height: size,
                    isSelected: isSelected,
                    isDisabled: isDisabled,
                    hoverScale: 1.08
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .help(helpText)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sentinel selections for the composer's quick-pick model presets, persisted
/// in place of a concrete model name.
enum ComposerModelSelection {
    static let swiftModel = "settings.home.modelPreset.swift"
    static let clawModel = "settings.home.modelPreset.claw"
}

private struct ComposerModelOption: Identifiable {
    let title: String
    let selection: String

    var id: String { selection }
}
