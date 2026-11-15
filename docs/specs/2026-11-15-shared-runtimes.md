# Spec: shared runtimes — several sessions in one VM

Version: 0.1 (draft, before the first design review)
Date: 2026-11-15
Source: discussion of 2026-11-15 and two live tests on Apple Container 1.7.1-bshk.1 with
socktainer `65e0569`. LinuxPod research: 2026-11-12.

## 1. Overview

Each container is one VM, and a VM keeps the guest memory it has touched. An MCP client starts
one `docker run -i --rm <image>` for each agent session, so three sessions of one MCP server are
three VMs.

Measured with `crystaldba/postgres-mcp`, container limit 8 GiB:

| Setup | Host memory |
|---|---|
| 3 dedicated VMs | 633 + 629 + 629 = 1891 MB |
| 1 VM with 3 `exec` sessions | 836 MB |

The fixed cost of one VM is about 470 MB; one server process uses 100 to 160 MB in the guest.

This spec adds **groups**. A run that belongs to a group does not get its own VM: it becomes a
**session**, a process in a shared container of the group. The client still sees a container
of its own. Stage 1 is socktainer; stage 2 is the app; groups of different images in one VM
(`LinuxPod`) are a later spec.

## 2. Requirements

Stage 1 (socktainer):

- **[F-001] Selection.** A create request selects a group in this order: the label
  `containerstack.group=<name>` (`none` = no group); the rules of the file, in order; else no
  group. *Acceptance:* unit tests over the fixture file (§3.1) for a label that wins over a
  rule, `none`, the first matching rule, and no match.
- **[F-002] Eligibility.** A run can be a session only when the request has: `OpenStdin`,
  `AttachStdin`, `AttachStdout`, `AutoRemove`; no `Tty`; no binds, mounts or volumes; no port
  bindings; the default network; no CPU or memory limit; and each other field of the request at
  its default. The check is an allowlist: a field that is not in the sharing key and not at its
  default makes the run not eligible. *Acceptance:* one unit test for each condition, and one
  for a field outside the list (`Privileged`), all on recorded create bodies.
- **[F-003] Sharing key.** Sessions share a container only when these are equal: image ID,
  entrypoint, command, environment, user, working directory. The key is a SHA-256 of a canonical
  encoding. Environment values are never written to a label, a log line or an error text.
  *Acceptance:* unit tests: equal requests give equal keys; a change of one environment value,
  of the image ID behind the same tag, or of the user gives a different key; the key and the
  log output of a run do not contain an environment value.
- **[F-004] One container for one key.** Concurrent first sessions with one key create one
  shared container. *Acceptance:* a test starts 3 sessions with one key at the same time on a
  fake runtime client that suspends in `create`; the client sees one container create.
- **[F-005] Session life.** The Docker CLI sends `create`, then `attach` (a hijacked stream,
  before `start`), then `wait?condition=removed`, then `start` (traced on 2026-11-15). `create`
  returns a session ID and starts nothing. `start` makes sure the shared container runs, starts
  the session through the launcher (§3.3) and connects it to the waiting `attach` stream. `wait`
  returns the exit code of the session's main process when the session has ended and is
  removed. *Acceptance:* a route test runs the four calls in the traced order against the fake
  client and asserts the bytes in both directions and the exit code; a second test sends `start`
  with no `attach` and gets a session that ends cleanly.
- **[F-006] A session ends with all its processes.** A session ends when its main process
  exits, when the client calls `stop` or `kill`, or when the `attach` connection closes. In each
  case socktainer signals the launcher, and no process of the session is left. *Acceptance:* a
  test per cause on the fake client asserts the signal to the launcher's process handle; the
  live check (§4) starts a shell with two child processes as a session, kills the Docker client,
  and finds no process of the session after 10 s.
- **[F-007] Idle stop.** When the last session of a shared container ends, the container stays
  for `idleMinutes` of its group, then it is stopped and removed. `0` means never. A session
  that joins during the stop gets a new container; it never joins one that is stopping.
  *Acceptance:* tests with a fake clock: no stop before the limit, a stop at the limit, a join
  that cancels the timer, and a join that arrives while the stop runs.
- **[F-008] A run that cannot be a session.** If a rule selected the group, the run gets a
  dedicated VM and the label `containerstack.group.skipped=<group>:<reason>`. If a label
  selected the group, `create` fails with 400 and a message that names the reason. An unknown or
  disabled group in a label is a reason too. *Acceptance:* tests for both paths for one reason of
  each class (§3.2).
