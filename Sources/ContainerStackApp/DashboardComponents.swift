import SwiftUI

struct MetricCard: View {
    let title: String
    let value: String
    let icon: Lucide
    let tint: Color

    init(title: String, value: Int, icon: Lucide, tint: Color) {
        self.init(title: title, value: "\(value)", icon: icon, tint: tint)
    }

    init(title: String, value: String, icon: Lucide, tint: Color) {
        self.title = title
        self.value = value
        self.icon = icon
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 12) {
            LucideIcon(icon)
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.12), in: .rect(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 12))
    }
}

struct EmptyResourceView: View {
    let title: String
    let description: String
    let icon: Lucide

    var body: some View {
        VStack(spacing: 10) {
            LucideIcon(icon)
                .frame(width: 28, height: 28)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(30)
    }
}

struct MessageCard: View {
    let title: String
    let icon: Lucide
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            LucideIcon(icon)
                .frame(width: 14, height: 14)
            Text(title)
        }
        .font(.callout)
        .foregroundStyle(tint)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: 10))
    }
}

struct OutputCard: View {
    let title: String
    let output: String

    init(title: String = "Last output", output: String) {
        self.title = title
        self.output = output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(output)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.black.opacity(0.88), in: .rect(cornerRadius: 10))
        .foregroundStyle(.white)
    }
}

/// Inline "type a name, press the button" bar used by the images, volumes and networks views.
struct ResourceCreateBar: View {
    let placeholder: String
    let actionTitle: String
    let icon: Lucide
    let isBusy: Bool
    let isEnabled: Bool
    var focused: FocusState<Bool>.Binding? = nil
    let action: (String) -> Void

    @State private var text = ""

    var body: some View {
        HStack(spacing: 10) {
            createField
                .textFieldStyle(.roundedBorder)
                .font(.callout.monospaced())
                .onSubmit(submit)

            Button(action: submit) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label {
                        Text(actionTitle)
                    } icon: {
                        LucideIcon(icon)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isEnabled || isBusy || text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func submit() {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        action(value)
        text = ""
    }

    @ViewBuilder
    private var createField: some View {
        let field = TextField(placeholder, text: $text)
        if let focused {
            field.focused(focused)
        } else {
            field
        }
    }
}
