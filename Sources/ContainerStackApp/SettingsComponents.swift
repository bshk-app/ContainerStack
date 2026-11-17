import SwiftUI

/// Palette 1c: controls and notes share one surface, separated by one-point lines.
struct SettingsRow<Content: View>: View {
    @Environment(\.appTheme) private var theme
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { theme.hairline.frame(height: 1) }
    }
}

struct SettingsHelp: View {
    let title: String
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button(title, systemImage: "questionmark.circle") { isPresented.toggle() }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .popover(isPresented: $isPresented) {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .padding(20)
                    .frame(width: 360, alignment: .leading)
            }
    }
}

struct SettingsResourceFields: View {
    let settings: ContainerResourceSettings

    var body: some View {
        VStack(spacing: 0) {
            SettingsRow {
                Stepper(
                    value: Binding(get: { settings.cpus }, set: { settings.setCPUs($0) }), in: 1...settings.maximumCPUs
                ) {
                    LabeledContent("CPUs", value: settings.cpus.formatted())
                }
            }
            SettingsRow {
                Stepper(
                    value: Binding(get: { settings.memoryGiB }, set: { settings.setMemoryGiB($0) }),
                    in: 1...settings.maximumMemoryGiB
                ) {
                    LabeledContent("Memory", value: settings.memoryDescription)
                }
            }
        }
        .disabled(settings.problem != nil)
        if let problem = settings.problem {
            Text(problem).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}
