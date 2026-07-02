import SwiftUI

struct ChatComposerView: View {
    private let controlRowHeight: CGFloat = 28
    private let reasoningControlWidth: CGFloat = 92
    private let modelControlWidth: CGFloat = 132

    var isBusy = false
    var submissionError: String?
    var allowsImageAttachments = true

    var chatReasoningEffort: ModelReasoningEffort? = nil
    var onReasoningEffortChange: ((ModelReasoningEffort) -> Void)? = nil

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
    @State private var attachmentController = ImageAttachmentComposerController()
    @State private var availableModels = SettingsStorage.loadAvailableModels()
    @State private var isInvestigationEnabled = false
    @State private var isInvestigationAvailable = InvestigateTool().isConfigured
    @FocusState private var isMessageFieldFocused: Bool

    init(
        isBusy: Bool = false,
        submissionError: String? = nil,
        allowsImageAttachments: Bool = true,
        chatReasoningEffort: ModelReasoningEffort? = nil,
        onReasoningEffortChange: ((ModelReasoningEffort) -> Void)? = nil,
        onSubmit: @escaping (ChatComposerSubmission) -> Bool
    ) {
        self.isBusy = isBusy
        self.submissionError = submissionError
        self.allowsImageAttachments = allowsImageAttachments
        self.chatReasoningEffort = chatReasoningEffort
        self.onReasoningEffortChange = onReasoningEffortChange
        self.onSubmit = onSubmit
    }

    private var activeModelSelection: String {
        selectedModel
    }

    private var selectedReasoningEffort: ModelReasoningEffort {
        if let chatReasoningEffort {
            return chatReasoningEffort
        }

        return ModelReasoningEffort(rawValue: selectedReasoningEffortRaw) ?? .off
    }

    private var modelResolution: ComposerModelResolution {
        ComposerModelResolution(
            activeSelection: activeModelSelection,
            availableModels: availableModels,
            swiftModel: swiftModel,
            clawModel: clawModel
        )
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

    private var isClawModelSelected: Bool {
        modelResolution.isClawModelSelected
    }

    private var reasoningDefaultForModelChange: ModelReasoningEffort? {
        SettingsStorage.composerDefaultReasoningEffort(
            isClawModel: isClawModelSelected,
            supportsReasoning: selectedModelSupportsReasoning
        )
    }

    private var selectedModelTitle: String {
        modelResolution.selectedTitle
    }

    private var effectiveModel: String? {
        modelResolution.effectiveModel
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
        modelResolution.quickOptions
    }

    private var previewSelectionBinding: Binding<ImageAttachmentPreviewSelection?> {
        Binding(
            get: { attachmentController.previewSelection },
            set: { attachmentController.previewSelection = $0 }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            attachmentStrip
            messageInput

            Divider()
                .padding(.top, 4)

            controlRow
                .frame(height: controlRowHeight, alignment: .center)
                .padding(.vertical, 8)

            errorMessages
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .glassEffect(in: .rect(cornerRadius: 16.0))
        .contentShape(Rectangle())
        .dropDestination(for: ImageImportTransfer.self) { items, _ in
            attachmentController.importDroppedItems(items, isEnabled: canImportImageAttachments)
        } isTargeted: { isTargeted in
            attachmentController.setDropTargeted(isTargeted, isEnabled: canImportImageAttachments)
        }
        .overlay {
            if attachmentController.isDropTargeted, canImportImageAttachments {
                ComposerDropTargetOverlay()
            }
        }
        .imageAttachmentPreviewOverlay(selection: previewSelectionBinding)
        .onAppear(perform: refreshModels)
        .onDisappear {
            setInvestigation(false)
            attachmentController.clearDraftAttachments()
        }
        .onChange(of: allowsImageAttachments) { _, allowsImageAttachments in
            if !allowsImageAttachments {
                attachmentController.clearDraftAttachments()
            }
        }
        .onChange(of: effectiveModel) { _, _ in
            syncCapabilityState()
        }
        .onChange(of: activeModelSelection) { _, _ in
            applyReasoningDefaultForModelChange()
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

    @ViewBuilder
    private var attachmentStrip: some View {
        if allowsImageAttachments, !attachmentController.attachments.isEmpty {
            ImageAttachmentThumbnailStrip(
                attachments: attachmentController.attachments,
                onSelect: attachmentController.selectPreview,
                onRemove: attachmentController.removeAttachment
            )
            .padding(.bottom, 8)
        }
    }

    private var messageInput: some View {
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
    }

    private var controlRow: some View {
        HStack(alignment: .center) {
            HStack(spacing: 12) {
                ComposerIconButton(
                    systemName: "paperclip",
                    size: controlRowHeight,
                    isDisabled: !canImportImageAttachments,
                    helpText: selectedModelSupportsVision ? "Attach images" : "Selected model does not support vision",
                    accessibilityLabel: "Attach images"
                ) {
                    attachmentController.chooseImageAttachments(isEnabled: canImportImageAttachments)
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
                    ComposerReasoningMenu(
                        selectedReasoningEffort: selectedReasoningEffort,
                        width: reasoningControlWidth,
                        height: controlRowHeight,
                        isDisabled: composerControlsDisabled || !selectedModelSupportsReasoning,
                        onSelect: setReasoningEffort
                    )
                }

                ComposerModelSelectionMenu(
                    selectedModelTitle: selectedModelTitle,
                    activeModelSelection: activeModelSelection,
                    effectiveModel: effectiveModel,
                    availableModels: availableModels,
                    quickModelOptions: quickModelOptions,
                    width: modelControlWidth,
                    height: controlRowHeight,
                    isDisabled: modelSelectionDisabled
                ) { selection in
                    selectedModel = selection
                }

                ComposerSendButton(
                    size: controlRowHeight,
                    isDisabled: !canSubmitMessage,
                    action: submitMessage
                )
            }
        }
    }

    @ViewBuilder
    private var errorMessages: some View {
        if let submissionError {
            Text(submissionError)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
        }

        if let imageAttachmentError = attachmentController.errorMessage {
            Text(imageAttachmentError)
                .font(.caption)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 10)
        }
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
            attachmentController.clearDraftAttachments()
        }
    }

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

        if let onReasoningEffortChange {
            onReasoningEffortChange(effort)
        } else {
            selectedReasoningEffortRaw = effort.rawValue
        }

        if !canEnableInvestigation {
            setInvestigation(false)
        }
    }

    private func applyReasoningDefaultForModelChange() {
        guard let effort = reasoningDefaultForModelChange else {
            return
        }

        setReasoningEffort(effort)
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
            return attachmentController.pasteImagesFromClipboard(isEnabled: canImportImageAttachments)
                ? .handled
                : .ignored
        }

        return .ignored
    }

    private func submitMessage() {
        let input = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, let model = effectiveModel, !isBusy else {
            return
        }

        let attachments = allowsImageAttachments && selectedModelSupportsVision
            ? attachmentController.attachments
            : []
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
            attachmentController.releaseSubmittedAttachments()
            setInvestigation(false)
        }
    }
}
