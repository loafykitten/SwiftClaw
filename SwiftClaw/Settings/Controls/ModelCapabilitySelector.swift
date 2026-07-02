import SwiftUI

struct ModelCapabilitySelector: View {
    @Binding var capabilities: Set<ModelCapability>

    var body: some View {
        HStack(spacing: 14) {
            ForEach(ModelCapability.allCases) { capability in
                Toggle(
                    capability.displayName,
                    isOn: Binding(
                        get: {
                            capabilities.contains(capability)
                        },
                        set: { isEnabled in
                            if isEnabled {
                                capabilities.insert(capability)
                            } else {
                                capabilities.remove(capability)
                            }
                        }
                    )
                )
                .toggleStyle(.checkbox)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
