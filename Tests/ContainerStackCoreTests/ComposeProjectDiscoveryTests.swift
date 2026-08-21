import Foundation
import Testing

@testable import ContainerStackCore

/// Reading the Stacks list off the runtime instead of a registry the user has to fill by hand
/// (issue #44): `docker compose up` in a terminal left the screen empty while Containers listed
/// every container of the project.
@Suite("ComposeProjectDiscovery")
struct ComposeProjectDiscoveryTests {
    private static func container(
        id: String,
        name: String,
        state: String = "running",
        project: String? = "myproject",
        service: String? = "db",
        workingDir: String? = "/path/to/myproject",
        configFiles: String? = "/path/to/myproject/docker-compose.yml"
    ) -> DockerContainerSummary {
        var labels: [String: String] = [:]
        if let project { labels[ComposeProjectDiscovery.projectLabel] = project }
        if let service { labels[ComposeProjectDiscovery.serviceLabel] = service }
        if let workingDir { labels[ComposeProjectDiscovery.workingDirLabel] = workingDir }
        if let configFiles { labels[ComposeProjectDiscovery.configFilesLabel] = configFiles }
        return DockerContainerSummary(
            id: id,
            names: ["/\(name)"],
            image: "alpine:3.20",
            imageID: nil,
            command: nil,
            created: nil,
            state: state,
            status: nil,
            labels: labels,
            ports: nil,
            networkSettings: nil
        )
    }

    @Test("containers of one project become one project, with its services and paths")
    func groupsByProject() {
        let projects = ComposeProjectDiscovery.discover(from: [
            Self.container(id: "1", name: "myproject-db-1", service: "db"),
            Self.container(id: "2", name: "myproject-cache-1", service: "cache"),
            Self.container(
                id: "3", name: "other-web-1", project: "other", service: "web",
                workingDir: "/elsewhere", configFiles: "/elsewhere/compose.yaml"),
        ])

        #expect(projects.count == 2)
        #expect(projects[0].name == "myproject")
        #expect(projects[0].services == ["db", "cache"])
        #expect(projects[0].workingDirectory?.path == "/path/to/myproject")
        #expect(projects[0].primaryFile == "/path/to/myproject/docker-compose.yml")
        #expect(projects[1].name == "other")
    }

    @Test("a container without compose labels is not a project")
    func ignoresPlainContainers() {
        let projects = ComposeProjectDiscovery.discover(from: [
            Self.container(
                id: "1", name: "loose", project: nil, service: nil, workingDir: nil, configFiles: nil)
        ])
        #expect(projects.isEmpty)
    }

    @Test("overrides are kept in the order Compose merged them, and the base file leads")
    func parsesConfigFileList() {
        let projects = ComposeProjectDiscovery.discover(from: [
            Self.container(
                id: "1", name: "myproject-db-1",
                configFiles:
                    "/path/to/myproject/docker-compose.yml,/path/to/myproject/docker-compose.override.yml")
        ])

        #expect(
            projects[0].configFiles == [
                "/path/to/myproject/docker-compose.yml",
                "/path/to/myproject/docker-compose.override.yml",
            ])
        #expect(
            projects[0].primaryFile.map { URL(fileURLWithPath: $0).lastPathComponent }
                == "docker-compose.yml")
    }

    @Test("a relative config path resolves against the working directory Compose recorded")
    func resolvesRelativeConfigPath() {
        let projects = ComposeProjectDiscovery.discover(from: [
            Self.container(
                id: "1", name: "myproject-db-1", workingDir: "/path/to/myproject",
                configFiles: "compose.yaml")
        ])
        let resolved = ComposeProjectDiscovery.resolvedPrimaryFile(for: projects[0])
        #expect(resolved?.path == "/path/to/myproject/compose.yaml")
    }

    @Test("a project's row keeps its identity between refreshes")
    func stableIdentity() {
        let first = ComposeProjectDiscovery.discover(from: [
            Self.container(id: "1", name: "myproject-db-1")
        ])[0]
        // Same project, different container: SwiftUI must see the same row, or selection and any
        // per-stack state are torn down on every poll.
        let second = ComposeProjectDiscovery.discover(from: [
            Self.container(id: "2", name: "myproject-db-2")
        ])[0]
        #expect(
            ComposeProjectDiscovery.stack(for: first)?.id
                == ComposeProjectDiscovery.stack(for: second)?.id)

        let elsewhere = ComposeProjectDiscovery.discover(from: [
            Self.container(
                id: "3", name: "myproject-db-1", workingDir: "/other", configFiles: "/other/compose.yaml")
        ])[0]
        #expect(
            ComposeProjectDiscovery.stack(for: elsewhere)?.id
                != ComposeProjectDiscovery.stack(for: first)?.id)
    }

    @Test("a project with no config file recorded cannot become a row")
    func skipsProjectWithoutFile() {
        let projects = ComposeProjectDiscovery.discover(from: [
            Self.container(id: "1", name: "myproject-db-1", workingDir: nil, configFiles: nil)
        ])
        #expect(ComposeProjectDiscovery.stack(for: projects[0]) == nil)
    }

    // MARK: - merging with the registry

    @Test("a running project the registry never saw is added")
    func mergeAddsUnknownProject() {
        let registered = [
            ComposeStack(name: "registered", fileURL: URL(fileURLWithPath: "/a/compose.yaml"))
        ]
        let discovered = ComposeProjectDiscovery.discover(from: [
            Self.container(id: "1", name: "myproject-db-1")
        ])

        let merged = ComposeProjectDiscovery.merge(registered: registered, discovered: discovered)
        #expect(merged.count == 2)
        #expect(merged[0].name == "registered", "a registered stack keeps its place and its identity")
        #expect(merged[1].name == "myproject")
    }

    @Test("a registered stack is not duplicated by its own running containers")
    func mergeDoesNotDuplicate() {
        // The app starts stacks with `--project-name <stack name>`, so its containers carry the
        // registered name and file — the same project, one row.
        let registered = [
            ComposeStack(
                name: "myproject", fileURL: URL(fileURLWithPath: "/path/to/myproject/docker-compose.yml"))
        ]
        let discovered = ComposeProjectDiscovery.discover(from: [
            Self.container(id: "1", name: "myproject-db-1")
        ])

        let merged = ComposeProjectDiscovery.merge(registered: registered, discovered: discovered)
        #expect(merged.map(\.name) == ["myproject"])
        #expect(merged.map(\.id) == registered.map(\.id), "the registry's identity survives the merge")
    }

    @Test("the same file under another project name is another stack")
    func mergeKeepsDistinctProjectsOnOneFile() {
        // `docker compose -p production -f /x/compose.yaml up` beside a registered `demo` on the same
        // file is a second, genuinely separate project — Compose tracks it separately and so must the
        // list. Matching on the file alone hid it.
        let registered = [ComposeStack(name: "demo", fileURL: URL(fileURLWithPath: "/x/compose.yaml"))]
        let discovered = ComposeProjectDiscovery.discover(from: [
            Self.container(
                id: "1", name: "production-web-1", project: "production",
                workingDir: "/x", configFiles: "/x/compose.yaml")
        ])

        let merged = ComposeProjectDiscovery.merge(registered: registered, discovered: discovered)
        #expect(merged.map(\.name) == ["demo", "production"])
    }

    @Test("every compose file the project was started with is carried, in order")
    func stackCarriesOverrides() {
        let discovered = ComposeProjectDiscovery.discover(from: [
            Self.container(
                id: "1", name: "myproject-db-1",
                configFiles:
                    "/path/to/myproject/docker-compose.yml,/path/to/myproject/docker-compose.override.yml")
        ])
        let stack = ComposeProjectDiscovery.stack(for: discovered[0])

        // Acting on the base file alone describes a different project, and `up --remove-orphans`
        // would delete a service that only the override defines.
        #expect(
            stack?.composeFiles.map(\.path) == [
                "/path/to/myproject/docker-compose.yml",
                "/path/to/myproject/docker-compose.override.yml",
            ])
    }
}