- **[F-009] What the API shows.** A session is in the container list, with its own ID, name,
  labels and state. The shared container is in the list too. These routes work on a session ID:
  `inspect`, `logs`, `attach`, `wait`, `stop`, `kill`, `remove`. Each other route that takes a
  container ID returns 409 "not supported for a session of a shared group". *Acceptance:* route
  tests for each supported route and for two unsupported ones (`exec`, `archive`).
- **[F-010] Logs.** socktainer keeps the last 256 KiB of the output of each session in memory
  and serves `logs` from it. The buffer is dropped when the session is removed. *Acceptance:* a
  test writes 300 KiB and reads the last 256 KiB.
- **[F-011] The file.** A missing file means the defaults (§3.1). A file that does not parse, or
  has a `version` that socktainer does not know, turns grouping off; the cause is in `/info`
  for Doctor. socktainer reads the file again at a `create` when its modification time has
  changed. Live sessions keep their container. *Acceptance:* tests for missing, malformed,
  unknown version, and a change between two creates.
- **[F-012] Cleanup at start.** At start, socktainer removes the shared containers whose
  `containerstack.shared.socket` label is its own socket path, and only when it owns startup
  housekeeping. *Acceptance:* a test with two shared containers of different socket labels
  removes one.
- **[F-013] Temporary directory.** Each session gets a directory of its own, `TMPDIR` names it,
  and it is removed when the session ends. *Acceptance:* launcher test (§3.3).
- **[F-014] Off until asked.** Grouping runs only when socktainer starts with
  `--shared-runtimes`. Without the flag, every request behaves as today. *Acceptance:* a test
  that an eligible `mcp/*` run with no flag creates a dedicated container.

Stage 2 (app), detailed in its own plan:

- **[F-101]** The runtime helper passes `--shared-runtimes`.
- **[F-102]** Settings > Shared Runtimes edits the file: enable, idle time, one image pattern
  per added group. A file that does not parse disables the controls and shows the cause.
- **[F-103]** Containers shows a shared container as a group row with its sessions below it;
  a session has Stop and Logs only; a skipped run shows its reason in the inspector.
- **[F-104]** Doctor's memory check counts a shared container one time and no sessions, and
  reports "N sessions in M shared containers".

## 3. Design

### 3.1 File (frozen contract)

`~/.containerstack/runtime-groups.json`. The app writes it; socktainer reads it. JSON, because
the app's `config.toml` reader supports flat tables only.

```json
{
  "version": 1,
  "groups": [
    { "name": "mcp-catalog",    "kind": "exec", "idleMinutes": 10, "enabled": true },
    { "name": "stdio-sessions", "kind": "exec", "idleMinutes": 10, "enabled": false }
  ],
  "rules": [
    { "group": "mcp-catalog",    "image": "mcp/*" },
    { "group": "stdio-sessions", "stdioSession": true }
  ]
}
```

- This document is also the default when the file is missing, and the fixture
  `runtime-groups.v1.json` that the tests of both repositories read.
- `name`: `[a-z0-9-]{1,32}`, unique. `kind`: `exec`; `pod` is reserved and makes the group
  disabled in version 1. `idleMinutes`: 0, 5, 10, 30 or 60.
- A rule has `group` and exactly one condition. `image`: a glob on the image name as the client
  wrote it, with no tag and no `docker.io/` prefix; `*` does not match `/`. `stdioSession`:
  matches each eligible run.
- Unknown keys are an error (the file does not parse).

### 3.2 Labels and reasons (frozen contract)

| On | Label | Value |
|---|---|---|
| shared container | `containerstack.shared.group` | group name |
| shared container | `containerstack.shared.key` | first 16 hex characters of the key |
| shared container | `containerstack.shared.socket` | socket path of the bridge that owns it |
| session | `containerstack.session.group` | group name |
| session | `containerstack.session.container` | ID of its shared container |
| dedicated run | `containerstack.group.skipped` | `<group>:<reason>` |

The shared container is named `cs-shared-<group>-<first 8 of the key>`. A session keeps the
name the client gave, or gets a generated one, as a container does.

Reasons: `no-stdin`, `no-autoremove`, `tty`, `mount`, `port`, `network`, `limits`,
`option:<field name>`, `unknown-group`, `disabled-group`.

### 3.3 Launcher (frozen contract)

One static Linux arm64 binary, `cs-session`, built by the project with the toolchain and the
embedding path of the `socktainer-dns` forwarder. socktainer mounts it read-only at
`/run/containerstack/cs-session`. The image needs no shell.

- `cs-session pause`: the init process of a shared container. It reaps each child and exits 0
  on SIGTERM.
