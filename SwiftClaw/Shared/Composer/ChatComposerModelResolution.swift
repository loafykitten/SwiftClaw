import Foundation

struct ChatComposerSubmission {
    let text: String
    let model: String
    let isInvestigationEnabled: Bool
    let reasoningEffort: ModelReasoningEffort?
    let imageAttachments: [ImageAttachmentRecord]
    let supportsImages: Bool
}

struct ComposerModelResolution {
    let activeSelection: String
    let availableModels: [String]
    let swiftModel: String
    let clawModel: String

    var selectedTitle: String {
        guard !availableModels.isEmpty else {
            return "(N/A)"
        }

        if activeSelection == ComposerModelSelection.swiftModel, isSwiftModelAvailable {
            return "Swift Model"
        }

        if activeSelection == ComposerModelSelection.clawModel, isClawModelAvailable {
            return "Claw Model"
        }

        return effectiveModel ?? availableModels[0]
    }

    var effectiveModel: String? {
        if activeSelection == ComposerModelSelection.swiftModel {
            return isSwiftModelAvailable ? swiftModel : nil
        }

        if activeSelection == ComposerModelSelection.clawModel {
            return isClawModelAvailable ? clawModel : nil
        }

        if !activeSelection.isEmpty, availableModels.contains(activeSelection) {
            return activeSelection
        }

        if !swiftModel.isEmpty, availableModels.contains(swiftModel) {
            return swiftModel
        }

        return availableModels.first
    }

    var isSwiftModelAvailable: Bool {
        !swiftModel.isEmpty && availableModels.contains(swiftModel)
    }

    var isClawModelAvailable: Bool {
        !clawModel.isEmpty && availableModels.contains(clawModel)
    }

    var isClawModelSelected: Bool {
        if activeSelection == ComposerModelSelection.clawModel {
            return true
        }

        guard let effectiveModel, !clawModel.isEmpty, isClawModelAvailable else {
            return false
        }

        return effectiveModel == clawModel
    }

    var quickOptions: [ComposerModelOption] {
        var options: [ComposerModelOption] = []

        if isSwiftModelAvailable {
            options.append(ComposerModelOption(title: "Swift Model", selection: ComposerModelSelection.swiftModel))
        }

        if isClawModelAvailable {
            options.append(ComposerModelOption(title: "Claw Model", selection: ComposerModelSelection.clawModel))
        }

        return options
    }
}
