import SwiftUI

struct HomeView: View {
    @State private var messageText = ""
    @State private var selectedMode = "Chat"

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 4) {
                Image(systemName: "cat")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .foregroundStyle(Color.accentColor)

                Text("SwiftClaw")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Text("Good morning, User!")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            Text("There's no place like 127.0.0.1")
                .font(.callout)
                .italic()
                .foregroundStyle(.tertiary)
                .padding(.top, 12)

            Spacer()

            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    TextField("Message SwiftClaw...", text: $messageText)
                        .textFieldStyle(.plain)
                        .font(.body)

                    Menu {
                        Button("GLM 5.1") {}
                    } label: {
                        HStack(spacing: 4) {
                            Text("GLM 5.1")
                                .font(.caption)
                            Image(systemName: "chevron.down")
                                .font(.caption2)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .menuIndicator(.hidden)
                }

                Divider()
                    .padding(.vertical, 4)

                HStack {
                    HStack(spacing: 12) {
                        Button {} label: {
                            Image(systemName: "paperclip")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)

                        Button {} label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Picker("", selection: $selectedMode) {
                            Text("Agent").tag("Agent")
                            Text("Chat").tag("Chat")
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 130)

                        Button {} label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(16)
            .glassEffect(in: .rect(cornerRadius: 16.0))
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    HomeView()
        .frame(width: 700, height: 500)
}
