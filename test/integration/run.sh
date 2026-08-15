#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE:?set IMAGE to the locally loaded candidate image}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixtures="$root/test/fixtures"
platform=linux/arm64

expect_ok() { "$@"; }
expect_fail() { if "$@"; then echo "expected command failure" >&2; exit 1; fi; }

expect_ok docker run --rm --platform "$platform" -v "$fixtures/valid.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_ok docker run --rm --platform "$platform" -v "$fixtures/template.json:/template.json:ro" -v "$fixtures/template-values.json:/values.json:ro" "$IMAGE" test --mode template --template /template.json --values /values.json
encoded=$(base64 -w0 "$fixtures/valid.json")
expect_ok docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$encoded" "$IMAGE" test --mode env-base64
invalid_encoded=$(base64 -w0 "$fixtures/invalid-json.json")
expect_fail docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$invalid_encoded" "$IMAGE" test --mode env-base64
expect_fail docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$encoded" "$IMAGE" test --mode template --template /template.json --values /values.json
expect_fail docker run --rm --platform "$platform" -v "$fixtures/invalid-json.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_fail docker run --rm --platform "$platform" -v "$fixtures/invalid-semantic.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_fail docker run --rm --platform "$platform" -v "$fixtures/template.json:/template.json:ro" -v "$fixtures/template-values-missing.json:/values.json:ro" "$IMAGE" test --mode template --template /template.json --values /values.json
expect_ok docker run --rm --platform "$platform" -v "$fixtures/xhttp-stream-one.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json

# A running container proves run execs the validated stdin configuration without a named config path.
cid=$(docker run -d --platform "$platform" -e "XRAY_CONFIG_BASE64=$encoded" "$IMAGE" run --mode env-base64)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
sleep 2
test "$(docker inspect -f '{{.State.Running}}' "$cid")" = true
docker rm -f "$cid" >/dev/null
trap - EXIT

test "$(docker image inspect -f '{{.Config.User}}' "$IMAGE")" = "65532:65532"
created=$(docker create --platform "$platform" "$IMAGE")
trap 'docker rm -f "$created" >/dev/null 2>&1 || true' EXIT
actual=$(docker export "$created" | tar -tf - | sed 's#^\./##' | grep -v '/$' | sort)
expected=$(printf '%s\n' etc/ssl/certs/ca-certificates.crt usr/local/bin/xray usr/local/bin/xray-entry usr/local/share/xray/geoip.dat usr/local/share/xray/geosite.dat | sort)
test "$actual" = "$expected"
docker export "$created" | tar -tf - | grep -qx 'tmp/'
for forbidden in bin/sh bin/bash busybox curl wget ssh apk apt apt-get dpkg yum dnf; do
  if printf '%s\n' "$actual" | grep -Eq "(^|/)$forbidden($|/)"; then
    echo "forbidden runtime file: $forbidden" >&2
    exit 1
  fi
done
docker rm -f "$created" >/dev/null
trap - EXIT
docker run --rm --platform "$platform" --entrypoint /usr/local/bin/xray "$IMAGE" version | grep -E '^Xray 26\.7\.28 '
echo "integration and final-filesystem checks passed"
