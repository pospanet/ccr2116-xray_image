#!/usr/bin/env bash
set -euo pipefail

test "$(wc -l < .env)" -eq 8
grep -qx 'XRAY_VERSION=26.7.28' .env
grep -qx 'XRAY_RELEASE_TAG=v26.7.28' .env
grep -qx 'XRAY_UPSTREAM_COMMIT=5ca6f4b7d4dc20a881d4330e498892697627ec0c' .env
grep -qx 'XRAY_ASSET_NAME=Xray-linux-arm64-v8a.zip' .env
grep -qx 'XRAY_ASSET_SHA256=f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501' .env
grep -qx 'IMAGE_NAME=pospa/xray-core' .env
grep -qx 'WRAPPER_RELEASE=0.2' .env
grep -qx 'PLATFORM=linux/arm64' .env
grep -qx 'f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501  Xray-linux-arm64-v8a.zip' checksums/xray-v26.7.28-linux-arm64-v8a.sha256

grep -Fq 'ADD --checksum=sha256:f5698bb218ada3b4022db26fafc39601c5f53b46b19eb76c9616325985807501 https://github.com/XTLS/Xray-core/releases/download/v26.7.28/Xray-linux-arm64-v8a.zip /tmp/xray.zip' Dockerfile
grep -Fq "FROM --platform=\$BUILDPLATFORM golang:1.24.6-alpine3.22@sha256:c8c5f95d64aa79b6547f3b626eb84b16a7ce18a139e3e9ca19a8c078b85ba80d AS entry-build" Dockerfile
grep -Fq "FROM --platform=\$BUILDPLATFORM alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce AS xray-verified" Dockerfile
test "$(grep -Fc 'FROM scratch' Dockerfile)" -eq 1
test "$(grep -Fc 'USER 65532:65532' Dockerfile)" -eq 1
grep -Fq "test \"\$TARGETPLATFORM\" = \"linux/arm64\"" Dockerfile
grep -Fq 'COPY --from=xray-verified --chmod=0555 /out/runtime-dirs/etc /etc' Dockerfile
grep -Fq 'COPY --from=xray-verified --chmod=0555 /out/runtime-dirs/usr /usr' Dockerfile
grep -Fq '&& chmod 1777 /out/runtime-tmp/tmp' Dockerfile
grep -Fq 'COPY --from=xray-verified /out/runtime-tmp/ /' Dockerfile
if grep -Eq '^COPY .*--chmod=.*runtime-tmp' Dockerfile; then
  echo 'Dockerfile overrides the verified sticky mode of /out/tmp' >&2
  exit 1
fi
awk '/^FROM scratch$/ { final_stage=1; next } final_stage && /^COPY --from=/ { copies++ } END { exit copies == 8 ? 0 : 1 }' Dockerfile
if grep -Eq 'apk add|apt-get|curl|wget' Dockerfile; then
  echo 'Dockerfile contains an unapproved network/package command' >&2
  exit 1
fi
if grep -REq 'uses:[[:space:]]+[^@]+@(v[0-9]+|main|master)([[:space:]#]|$)' .github/workflows; then
  echo 'workflow action is not pinned by full commit SHA' >&2
  exit 1
fi
if grep -REh '^[[:space:]]*-[[:space:]]+uses:' .github/workflows \
  | grep -Ev 'uses:[[:space:]]+(\./[^[:space:]#]+|[^[:space:]#]+@[0-9a-f]{40})([[:space:]]+#.*)?$'; then
  echo 'workflow action reference is not local or pinned by full commit SHA' >&2
  exit 1
fi
if grep -Eq 'docker/login-action|docker (login|push)' .github/workflows/xray-ci.yaml; then
  echo 'ordinary CI contains registry authentication or publication' >&2
  exit 1
fi
if grep -REqi '(^|[^[:alnum:]])latest([^[:alnum:]]|$)' .github/workflows; then
  echo 'workflow contains a forbidden latest tag reference' >&2
  exit 1
fi
