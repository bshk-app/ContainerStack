import SwiftUI

struct WelcomeView<Controls: View>: View {
    let session: WelcomeSession
    @ViewBuilder let controls: (WelcomeStep) -> Controls
    let openLocation: (WelcomeStep) -> Void
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    private var theme: AppTheme { .resolve(scheme) }
    private var surface: Color { scheme == .dark ? Color(uiHex: 0x1E1E1E) : .white }
    private var card: Color { scheme == .dark ? Color(uiHex: 0x262628) : Color(uiHex: 0xF5F5F7) }
    private var newIDs: Set<String> { Set(session.policy.newSteps.map(\.id)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar.frame(width: 216)
                Rectangle().fill(theme.hairline).frame(width: 1)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            Rectangle().fill(theme.hairline).frame(height: 1)
            footer.frame(height: 51)
        }
        .frame(width: 760, height: 520)
        .background(surface)
        .foregroundStyle(theme.textPrimary)
        .environment(\.appTheme, theme)
        .navigationTitle(session.title)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("EXPLORE CONTAINERSTACK")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 12)
            VStack(spacing: 4) {
                ForEach(Array(session.policy.orderedSteps.enumerated()), id: \.element.id) { index, step in
                    stepButton(step, number: index + 1)
                }
            }
            Spacer(minLength: 12)
            Text("Open this again from Help › Welcome to ContainerStack.")
                .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                .padding(.horizontal, 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 22)
    }

    private func stepButton(_ step: WelcomeStep, number: Int) -> some View {
        Button {
            session.select(step.id)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle().strokeBorder(theme.hairline, lineWidth: 1)
                    if session.visited.contains(step.id) {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .semibold))
                    } else {
                        Text(number.formatted()).font(.system(size: 10, weight: .medium))
                    }
                }.frame(width: 18, height: 18)
                Text(step.short).font(.system(size: 12)).lineLimit(1)
                Spacer(minLength: 0)
                if newIDs.contains(step.id) { newBadge("New") }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(session.selectedID == step.id ? theme.subtleFill : .clear, in: .rect(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(number). \(step.short)\(newIDs.contains(step.id) ? ", New" : "")")
        .accessibilityAddTraits(session.selectedID == step.id ? .isSelected : [])
    }

    private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                controls(session.selected)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(card, in: .rect(cornerRadius: 10))
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(theme.hairline, lineWidth: 1) }
                    .id(session.selectedID)
                if newIDs.contains(session.selectedID) {
                    newBadge("New in \(session.selected.introduced(in: session.policy.currentVersion))")
                }
                Text(session.selected.title).font(.system(size: 19, weight: .semibold))
                Text(session.selected.body)
                    .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("Where").font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                        Text(session.selected.location).font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 0)
                        Button(session.selected.action) { openLocation(session.selected) }
                            .buttonStyle(.link).font(.system(size: 12))
                    }
                    Text(session.selected.alternative)
                        .font(.system(size: 11.5)).foregroundStyle(theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
        }
    }

    private func newBadge(_ title: String) -> some View {
        Text(title).font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Color(uiHex: scheme == .dark ? 0x64B5FF : 0x0060CC))
            .padding(.horizontal, 5).padding(.vertical, 3)
            .background(Color.accentColor.opacity(scheme == .dark ? 0.18 : 0.12), in: .rect(cornerRadius: 4))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Skip") { finish() }.buttonStyle(.plain).foregroundStyle(theme.textSecondary)
            Spacer()
            Text("\(session.index + 1) of \(session.policy.orderedSteps.count)")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(theme.textTertiary)
            Spacer()
            Button("Back") { session.select(session.policy.orderedSteps[session.index - 1].id) }
                .disabled(session.index == 0)
            Button(session.index == session.policy.orderedSteps.count - 1 ? "Done" : "Next") {
                if session.index == session.policy.orderedSteps.count - 1 {
                    finish()
                } else {
                    session.select(session.policy.orderedSteps[session.index + 1].id)
                }
            }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
        .controlSize(.small).padding(.horizontal, 22)
    }

    private func finish() {
        session.finish()
        close()
    }
}

struct WhatsNewView: View {
    let session: WelcomeSession
    let openStep: (String) -> Void

    private var steps: [WelcomeStep] {
        session.policy.steps.filter {
            WelcomePolicy.compare($0.introduced(in: session.policy.currentVersion), session.policy.currentVersion)
                == .orderedSame
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("What's New in ContainerStack \(session.policy.currentVersion)").font(.title2.weight(.semibold))
                ForEach(steps) { step in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(step.title).font(.headline)
                        Text(step.line).foregroundStyle(.secondary)
                        Button("Show in Welcome") { openStep(step.id) }.buttonStyle(.link)
                    }
                }
                Divider()
                Text("Release notes").font(.headline)
                if WelcomeRelease.notes.isEmpty {
                    Text("No release notes are available for this version.").foregroundStyle(.secondary)
                } else {
                    ReleaseNotesContent(text: WelcomeRelease.notes)
                }
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 560, height: 500)
    }
}

private struct ReleaseNotesContent: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(text.components(separatedBy: .newlines).enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("### ") {
                    Text(String(line.dropFirst(4))).font(.headline).padding(.top, 4)
                } else if !line.isEmpty {
                    Text(.init(line.hasPrefix("* ") ? "• " + line.dropFirst(2) : line))
                        .font(.callout).textSelection(.enabled)
                }
            }
        }
    }
}
