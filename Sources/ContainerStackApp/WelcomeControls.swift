import ContainerStackCore
import SwiftUI

struct WelcomeControls: View {
    let step: WelcomeStep
    let model: RuntimeViewModel
    let resources: ContainerResourceSettings
    let builder: ContainerResourceSettings
    let shared: SharedRuntimeSettings
    let commandLine: CommandLineSettings
    let skill: AgentSkillSettings
    let doctor: DoctorViewModel
    @AppStorage(BuilderIdleStop.minutesKey) private var idleMinutes = BuilderIdleStop.defaultMinutes

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch step.id {
            case "socket":
                LabeledContent("Socket") { Text("~/.containerstack/docker.sock").monospaced() }
                LabeledContent("ContainerStack context") { Text("containerstack").monospaced() }
                HStack {
                    Circle().fill(model.isDockerContextActive ? .green : .orange).frame(width: 7, height: 7)
                    LabeledContent("Context in use", value: model.activeDockerContext ?? "Not checked yet")
                }
            case "resources":
                resourceFields(resources)
                Text(resources.memoryAllocationNote).font(.caption).foregroundStyle(.secondary)
                WelcomeBridgeRestart(model: model, resources: resources, shared: shared)
            case "builder":
                resourceFields(builder)
                Picker("Stop when idle for", selection: $idleMinutes) {
                    ForEach(BuilderIdleStop.choices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "\(minutes) minutes").tag(minutes)
                    }
                }
                WelcomeBridgeRestart(model: model, resources: builder, shared: shared)
            case "cli":
                CommandLineAndAgentsView(commandLine: commandLine, agentSkill: skill)
            case "shared":
                SharedRuntimeSettingsSection(settings: shared).controls
                    .disabled(shared.document == nil)
                if let problem = shared.problem ?? shared.bridgeProblem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
                WelcomeBridgeRestart(model: model, resources: resources, shared: shared)
            case "stacks":
                stackControls
            case "doctor":
                WelcomeDoctorControls(doctor: doctor)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
    }

    private func resourceFields(_ settings: ContainerResourceSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ResourceLimitFields(
                cpus: Binding(get: { settings.cpus }, set: { settings.setCPUs($0) }),
                memoryGiB: Binding(get: { settings.memoryGiB }, set: { settings.setMemoryGiB($0) }),
                memoryDescription: settings.memoryDescription,
                maximumCPUs: settings.maximumCPUs,
                maximumMemoryGiB: settings.maximumMemoryGiB
            )
            .disabled(settings.problem != nil)
            if let problem = settings.problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }

    @ViewBuilder private var stackControls: some View {
        if let stack = model.allStacks.first {
            Text(stack.name).fontWeight(.semibold)
            ForEach(model.stackStatuses[stack.id] ?? [], id: \.name) { service in
                HStack {
                    Circle().fill(service.isRunning ? .green : .secondary).frame(width: 7, height: 7)
                    Text(service.name)
                    Spacer()
                    Text(service.isRunning ? "Running" : "Stopped").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Up") { Task { await model.upStack(stack) } }
                Button("Down") { Task { await model.downStack(stack, removeVolumes: false) } }
                Button("Restart") { Task { await model.restartStack(stack) } }
            }
            .disabled(!model.canMutate || model.busyStackID != nil)
            if let message = model.stackMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        } else {
            Text("No stacks yet").fontWeight(.medium)
            Text("Add an existing compose file or create a stack from the sidebar.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct WelcomeBridgeRestart: View {
    let model: RuntimeViewModel
    let resources: ContainerResourceSettings
    let shared: SharedRuntimeSettings
    @State private var problem: String?

    var body: some View {
        if resources.awaitsBridgeRestart || shared.awaitsBridgeRestart {
            Text("Saved. Restart Docker Bridge to apply changes. Running containers keep their size.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Restart Docker Bridge") {
                Task {
                    shared.beginBridgeRestart()
                    problem =
                        await model.restartBridge() ? nil : model.runtimeFailure ?? "Docker bridge restart failed."
                    resources.reload()
                    shared.reload()
                }
            }
            .disabled(!model.canRestartRuntime || resources.problem != nil)
            if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
        }
    }
}

private struct WelcomeDoctorControls: View {
    let doctor: DoctorViewModel
    private let checks: [CheckID] = [.appRoot, .socket, .foreignBridge, .dockerContext]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let repair = doctor.repairInProgress {
                Text(repair.progressTitle)
            } else {
                ForEach(checks, id: \.self) { id in
                    let check = doctor.report?.check(id)
                    HStack {
                        Circle().fill(check?.verdict.tint ?? .secondary).frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(id.title).fontWeight(.medium)
                            Text(check?.summary ?? "Not checked yet").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if let check, let action = DoctorAction(check.remedy) {
                            Button(action.title) { Task { await doctor.perform(action) } }
                                .disabled(!doctor.canPerform(action))
                        }
                    }
                }
            }
            HStack {
                Text(doctor.statusLine).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Check again") { doctor.checkAgain() }
                    .disabled(doctor.isRunning || doctor.repairInProgress != nil)
            }
            if let failure = doctor.repairFailure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { doctor.appeared() }
        .onDisappear { doctor.disappeared() }
    }
}
