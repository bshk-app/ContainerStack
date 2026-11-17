# Shared runtimes

A shared runtime runs several eligible `docker run -i --rm` sessions of one group in
one VM. Each session is a process. Docker clients still see a container of their own.
Sessions share a VM only with the same image and effective command, entrypoint,
environment, user and working directory. A group can have more than one shared VM.

Each shared container is one trust domain: its sessions use the same user and writable
file system. Files and secrets written by one session can be read by another session.

## Turn a group on

Open **Settings > Shared Runtimes**. Both groups are off by default:

- **mcp-catalog** selects eligible runs of images that match `mcp/*`.
- **stdio-sessions** selects any eligible plain `docker run -i --rm` session.

The first matching rule of an enabled group wins. In the default file, the
`mcp-catalog` rule comes first. Image rules ignore the tag and the `docker.io/` prefix.
`*` does not match `/`.

Turn on a group, then click **Restart Docker Bridge** if Settings offers it.
By default, the bridge starts without shared runtime support, so the first group needs a
restart. Restarting interrupts open builds, exec sessions and runner jobs.
With shared runtime support active, later group, rule and idle changes need no restart.

## Runs that keep their own VM

A session needs open stdin, attached input and output, and automatic removal (`-i --rm`).
A TTY (`-t`), mounts or image volumes, published ports, a non-default network, CPU or
memory limits, or another unsupported option prevents sharing.

If a rule selects such a run, it gets its own VM. Select the container in the app and
read **Shared runtime** in its inspector for the group and reason. If you select a
group with `--label containerstack.group=<name>`, an incompatible run fails instead.
An unknown or disabled group also fails.

To keep a run separate even when a rule matches, use:

```sh
docker run -i --rm --label containerstack.group=none mcp/time
```

## Sessions and idle stop

Containers shows each shared container as a group with its sessions below it.
A session offers **Stop** and **Logs** only. Its inspector shows the group and shared
container. The group row offers **Stop** only. Its confirmation says how many sessions
will end. Sessions do not support `docker exec` or `docker cp`.

**Stop when idle for** sets one idle time for both default groups: Never, 5, 10, 30 or
60 minutes. The default is 10 minutes. After the last session ends, the shared container
is stopped and removed at that limit. **Never** disables the idle timer. **Mixed** means
the two groups have different times in the file. A choice sets the time of both.

## Doctor

Doctor and `cstack doctor` show **Shared runtimes: on**, **off** or **starting**.
When shared runtimes are off because of an error, they show the cause.
Only `cstack doctor` reports session and VM counts, such as
`3 sessions in 1 shared container`. Its memory total counts each shared VM once and
excludes sessions.

Doctor warns about shared containers with no bridge and shows `docker rm -f <names>`
for manual removal. It has no removal button. When the runtime helper starts and the
bridge runs without shared runtimes, the app removes leftovers with its own socket label.

## Hand edits

Settings saves `~/.containerstack/runtime-groups.json` at the first change, not at launch.
A missing file means the defaults, with both groups off. Settings preserves other groups
and rules when it edits this file. For the JSON layout and field rules, see the
[file format](specs/2026-11-15-shared-runtimes.md#31-file-frozen-contract).

Keep `version` at `1`. Unknown keys and rules that name an unknown group are errors.
Edit image rules and idle times by hand. The bridge reads file changes again.
If it has no shared runtime support, enabling the first `exec` group needs a restart.

If the file is not valid, Settings disables the controls and shows the cause.
Repair the file, or use **Reset to Defaults** and confirm it to replace your hand edits.
