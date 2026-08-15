# The builder manifest digest was reviewed from Docker Hub on 2026-08-15.
FROM --platform=$BUILDPLATFORM golang:1.24.6-alpine3.22@sha256:c8c5f95d64aa79b6547f3b626eb84b16a7ce18a139e3e9ca19a8c078b85ba80d AS entry-build
ARG TARGETPLATFORM
WORKDIR /src
COPY go.mod ./
COPY cmd/xray-entry ./cmd/xray-entry
COPY tools/xray-extract ./tools/xray-extract
RUN test "$TARGETPLATFORM" = "linux/arm64" \
    && CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o /out/xray-extract ./tools/xray-extract \
    && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o /out/xray-entry ./cmd/xray-entry

FROM --platform=$BUILDPLATFORM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS xray-verified
# BuildKit verifies the committed archive SHA-256 before this archive is extracted.
ADD --checksum=sha256:f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501 https://github.com/XTLS/Xray-core/releases/download/v26.7.28/Xray-linux-arm64-v8a.zip /tmp/xray.zip
COPY --from=entry-build /out/xray-extract /usr/local/bin/xray-extract
RUN mkdir -p /out/usr/local/bin /out/usr/local/share/xray \
        /out/runtime-dirs/etc/ssl/certs \
        /out/runtime-dirs/usr/local/bin \
        /out/runtime-dirs/usr/local/share/xray \
        /out/runtime-tmp/tmp \
    && /usr/local/bin/xray-extract /tmp/xray.zip /out/usr/local/share/xray \
    && mv /out/usr/local/share/xray/xray /out/usr/local/bin/xray \
    && chmod 1777 /out/runtime-tmp/tmp

FROM scratch
COPY --from=xray-verified --chmod=0555 /out/runtime-dirs/etc /etc
COPY --from=xray-verified --chmod=0555 /out/runtime-dirs/usr /usr
COPY --from=xray-verified --chmod=0555 /out/usr/local/bin/xray /usr/local/bin/xray
COPY --from=entry-build --chmod=0555 /out/xray-entry /usr/local/bin/xray-entry
COPY --from=entry-build --chmod=0444 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=xray-verified --chmod=0444 /out/usr/local/share/xray/geoip.dat /usr/local/share/xray/geoip.dat
COPY --from=xray-verified --chmod=0444 /out/usr/local/share/xray/geosite.dat /usr/local/share/xray/geosite.dat
# COPY omits metadata of its source root, so /tmp is deliberately a child of
# this staging root. Its 1777 mode is then recorded in the final layer.
COPY --from=xray-verified /out/runtime-tmp/ /
USER 65532:65532
ENTRYPOINT ["/usr/local/bin/xray-entry"]
CMD ["run"]
