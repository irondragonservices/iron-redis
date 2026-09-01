# irondragonservices/iron-redis

Hardened Redis image.

Forked from [ironpeakservices/iron-redis](https://github.com/ironpeakservices/iron-redis).

`redis-server`, `redis-sentinel` and `redis-cli` lifted out of the official
image into distroless: no shell, no package manager, no coreutils. Runs as
`nonroot`, listens on 6379, persists to `/data`.

```sh
docker pull ghcr.io/irondragonservices/iron-redis:8
```

The tag tracks the Redis release, so `:8.10.1` is iron-redis built on
`redis:8.10.1`.

> **Licence.** Upstream pinned `redis:7.2.3`, which was BSD-3. Redis 8 is
> AGPLv3. That is a change you may care about depending on how you ship this;
> [Valkey](https://valkey.io) is the BSD-licensed fork if it matters.

## Using it

```sh
docker run -v redis-data:/data ghcr.io/irondragonservices/iron-redis:8
```

To change the configuration, replace the file:

```dockerfile
FROM ghcr.io/irondragonservices/iron-redis:8
COPY --chown=nonroot redis.conf /redis.conf
```

There is no shell in the image, so `docker exec sh` will not work. `redis-cli`
is present at `/usr/local/bin/redis-cli` and can be run directly.

**Redis has no authentication configured by default.** Do not expose 6379
outside a trusted network without setting `requirepass` or an ACL.

## What is in it

- `redis-server`, `redis-sentinel`, `redis-cli` and the libraries they link
  against
- a static healthcheck binary that issues a `PING`, wired into `HEALTHCHECK`
- `/redis.conf`
- `/data`, owned by the runtime user, declared as a volume

## Verifying what you pulled

```sh
cosign verify ghcr.io/irondragonservices/iron-redis:8 \
  --certificate-identity-regexp '^https://github\.com/irondragonservices/\.github/\.github/workflows/image-(release|refresh)\.yml@refs/heads/main$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-github-workflow-repository irondragonservices/iron-redis
```

Be precise about the identity. The signature is produced by the shared
reusable workflow in
[irondragonservices/.github](https://github.com/irondragonservices/.github),
not by a workflow in this repository, so the certificate names *that* path.
A looser pattern such as `^https://github.com/irondragonservices/` would
accept a signature from any workflow in any repository in the organisation,
which is a much weaker claim than it looks. The
`--certificate-github-workflow-repository` flag is what ties the signature back
to this repository.

Both `image-release` and `image-refresh` sign: the nightly rebuild republishes
when the package set has actually changed, and it signs what it pushes.

## Changes from upstream

- **Redis is no longer compiled from source.** Upstream read the version out of
  the official image, then fetched the tarball from `download.redis.io` **over
  plain HTTP** and checked it against a hash file in
  `antirez/redis-hashes`, a repository that has since been renamed. That is an
  unsigned artefact over an unauthenticated channel, plus a full compiler
  toolchain in the build, to arrive at a binary the official image already
  contains. It is copied out now — simpler, and a much smaller thing to trust.
- **Base moved from `distroless/base-debian10` to `base-debian13`**, and the
  builder from `debian:buster`. Both went end of life; buster's package
  archives have moved to `archive.debian.org`, so that stage could not resolve
  a mirror any more.
- **`/data` was not writable by the runtime user.** `COPY` of a directory
  copies the contents and creates the destination fresh as `root:root`, so the
  ownership set in the builder stage was discarded and Redis exited during
  initialisation with `Can't open or create append-only dir appendonlydir`.
- **The healthcheck moved from `go-redis` v6 to `redis/go-redis/v9`.** The old
  import path is unmaintained; `Ping` now takes a context.
- **The healthcheck now builds as a module.** It was built out of `/go/src`,
  which stopped working in Go 1.22. Go 1.21.3 to 1.25.
- **`CMD` no longer passes `"--port 6379"` as a single argv element**, which is
  not how it is parsed. The port is in `redis.conf`, where it already was.
- Redis 7.2.3 to 8.10.1 — see the licence note above.
- CI rebuilt as callers into
  [irondragonservices/.github](https://github.com/irondragonservices/.github).

Verified on build: the container reaches `healthy`, a `SET`/`GET` round-trips
through `redis-cli`, and the AOF files are created on startup.