- `cs-session run --tmp <dir> -- <program> [args...]`: one session.
  1. It makes itself a child subreaper, creates `<dir>` (mode 0700) and sets `TMPDIR=<dir>`.
  2. It starts the program with its own stdin, stdout and stderr, in the current directory.
  3. It forwards SIGTERM, SIGINT, SIGHUP and SIGQUIT to the program. 5 s after the first
     SIGTERM it sends SIGKILL.
  4. When the program has exited, it sends SIGKILL to each remaining descendant until it has
     none, removes `<dir>`, and exits.
- Exit code: the code of the program; 128 + N when signal N ended it; 125 for a usage error;
  126 when the program cannot run; 127 when it is not found.
- Tests run the binary in a container: exit code pass-through; a program with two children that
  ignores SIGTERM leaves no process after the 5 s limit; `<dir>` is gone after each case.

Tested on 2026-11-15, the reasons for this shape: a signal through the runtime ends only the
main process of an `exec`, its children stay; a killed Docker client ends nothing; a static
binary mounted from the host keeps a container alive in an image with no shell.

### 3.4 Session manager

One actor owns the map from key to shared container and from session ID to session. It makes
F-004 and F-007 true by construction: "find or create the container for a key" and "stop an idle
container" are operations of the same actor, and a container is in one of three states,
`starting`, `running(sessions)`, `stopping`. A request for a key in `stopping` starts a new
container under a new name suffix.

The session is started with the working directory, the entrypoint and the command of the image
as separate arguments, and the environment and the user of the request. The environment of the
image reaches an `exec` with no extra work (checked with three images: `mcp/time`,
`mcp/sequentialthinking`, `ghcr.io/github/github-mcp-server`).

`attach` for a session that has not started holds the stream. `start` binds it. Output that
arrives with no stream attached goes only to the log buffer.

### 3.5 What does not change

The wait route for dedicated containers (bounded poll, end on disconnect, #23) is not changed.
A session never uses the container list poll: its `wait` resolves from the session manager.

## 4. Test infrastructure and live check

Unit and route tests use the existing fake runtime client of socktainer; a test must suspend,
not block a pool thread. The live check runs on a second bridge with its own socket and the
`--shared-runtimes` flag, not on the user's bridge:

1. Three `docker run -i --rm crystaldba/postgres-mcp` with one environment: one VM; host memory
   under 1000 MB against about 1900 MB for three dedicated runs.
2. A real MCP exchange (`initialize`, `tools/list`) through a session for `mcp/time`,
   `mcp/sequentialthinking` and `ghcr.io/github/github-mcp-server`.
3. F-006: kill the client of a session that has child processes; no process is left.
4. F-007 with the idle time set to its minimum by a test hook.

## 5. Non-goals

- Groups of different images in one VM (`kind: "pod"`, `LinuxPod`). Separate spec.
- Agent runtimes (a sandbox for a coding agent, a long-lived worker).
- Sessions with mounts, ports, a TTY or resource limits.
- The compose key `runtime:`. Selection is by label only.
- A rule editor for more than one image pattern per group in the app.
- `exec`, `cp`, `stats`, `rename`, `update` and `commit` on a session.

## 6. Decided

- Stage 1 is in socktainer. The owner is not sure that socktainer is the right place; a runtime
  plugin would also cover the `container` CLI, but it is a change in the `container` fork. The
  file, the labels and the launcher do not depend on this choice.
- Explicit selection is by label, not by the compose key `runtime:`: a file with an unknown
  runtime fails on other engines.
- `mcp-catalog` (images `mcp/*`) is on by default; `stdio-sessions` is off by default.
- Sessions share a container only with the same image and run configuration, so one session
  cannot read the credentials of another configuration.
- A session shows as a container; the shared container shows too.
- The project builds the launcher. Each session has its own temporary directory.
- Rule-selected runs fall back to a dedicated VM; label-selected runs fail.

## 7. Delivery

- Wave 1, in parallel, disjoint files: (a) the launcher binary and its tests; (b) the pure
  module for the file, the rules, eligibility and the key, with the fixture.
- Wave 2, one owner, after wave 1 is merged: the session manager, the routes, logs, cleanup at
  start, the flag.
- Live check (§4), then the pin in ContainerStack. The pin is safe before stage 2 because of
  F-014.
- Stage 2 starts when the labels exist in a merged socktainer.

Open:

1. What `inspect` of a session must return for the MCP clients in use to accept it.
2. Three images passed the session test; the catalog has many more, and `mcp-catalog` is on by
   default once the flag is passed.
3. The fixed VM cost was measured at an 8 GiB limit only.
