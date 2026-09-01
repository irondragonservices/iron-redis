# image used for the healthcheck binary
FROM golang:1.25-alpine AS gobuilder
WORKDIR /src
COPY healthcheck/ ./
# Static, so it runs in an image with no loader guarantee of its own.
RUN CGO_ENABLED=0 go build -trimpath -ldflags '-w -s' -o /healthcheck .

#
# ---
#

# The official Redis image, for the binaries and the libraries they need.
#
# Upstream compiled Redis from source here: it read the version out of this
# image, fetched the tarball from download.redis.io over plain HTTP, and
# checked it against a hash file in a GitHub repository that has since been
# renamed. That is a build that fetches a compiler toolchain and an unsigned
# tarball over an unauthenticated channel, to arrive at a binary the official
# image already contains. Copying it out is both simpler and a smaller thing
# to trust.
FROM redis:8.10.1 AS base

# Fail the whole pipeline on the first failure. Without this the `ldd | awk |
# while read` below reports success even when ldd finds nothing, and the image
# is built missing every library it was supposed to carry.
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Patch the packages before lifting the libraries out. Whatever ships in the
# upstream image is what gets copied, and upstream rebuilds its image on its own
# schedule rather than on the security team's — so without this the hardened
# image inherits every unpatched library the upstream tag happens to carry.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# An empty directory to become /data. Its ownership is set on the COPY, not
# here: COPY of a directory copies the contents, creating the destination
# fresh as root:root 0755, so anything done to it in this stage is discarded.
RUN mkdir -p /out/data && chmod 700 /out/data

# Copy the binaries and everything they link against, preserving paths.
#
# The library list is resolved with ldd rather than written out, so the image
# builds on any architecture and the list cannot rot. The /lib -> /usr/lib
# rewrite is what makes the result copyable into distroless: Debian is
# usr-merged, ldd reports the /lib path, and `cp --parents` materialises
# /out/lib as a real directory, which cannot be copied over distroless's /lib
# symlink. The readlink pass copies the soname symlink and the file behind it;
# cp -a alone preserves the link and leaves its target behind.
RUN cp -a --parents /usr/local/bin/redis-server /out \
    && cp -a --parents /usr/local/bin/redis-sentinel /out \
    && cp -a --parents /usr/local/bin/redis-cli /out \
    && { ldd /usr/local/bin/redis-server; ldd /usr/local/bin/redis-sentinel; ldd /usr/local/bin/redis-cli; } \
       | tr -s ' ' | grep '=> /' | awk '{print $3}' \
       | sed -e 's|^/lib/|/usr/lib/|' -e 's|^/lib64/|/usr/lib64/|' \
       | sort -u \
       | while read -r lib; do \
           cp -a --parents "$lib" /out; \
           target="$(readlink -f "$lib")"; \
           [ "$target" != "$lib" ] && cp -a --parents "$target" /out; \
           true; \
         done

#
# ---
#

# Distroless, matched to the Debian release the Redis image is built on. The
# binaries are copied out dynamically linked, so a mismatched glibc is a
# container that exits before it logs anything.
FROM gcr.io/distroless/base-debian13:nonroot

LABEL org.opencontainers.image.source="https://github.com/irondragonservices/iron-redis"
LABEL org.opencontainers.image.description="Hardened base image for running Redis"

# copy in our healthcheck binary
COPY --from=gobuilder --chown=nonroot /healthcheck /healthcheck

# redis and its libraries. Not chowned to nonroot: these are system files and
# the runtime user has no business owning them.
COPY --from=base /out/usr /usr

# the data directory, owned by the runtime user. redis with appendonly yes
# creates appendonlydir under it on startup, so this has to be writable or the
# server exits during initialisation.
COPY --from=base --chown=nonroot /out/data /data

# copy in our redis config file
COPY --chown=nonroot redis.conf /redis.conf

# run as an unprivileged user instead of root
USER nonroot

# where we will store our data
VOLUME /data

# redis writes its dump and append-only files relative to the working directory
WORKDIR /data

# default redis port
EXPOSE 6379

# healthcheck to report the container status
HEALTHCHECK --interval=10s --timeout=10s --start-period=5s --retries=3 CMD [ "/healthcheck", "6379" ]

# entrypoint
CMD ["/usr/local/bin/redis-server", "/redis.conf"]
