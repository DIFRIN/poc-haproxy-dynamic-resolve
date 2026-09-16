# syntax=docker/dockerfile:1
#
# iot-mock -- the POC's mTLS IoT backend, the final destination of proxied
# HTTP CONNECT tunnels.
#
# Build context is this directory only:
#   docker build -t poc-iot-mock ./iot-mock
#
# Standard library only, so the builder needs no module downloads, no GOPROXY
# and no checksum database. go.mod is written here rather than committed
# because the module has exactly one file in it and no dependency graph worth
# tracking.

FROM golang:1.23-alpine AS builder

# CGO off -> fully static binary -> no libc in the runtime stage.
# GOTOOLCHAIN=local -> never try to fetch a different toolchain over the
# network, which would fail the build in an offline CI.
ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOFLAGS=-mod=mod \
    GOTOOLCHAIN=local

WORKDIR /src

RUN printf 'module iot-mock\n\ngo 1.23\n' > go.mod

COPY main.go ./

# -trimpath and -s -w keep the image small and the binary reproducible.
RUN go vet ./... \
 && go build -trimpath -ldflags='-s -w' -o /out/iot-mock .

# ---------------------------------------------------------------------------
FROM alpine:3.20

# This image makes no outbound TLS connections of its own (client certificates
# arrive over the mTLS listener), but ca-certificates keeps the trust store
# present for any future outbound call and costs ~200 KB.
RUN apk add --no-cache ca-certificates

COPY --from=builder /out/iot-mock /usr/local/bin/iot-mock

# Runs as root, on purpose: the container binds :443 inside its own network
# namespace, where that is not a privilege escalation, and it keeps the image
# free of setcap/xattrs that some container runtimes strip. If this ever runs
# with a shared network namespace, switch to a non-root user plus
# `setcap cap_net_bind_service=+ep /usr/local/bin/iot-mock`.
# The process needs no writable filesystem; mount one read-only if you like.

ENV LISTEN_TLS=:443 \
    LISTEN_METRICS=:9090

EXPOSE 443 9090

# The entrypoint fails fast (non-zero) if TLS_CERT, TLS_KEY or CLIENT_CA are
# missing or unreadable -- mTLS is mandatory in this POC and is never
# silently downgraded.
ENTRYPOINT ["/usr/local/bin/iot-mock"]
