import SwiftUI

struct DeepResearchSettingsView: View {
    @AppStorage(SettingsKeys.deepResearchEnabled)
    private var isDeepResearchEnabled = SettingsStorage.defaultDeepResearchEnabled
    @AppStorage(SettingsKeys.deepResearchTimeBudgetMinutes)
    private var timeBudgetMinutes = SettingsStorage.defaultDeepResearchTimeBudgetMinutes
    @AppStorage(SettingsKeys.deepResearchMaxThreads)
    private var maxThreads = SettingsStorage.defaultDeepResearchMaxThreads
    @AppStorage(SettingsKeys.deepResearchReportLength)
    private var reportLengthRaw = SettingsStorage.defaultDeepResearchReportLength.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Show Research tab", isOn: $isDeepResearchEnabled)
            }

            Section("Research Model") {
                Text("Choose the Research Model in Model Behaviors. When unset, Deep Research uses the Claw Model.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(
                    value: $timeBudgetMinutes,
                    in: SettingsStorage.deepResearchTimeBudgetMinutesRange
                ) {
                    LabeledContent("Time Budget") {
                        Text("\(timeBudgetMinutes) minutes")
                            .foregroundStyle(.secondary)
                    }
                }

                Stepper(
                    value: $maxThreads,
                    in: SettingsStorage.deepResearchMaxThreadsRange
                ) {
                    LabeledContent("Thread Cap") {
                        Text("\(maxThreads) threads")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Run Limits")
            } footer: {
                Text("Deep runs use your Brave Search and model API keys and may make up to 60 searches.")
            }

            Section {
                Picker("Report Length", selection: $reportLengthRaw) {
                    ForEach(DeepResearchReportLength.allCases) { length in
                        Text(length.displayName).tag(length.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Concise: 1–2 short paragraphs per section. Standard: 2–3. Thorough: as much detail as the evidence supports.")
            }
        }
        .formStyle(.grouped)
    }
}
