import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

struct ChatComposerSubmission {
    let text: String
    let model: String
    let isInvestigationEnabled: Bool
    let imageAttachments: [ImageAttachmentRecord]
    let supportsImages: Bool
}

struct ChatComposerView: View {
    private let controlRowHeight: CGFloat = 28

    var isBusy = false
    var submissionError: String?
    var allowsImageAttachments = true

    /// Called with the message text, model selection, per-message toggles, and
    /// any finalized-ready draft image attachments.
    var onSubmit: (ChatComposerSubmission) -> Bool

    @AppStorage(SettingsKeys.homeModel) private var selectedModel = ""
    @AppStorage(SettingsKeys.swiftModel) private var swiftModel = ""
    @AppStorage(SettingsKeys.clawModel) private var clawModel = ""

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
        isInvestigationEnabled ? HomeModelSelection.clawModel : selectedModel
    }

    private var selectedModelTitle: String {
        guard !availableModels.isEmpty else {
            return "(N/A)"
        }

        if activeModelSelection == HomeModelSelection.swiftModel, isSwiftModelAvailable {
            return "Swift Model"
        }

        if activeModelSelection == HomeModelSelection.clawModel, isClawModelAvailable {
            return "Claw Model"
        }

        return effectiveModel ?? availableModels[0]
    }

    private var effectiveModel: String? {
        if activeModelSelection == HomeModelSelection.swiftModel {
            return isSwiftModelAvailable ? swiftModel : nil
        }

        if activeModelSelection == HomeModelSelection.clawModel {
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
        // Investigation sends this message with the Claw Model, so the
        // selector locks while the one-shot toggle is on.
        availableModels.isEmpty || isBusy || isInvestigationEnabled
    }

    private var composerControlsDisabled: Bool {
        availableModels.isEmpty || isBusy || effectiveModel == nil
    }

    private var canImportImageAttachments: Bool {
        allowsImageAttachments && !composerControlsDisabled
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

    private var quickModelOptions: [HomeModelOption] {
        var options: [HomeModelOption] = []

        if isSwiftModelAvailable {
            options.append(HomeModelOption(title: "Swift Model", selection: HomeModelSelection.swiftModel))
        }

        if isClawModelAvailable {
            options.append(HomeModelOption(title: "Claw Model", selection: HomeModelSelection.clawModel))
        }

        return options
    }

    private var isQuickModelSelection: Bool {
        activeModelSelection == HomeModelSelection.swiftModel || activeModelSelection == HomeModelSelection.clawModel
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
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .menuIndicator(.hidden)
        .disabled(modelSelectionDisabled)
        .frame(height: controlRowHeight, alignment: .center)
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
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .onDrop(
                                of: ImageDropImporter.supportedContentTypes,
                                isTargeted: $isImageDropTargeted,
                                perform: handleImageDrop
                            )
                    }
            }

            Divider()
                .padding(.top, 4)

            HStack(alignment: .center) {
                HStack(spacing: 12) {
                    Button {
                        chooseImageAttachments()
                    } label: {
                        Image(systemName: "paperclip")
                            .frame(width: controlRowHeight, height: controlRowHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(composerControlsDisabled || !allowsImageAttachments)
                    .help("Attach images")
                    .accessibilityLabel("Attach images")

                    Button {
                        setInvestigation(!isInvestigationEnabled)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .frame(width: controlRowHeight, height: controlRowHeight)
                            .background {
                                if isInvestigationEnabled {
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Color.accentColor.opacity(0.18))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isInvestigationEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .disabled(composerControlsDisabled || !isInvestigationAvailable || !isClawModelAvailable)
                    .help(
                        isInvestigationAvailable && isClawModelAvailable
                            ? "Investigate this message in depth using the Claw Model"
                            : "Investigation needs a Brave Search key plus Claw and Swift Models"
                    )
                    .accessibilityLabel("Investigation mode")
                    .accessibilityAddTraits(isInvestigationEnabled ? .isSelected : [])
                }

                Spacer()

                HStack(spacing: 8) {
                    modelSelectionMenu
                        .frame(width: 160, alignment: .trailing)

                    Button {
                        submitMessage()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title2)
                            .frame(width: controlRowHeight, height: controlRowHeight)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .disabled(!canSubmitMessage)
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

        if !isInvestigationAvailable || !isClawModelAvailable {
            setInvestigation(false)
        }
    }

    /// Turns investigation mode on or off. While on, this message uses the
    /// Claw Model without changing the saved home model selection.
    private func setInvestigation(_ enabled: Bool) {
        guard enabled != isInvestigationEnabled else {
            return
        }

        isInvestigationEnabled = enabled
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

        let attachments = allowsImageAttachments ? imageAttachments : []
        let submission = ChatComposerSubmission(
            text: input,
            model: model,
            isInvestigationEnabled: isInvestigationEnabled && isInvestigationAvailable,
            imageAttachments: attachments,
            supportsImages: allowsImageAttachments
        )

        if onSubmit(submission) {
            messageText = ""
            imageAttachments = []
            imageAttachmentError = nil
            // Investigation is a one-shot toggle: it always resets (and the
            // model selector unlocks) after the message is submitted.
            setInvestigation(false)
        }
    }
}

enum HomeModelSelection {
    static let swiftModel = "settings.home.modelPreset.swift"
    static let clawModel = "settings.home.modelPreset.claw"
}

private struct HomeModelOption: Identifiable {
    let title: String
    let selection: String

    var id: String { selection }
}
