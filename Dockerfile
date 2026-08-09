ARG GO_IMAGE=golang:1.26.5-bookworm@sha256:6c5605ab3a9a9fb3c4eafe5b3d63cdbf3881caf113262b67862547b54a9db599
FROM ${GO_IMAGE} AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
RUN go mod verify
COPY . .

ARG TARGETOS=linux
ARG TARGETARCH=amd64
ARG VERSION=dev
ARG COMMIT=unknown
ARG BUILD_TIME=unknown
ARG DIRTY=unknown
RUN go test -tags with_utls ./... && \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -tags with_utls -trimpath \
      -ldflags="-s -w -buildid= -X github.com/XDuke/mini-singbox/internal/version.Version=${VERSION} -X github.com/XDuke/mini-singbox/internal/version.Commit=${COMMIT} -X github.com/XDuke/mini-singbox/internal/version.BuildTime=${BUILD_TIME} -X github.com/XDuke/mini-singbox/internal/version.Dirty=${DIRTY}" \
      -o /out/mini-singbox ./cmd/mini-singbox

FROM scratch
COPY --from=builder /out/mini-singbox /mini-singbox
USER 65532:65532
ENTRYPOINT ["/mini-singbox"]
CMD ["run", "-c", "/etc/mini-singbox/config.json"]
