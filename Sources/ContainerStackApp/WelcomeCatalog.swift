import Foundation

struct WelcomeStep: Identifiable, Equatable {
    let id: String
    let short: String
    let release: String
    let title: String
    let body: String
    let line: String
    let location: String
    let action: String
    let alternative: String

    func introduced(in currentVersion: String) -> String { release == "next" ? currentVersion : release }
}

enum WelcomeCatalog {
    static let steps: [WelcomeStep] = [
        WelcomeStep(
            id: "socket",
            short: "Docker context",
            release: "0.1",
            title: "Use the Docker context",
            body:
                "docker and docker compose reach ContainerStack only when the Docker context containerstack is in "
                + "use. ContainerStack does not change the context for you. It does not replace "
                + "/var/run/docker.sock, so other Docker apps keep working.",
            line: "docker reaches ContainerStack only through the containerstack context.",
            location: "Sidebar › ⋯ at the bottom › Use as Docker Context",
            action: "Show in Sidebar",
            alternative: "Or set DOCKER_HOST=unix://$HOME/.containerstack/docker.sock"),
        WelcomeStep(
            id: "resources",
            short: "Container size",
            release: "0.9.0",
            title: "Each container is a virtual machine",
            body:
                "Apple Container starts one VM for each container. A container started with no CPU or memory "
                + "limit gets the default size. The default is all CPUs and a quarter of this Mac’s memory, minimum "
                + "2 GiB.",
            line: "Each container is a VM. Set the size of containers with no limit.",
            location: "Settings › Default Container Resources",
            action: "Open Settings",
            alternative:
                "Restart Docker Bridge shows here after you change a value. Running containers keep their size."),
        WelcomeStep(
            id: "builder",
            short: "Image builder",
            release: "0.9.0",
            title: "Builders stop when idle",
            body:
                "A builder VM keeps the memory it has used until it stops. ContainerStack stops the image builder "
                + "and buildx builders that do no work for the set time. The next build starts them again.",
            line: "A builder keeps its memory until it stops. Idle builders stop after 10 minutes.",
            location: "Settings › Image Builder",
            action: "Open Settings",
            alternative: "A running builder keeps its size. New values apply the next time it starts."),
        WelcomeStep(
            id: "stacks",
            short: "Stacks",
            release: "0.1",
            title: "Compose files become stacks",
            body:
                "Add a compose file you have, or make a new one. The stack editor changes ports and volumes and "
                + "runs Up, Down and Restart. Containers groups its list by stack.",
            line: "Register compose files, edit ports and volumes, run Up and Down.",
            location: "Sidebar › Stacks › Add Existing… or New Stack…",
            action: "Show in Sidebar",
            alternative: "Down removes the stack’s containers and network. Volumes stay."),
        WelcomeStep(
            id: "doctor",
            short: "Doctor",
            release: "0.1",
            title: "Doctor checks the setup and repairs it",
            body:
                "Doctor checks the runtime, the Docker socket and bridge, and the Docker context. When a check "
                + "fails, Doctor shows the repair: Restart Runtime or Repair Context.",
            line: "Checks the socket, the bridge and the context, and repairs them.",
            location: "Sidebar › Doctor",
            action: "Show in Sidebar",
            alternative: "The runtime status and its actions are at the bottom of the sidebar."),
        WelcomeStep(
            id: "cli",
            short: "Command line",
            release: "next",
            title: "Command line and coding agents",
            body:
                "The cstack command checks and controls ContainerStack from Terminal. The skill tells Codex and "
                + "Claude Code to build and run containers with docker and cstack through ContainerStack. The skill "
                + "has its own copy of cstack, so agents work without the command.",
            line: "Install the cstack command. Let Codex and Claude Code use ContainerStack.",
            location: "Settings › Command Line and Agents",
            action: "Open Settings",
            alternative: "Install asks for an administrator password. You can change both later in Settings."),
        WelcomeStep(
            id: "shared",
            short: "Shared runtimes",
            release: "0.11.0",
            title: "MCP sessions can share one VM",
            body:
                "Turn on a group, and each matching docker run -i --rm runs in one shared VM, not in a VM of its "
                + "own. Measured: three MCP sessions use about 560 MB, against about 1490 MB in three VMs. Sessions "
                + "of one group share one container, so they are one trust domain.",
            line: "Several MCP sessions share one VM: about 560 MB for three, not 1490 MB.",
            location: "Settings › Shared Runtimes",
            action: "Open Settings",
            alternative:
                "Both groups are off by default. A run with a TTY, mounts, ports or limits still gets its own VM."),
    ]
}
