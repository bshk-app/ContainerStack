# ContainerStack roadmap

Parity target: OrbStack, on top of Apple Container instead of a shared Linux VM.
Every milestone below maps to a GitHub milestone in `bshk-app/ContainerStack`.

## Where we are

Working today, verified end to end:

- Apple Container 1.2.2 supervised by a bundled runtime helper, socktainer shipped as a sidecar in `Contents/Helpers`.
- Docker-compatible socket at `~/.containerstack/docker.sock`, registered as the active `containerstack` Docker context by default. Opting out restores the previous context; `/var/run/docker.sock` is never changed.
- `docker` and `docker compose` work unmodified: networks, volumes, published ports, `exec`, `down -v`.
- `cstack`: ps, inspect, logs, start/stop/restart/rm, run, images, pull, rmi, volumes, networks, df, prune, context, compose.
- App: overview, containers grouped by Compose project, images with pull/run/delete, volumes, networks, runtime panel with polled state.
- Signed and notarized bundle, LaunchAgent that keeps the runtime alive without the GUI.

Measured against OrbStack on an idle M1/16 GiB: container round trip 4.6× slower, bind-mount writes 3.6× slower,
3000-file bind-mount create 3.6× slower, pull and published-port latency at parity.
The gap is architectural: Apple Container boots one micro-VM per container.


## Milestones

| Milestone | Goal | Why it comes first |
|---|---|---|
| **M1 Runtime correctness** | Lifecycle control, honest health, working published ports | A runtime that reports "ready" while ports are dead is unusable |
| **M2 Docker API coverage** | exec, events, stats, build, archive, rename | Blocks Compose recreate, IDEs, Testcontainers |
| **M3 App parity** | Detail panes, activity monitor, builds, search | The GUI is the product differentiator |
| **M4 Settings and resources** | Settings window, limits, Rosetta, menu bar | Everything is hardcoded today |
| **M5 Networking** | Container domains, HTTPS, LAN exposure, proxy | OrbStack's strongest convenience feature |
| **M6 Storage** | Disk usage, data location, danger zone | Users hit disk limits and need to see why |
| **M7 Linux machines** | Full Linux VMs, USB passthrough | Second OrbStack pillar |
| **M8 Kubernetes** | Local cluster, pods and services | Apple Container already ships a k8s plugin |
| **M9 Distribution** | DMG, auto-update, CLI on PATH | Required before anyone else can install it |

## Known defects driving M1 and M2

1. Published ports stop working until `container system stop && start` recreates the vmnet interface (#1).
2. `POST /containers/{id}/rename` is unimplemented, so `docker compose up` fails on a changed service (#8).
3. `GET /events` never terminates and emits nothing, which hangs attached `docker compose up` (#6).

## Non-goals for now

- Replacing socktainer with our own daemon. It is an explicit later step once the compatibility surface is pinned
  down by tests; see the research report for the ownership argument.
- Windows or Linux hosts.
- Remote container hosts.

## Support tier policy

What ContainerStack promises about Docker and Compose compatibility. This determines what the M2
conformance suite asserts and what the app's help surface says, so it has to be decided before M2.

Options: narrow-and-honest, broad-with-documented-holes, or tiered.


<!-- TODO(decision): state the policy here.
     If tiered, define each tier concretely:
       Tier 1 — guaranteed, regression-tested on every commit. Which commands/flags?
       Tier 2 — best effort, may break on upstream bumps. Which?
       Tier 3 — explicitly refused with a Docker-shaped error. Which?
     Whatever the shape, name the failure mode for anything outside Tier 1: silent no-op,
     warning, or hard error. socktainer currently no-ops `network connect`/`disconnect`. -->
