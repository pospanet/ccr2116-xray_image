#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE:?set IMAGE to the locally loaded candidate image}"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixtures="$root/test/fixtures"
platform=linux/arm64

expect_ok() {
  local name=$1
  shift
  echo "check: $name"
  if ! "$@"; then
    echo "failed: $name" >&2
    exit 1
  fi
}
expect_fail() {
  local name=$1
  shift
  echo "check: $name"
  if "$@" >/dev/null 2>&1; then
    echo "failed: $name unexpectedly succeeded" >&2
    exit 1
  fi
}

expect_ok "file mode" docker run --rm --platform "$platform" -v "$fixtures/valid.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_ok "template mode" docker run --rm --platform "$platform" -v "$fixtures/template.json:/template.json:ro" -v "$fixtures/template-values.json:/values.json:ro" "$IMAGE" test --mode template --template /template.json --values /values.json
encoded=$(base64 -w0 "$fixtures/valid.json")
expect_ok "env-base64 mode" docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$encoded" "$IMAGE" test --mode env-base64
invalid_encoded=$(base64 -w0 "$fixtures/invalid-json.json")
expect_fail "env-base64 rejects invalid JSON" docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$invalid_encoded" "$IMAGE" test --mode env-base64
expect_fail "template mode rejects missing sources" docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$encoded" "$IMAGE" test --mode template --template /template.json --values /values.json
expect_fail "file mode rejects invalid JSON" docker run --rm --platform "$platform" -v "$fixtures/invalid-json.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_fail "Xray rejects invalid semantics" docker run --rm --platform "$platform" -v "$fixtures/invalid-semantic.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_fail "template mode rejects missing parameter" docker run --rm --platform "$platform" -v "$fixtures/template.json:/template.json:ro" -v "$fixtures/template-values-missing.json:/values.json:ro" "$IMAGE" test --mode template --template /template.json --values /values.json
expect_ok "XHTTP stream-one fixture" docker run --rm --platform "$platform" -v "$fixtures/xhttp-stream-one.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json

# A running container proves run execs the validated stdin configuration without a named config path.
running_encoded=$(base64 -w0 "$fixtures/running.json")
echo "check: generated-config stdin lifecycle"
cid=$(docker run -d --platform "$platform" -e "XRAY_CONFIG_BASE64=$running_encoded" "$IMAGE" run --mode env-base64)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
sleep 2
if test "$(docker inspect -f '{{.State.Running}}' "$cid")" != true; then
  echo "generated-configuration runtime did not remain running" >&2
  exit 1
fi
docker rm -f "$cid" >/dev/null
trap - EXIT

echo "check: numeric runtime identity"
if test "$(docker image inspect -f '{{.Config.User}}' "$IMAGE")" != "65532:65532"; then
  echo "failed: runtime user is not 65532:65532" >&2
  exit 1
fi

echo "check: exact final filesystem"
created=$(docker create --platform "$platform" "$IMAGE")
trap 'docker rm -f "$created" >/dev/null 2>&1 || true' EXIT
inspection=$(mktemp -d)
trap 'docker rm -f "$created" >/dev/null 2>&1 || true; rm -rf -- "$inspection"' EXIT
docker export -o "$inspection/rootfs.tar" "$created"
mkdir "$inspection/rootfs"
tar -xf "$inspection/rootfs.tar" -C "$inspection/rootfs"
actual=$(find "$inspection/rootfs" -type f -printf '%P\n' | sort)
expected=$(printf '%s\n' etc/ssl/certs/ca-certificates.crt usr/local/bin/xray usr/local/bin/xray-entry usr/local/share/xray/geoip.dat usr/local/share/xray/geosite.dat | sort)
if test "$actual" != "$expected"; then
  echo "failed: unexpected regular-file set in final image" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
  exit 1
fi
if test ! -d "$inspection/rootfs/tmp" || test "$(stat -c '%a' "$inspection/rootfs/tmp")" != 1777; then
  echo "failed: /tmp is absent or is not mode 1777" >&2
  exit 1
fi
if find "$inspection/rootfs" -type l -print -quit | grep -q .; then
  echo "failed: symlink found in final image" >&2
  exit 1
fi
for forbidden in bin/sh bin/bash busybox curl wget ssh apk apt apt-get dpkg yum dnf; do
  if printf '%s\n' "$actual" | grep -Eq "(^|/)$forbidden($|/)"; then
    echo "forbidden runtime file: $forbidden" >&2
    exit 1
  fi
done
docker rm -f "$created" >/dev/null
rm -rf -- "$inspection"
trap - EXIT
echo "check: exact Xray version"
if ! docker run --rm --platform "$platform" --entrypoint /usr/local/bin/xray "$IMAGE" version | grep -E '^Xray 26\.7\.28 '; then
  echo "failed: exact Xray version check" >&2
  exit 1
fi
echo "integration and final-filesystem checks passed"
