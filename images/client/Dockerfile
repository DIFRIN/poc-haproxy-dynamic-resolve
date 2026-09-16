# Build stage: static binary, standard library only (no module downloads).
FROM golang:1.23-alpine AS build

WORKDIR /src

ENV CGO_ENABLED=0 \
    GOFLAGS=-mod=mod \
    GOPROXY=off

COPY go.mod ./
COPY main.go ./

RUN go build -trimpath -ldflags="-s -w" -o /out/client .

# Runtime stage: ca-certificates so -ca may be omitted and system roots work.
FROM alpine:3.20

RUN apk add --no-cache ca-certificates

COPY --from=build /out/client /usr/local/bin/client

ENTRYPOINT ["/usr/local/bin/client"]
