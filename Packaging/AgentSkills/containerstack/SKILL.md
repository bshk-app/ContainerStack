---
name: containerstack
description: Use for container work on a Mac with ContainerStack - building images, running containers, docker compose, Dockerfiles, image pulls and pushes, builder memory, and container runtime errors. ContainerStack serves a Docker-compatible API on Apple Container. Use docker and docker compose through it, not the `container` CLI.
---

# ContainerStack

ContainerStack runs containers on Apple Container and serves the Docker API on
`~/.containerstack/docker.sock`. The Docker context `containerstack` points at that socket.
Each container, and each builder, is a separate VM.

## Rules

1. Use `docker` and `docker compose` for all container work: build, run, exec, logs, pull,
   push and compose.
2. Do not use the `container` CLI to build or start: `container build`, `container run`,
   `container create`, `container start`, `container builder start`. These commands go around
   ContainerStack. `container build --cpus` or `--memory` also recreates the shared image builder
   VM at that size, and the Mac keeps the memory that the VM has used until the builder stops.
3. Do not make a new buildx builder (`docker buildx create`). Each builder is one more VM. Use
   `docker build` or `docker buildx build` with the current builder.
4. You can use the `container` CLI to read state: `container list`, `container logs`,
   `container stats`, `container system status`.

## Before you start

Make sure that `docker` and its builds go to ContainerStack:

```sh
docker context show     # prints: containerstack
docker buildx inspect   # the endpoint of the node is: containerstack
```

- If the context is another one, add `--context containerstack` to each `docker` command.
- If the builder is on another endpoint, run builds with `BUILDX_BUILDER=containerstack`, or
  give `--builder containerstack` to `docker build` and `docker compose build`. A builder that
  `docker buildx use --global` selected stays selected in every context.
- Do not change the user's current context or builder.

Check the runtime with the `cstack` CLI from the same ContainerStack.app as this skill:

```sh
<this skill's directory>/scripts/cstack doctor
```

## Builds

- `docker build` starts its builder if the builder is not running. A buildx builder container
  gets the default container resources from ContainerStack Settings > Default Container
  Resources when buildx creates the container. The image builder that `container build` and
  Docker API builds use gets Settings > Image Builder when it starts.
- If a build fails because it has no memory (exit code 137, `signal: killed`,
  `Cannot allocate memory`), stop and tell the user:
  - For a buildx builder: increase Default Container Resources > Memory and restart the Docker
    bridge. The builder container keeps its old size until it is made again, so the user must
    also remove it: `docker rm -f buildx_buildkit_<node>` (the name in `docker ps -a`). The next
    build makes it with the new size. The build cache stays in the volume
    `buildx_buildkit_<node>_state`.
  - For the image builder: increase Image Builder > Memory and restart the Docker bridge. The
    builder takes the new size the next time it starts.
  - Do not use `container build --memory` to get around it.
- ContainerStack stops a builder that does no work for the time in Settings > Image Builder
  (default: 10 minutes). The next build starts it again. Do not stop, remove or create builders
  unless the user asks you to.

## Containers

- `docker run --cpus N --memory SIZE` sets the VM size of one container.
- A container without limits gets Settings > Default Container Resources.

## When something fails

- `scripts/cstack doctor` checks the Docker socket, the versions, the routes to containers and
  the memory that running containers can use. Read its output before you change anything.
- `scripts/cstack runtime restart` restarts the runtime when published ports stop working. It
  stops all running containers and builds, so ask the user first.