/// The command line Compose is actually given. A stack carrying overrides has to pass all of them:
/// `up` runs with `--remove-orphans`, so a service defined only in an override would be deleted.
@Suite("ComposeRunner arguments")
struct ComposeRunnerArgumentTests {
    @Test("one --file per compose file, in merge order")
    func passesEveryFile() {
        let stack = ComposeStack(
            name: "myproject",
            fileURL: URL(fileURLWithPath: "/p/docker-compose.yml"),
            overrideFiles: [URL(fileURLWithPath: "/p/docker-compose.override.yml")]
        )

        let arguments = ComposeRunner.composeArguments(for: stack, verb: "up", extra: ["--detach"])
        #expect(
            arguments == [
                "--project-name", "myproject",
                "--file", "/p/docker-compose.yml",
                "--file", "/p/docker-compose.override.yml",
                "--project-directory", "/p",
                "up", "--detach",
            ])
    }

    @Test("a stack with no overrides is unchanged")
    func singleFileUnchanged() {
        let stack = ComposeStack(name: "solo", fileURL: URL(fileURLWithPath: "/p/compose.yaml"))
        #expect(
            ComposeRunner.composeArguments(for: stack, verb: "ps") == [
                "--project-name", "solo",
                "--file", "/p/compose.yaml",
                "--project-directory", "/p",
                "ps",
            ])
    }
}

/// The registry on disk predates `overrideFiles`. A decoder that demands the key takes every stack
/// the user registered off the screen the first time the app runs with the new field.
@Suite("StackRegistry compatibility")
struct StackRegistryCompatibilityTests {
    @Test("a registry written before overrides still loads")
    func decodesRegistryWithoutOverrideFiles() throws {
        let json = Data(
            """
            [{"id":"F8AFA36D-F2DD-41EE-91FB-42812D18FA0B","name":"demo",\
            "fileURL":"file:///Users/me/Documents/ContainerStack/demo/compose.yaml"}]
            """.utf8)

        let stacks = try JSONDecoder().decode([ComposeStack].self, from: json)
        #expect(stacks.count == 1)
        #expect(stacks[0].name == "demo")
        #expect(stacks[0].overrideFiles.isEmpty)
        #expect(stacks[0].composeFiles.count == 1)
    }

    @Test("a registry round-trips through the new shape")
    func roundTripsWithOverrides() throws {
        let stack = ComposeStack(
            name: "demo",
            fileURL: URL(fileURLWithPath: "/p/compose.yaml"),
            overrideFiles: [URL(fileURLWithPath: "/p/compose.override.yaml")]
        )
        let data = try JSONEncoder().encode([stack])
        #expect(try JSONDecoder().decode([ComposeStack].self, from: data) == [stack])
    }
}
