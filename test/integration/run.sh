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
expect_fail "file mode rejects duplicate JSON keys" docker run --rm --platform "$platform" -v "$fixtures/duplicate-json.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_fail "Xray rejects invalid semantics" docker run --rm --platform "$platform" -v "$fixtures/invalid-semantic.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_fail "template mode rejects missing parameter" docker run --rm --platform "$platform" -v "$fixtures/template.json:/template.json:ro" -v "$fixtures/template-values-missing.json:/values.json:ro" "$IMAGE" test --mode template --template /template.json --values /values.json
expect_fail "Xray rejects template type mismatch" docker run --rm --platform "$platform" -v "$fixtures/template.json:/template.json:ro" -v "$fixtures/template-values-wrong-type.json:/values.json:ro" "$IMAGE" test --mode template --template /template.json --values /values.json
expect_ok "XHTTP stream-one fixture" docker run --rm --platform "$platform" -v "$fixtures/xhttp-stream-one.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
expect_ok "runtime identity can read GeoIP and geosite assets" docker run --rm --platform "$platform" -v "$fixtures/geodata.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json

security_inspection=$(mktemp -d)
trap 'rm -rf -- "$security_inspection"' EXIT
cp "$fixtures/valid.json" "$security_inspection/non-writable.json"
chmod 0444 "$security_inspection/non-writable.json"
expect_ok "file mode accepts a non-writable file on a read-write mount" docker run --rm --platform "$platform" -v "$security_inspection/non-writable.json:/config.json:rw" "$IMAGE" test --mode file --config /config.json
cp "$fixtures/valid.json" "$security_inspection/non-runtime-owned.json"
chmod 0644 "$security_inspection/non-runtime-owned.json"
expect_ok "file mode uses runtime access instead of an unrelated owner-write bit" docker run --rm --platform "$platform" -v "$security_inspection/non-runtime-owned.json:/config.json:rw" "$IMAGE" test --mode file --config /config.json
cp "$fixtures/valid.json" "$security_inspection/writable.json"
chmod 0666 "$security_inspection/writable.json"
expect_fail "file mode rejects an actually writable file" docker run --rm --platform "$platform" -v "$security_inspection/writable.json:/config.json:rw" "$IMAGE" test --mode file --config /config.json
expect_ok "file mode accepts writable bits on a kernel read-only mount" docker run --rm --platform "$platform" -v "$security_inspection/writable.json:/config.json:ro" "$IMAGE" test --mode file --config /config.json
if ! cmp -s "$fixtures/valid.json" "$security_inspection/writable.json"; then
  echo "failed: file-mode writeability probes changed the source" >&2
  exit 1
fi
canary=XRAY_ENTRY_CANARY_7f29c1e6
canary_json=$(printf '{"inbounds":[{"protocol":"%s"}],"outbounds":[]}' "$canary")
canary_encoded=$(printf '%s' "$canary_json" | base64 -w0)
echo "check: validation errors do not reveal configuration values"
if canary_output=$(docker run --rm --platform "$platform" -e "XRAY_CONFIG_BASE64=$canary_encoded" "$IMAGE" test --mode env-base64 2>&1); then
  echo "failed: canary configuration unexpectedly validated" >&2
  exit 1
fi
if printf '%s' "$canary_output" | grep -Fq "$canary"; then
  echo "failed: configuration value appeared in validation output" >&2
  exit 1
fi
rm -rf -- "$security_inspection"
trap - EXIT

# File mode must also validate and exec Xray as PID 1 with a stable read-only mount.
echo "check: file-mode run lifecycle"
file_cid=$(docker run -d --platform "$platform" -v "$fixtures/running.json:/config.json:ro" "$IMAGE" run --mode file --config /config.json)
trap 'docker rm -f "$file_cid" >/dev/null 2>&1 || true' EXIT
sleep 2
if test "$(docker inspect -f '{{.State.Running}}' "$file_cid")" != true; then
  echo "failed: file-mode runtime did not remain running" >&2
  exit 1
fi
docker rm -f "$file_cid" >/dev/null
trap - EXIT

# A running container proves run execs the validated stdin configuration without a named config path.
running_encoded=$(base64 -w0 "$fixtures/running.json")
echo "check: generated-config stdin lifecycle"
cid=$(docker run -d --platform "$platform" -e "XRAY_CONFIG_BASE64=$running_encoded" "$IMAGE" run --mode env-base64)
lifecycle_inspection=$(mktemp -d)
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true; rm -rf -- "$lifecycle_inspection"' EXIT
sleep 2
if test "$(docker inspect -f '{{.State.Running}}' "$cid")" != true; then
  echo "generated-configuration runtime did not remain running" >&2
  exit 1
fi
docker export -o "$lifecycle_inspection/rootfs.tar" "$cid"
if tar -tf "$lifecycle_inspection/rootfs.tar" | grep -Eq '(^|/)tmp/xray-entry-'; then
  echo "failed: named generated configuration remains in /tmp" >&2
  exit 1
fi
docker rm -f "$cid" >/dev/null
rm -rf -- "$lifecycle_inspection"
trap - EXIT

echo "check: image platform"
if test "$(docker image inspect -f '{{.Os}}/{{.Architecture}}' "$IMAGE")" != "$platform"; then
  echo "failed: image platform is not linux/arm64" >&2
  exit 1
fi

echo "check: numeric runtime identity"
if test "$(docker image inspect -f '{{.Config.User}}' "$IMAGE")" != "65532:65532"; then
  echo "failed: runtime user is not 65532:65532" >&2
  exit 1
fi

echo "check: generic image metadata"
if ! command -v jq >/dev/null 2>&1; then
  echo "failed: jq is required for image inspection" >&2
  exit 1
fi
image_config=$(docker image inspect "$IMAGE" | jq -ce '.[0].Config')
if ! jq -e '.Entrypoint == ["/usr/local/bin/xray-entry"]' <<<"$image_config" >/dev/null; then
  echo "failed: image Entrypoint metadata is unexpected" >&2
  exit 1
fi
if ! jq -e '.Cmd == ["run"]' <<<"$image_config" >/dev/null; then
  echo "failed: image Cmd metadata is unexpected" >&2
  exit 1
fi
# Docker/BuildKit may inject this conventional default PATH even for scratch.
# No other environment metadata is permitted.
if ! jq -e '.Env == null or .Env == [] or .Env == ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"]' <<<"$image_config" >/dev/null; then
  echo "failed: image Env metadata is unexpected" >&2
  exit 1
fi
for metadata_field in ExposedPorts Volumes; do
  if ! jq -e --arg field "$metadata_field" '.[$field] == null or .[$field] == {}' <<<"$image_config" >/dev/null; then
    echo "failed: image $metadata_field metadata is not empty" >&2
    exit 1
  fi
done
if ! jq -e '.Healthcheck == null or .Healthcheck == {}' <<<"$image_config" >/dev/null; then
  echo "failed: image Healthcheck metadata is not empty" >&2
  exit 1
fi
if ! jq -e '.Shell == null or .Shell == []' <<<"$image_config" >/dev/null; then
  echo "failed: image Shell metadata is not empty" >&2
  exit 1
fi

echo "check: exact final filesystem"
created=$(docker create --platform "$platform" "$IMAGE")
trap 'docker rm -f "$created" >/dev/null 2>&1 || true' EXIT
inspection=$(mktemp -d)
trap 'docker rm -f "$created" >/dev/null 2>&1 || true; rm -rf -- "$inspection"' EXIT
docker export -o "$inspection/rootfs.tar" "$created"
mkdir "$inspection/rootfs"
# Archive headers remain the authority for image modes and ownership. The
# disposable extraction is made traversable for an unprivileged CI runner.
tar --no-same-owner -xf "$inspection/rootfs.tar" -C "$inspection/rootfs"
chmod -R u+rwX "$inspection/rootfs"
actual=$(find "$inspection/rootfs" -type f -printf '%P\n' | sort)
# Docker injects these files when it creates a container; they are not image-layer files.
runtime_injected='^(\.dockerenv|dev/console|etc/hostname|etc/hosts|etc/resolv\.conf)$'
image_files=$(printf '%s\n' "$actual" | grep -Ev "$runtime_injected" || true)
expected=$(printf '%s\n' etc/ssl/certs/ca-certificates.crt usr/local/bin/xray usr/local/bin/xray-entry usr/local/share/xray/geoip.dat usr/local/share/xray/geosite.dat | sort)
if test "$image_files" != "$expected"; then
  echo "failed: unexpected regular-file set in runtime container" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$image_files") >&2 || true
  exit 1
fi

docker image save -o "$inspection/image.tar" "$IMAGE"
mkdir "$inspection/image-archive" "$inspection/image-rootfs"
tar -xf "$inspection/image.tar" -C "$inspection/image-archive"
mapfile -t layers < <(jq -r '.[0].Layers[]' "$inspection/image-archive/manifest.json")
if test "${#layers[@]}" -eq 0; then
  echo "failed: saved image has no filesystem layers" >&2
  exit 1
fi
expected_directories=$(printf '%s\n' etc etc/ssl etc/ssl/certs tmp usr usr/local usr/local/bin usr/local/share usr/local/share/xray | sort)
while IFS= read -r directory; do
  mkdir -p "$inspection/image-rootfs/$directory"
done <<<"$expected_directories"
layer_listing="$inspection/layer-listing.txt"
: >"$layer_listing"
for layer in "${layers[@]}"; do
  if tar -tf "$inspection/image-archive/$layer" | grep -Eq '(^|/)\.wh\.'; then
    echo "failed: whiteout found in final scratch-image layers" >&2
    exit 1
  fi
  layer_metadata=$(tar --numeric-owner -tvf "$inspection/image-archive/$layer")
  printf '%s\n' "$layer_metadata" >>"$layer_listing"
  if printf '%s\n' "$layer_metadata" | awk '$2 != "0/0" { found=1 } END { exit found ? 0 : 1 }'; then
    echo "failed: non-root-owned entry found in final image layers" >&2
    exit 1
  fi
  if printf '%s\n' "$layer_metadata" | awk '$1 !~ /^[-d]/ { found=1 } END { exit found ? 0 : 1 }'; then
    echo "failed: non-file, non-directory object found in final image layers" >&2
    exit 1
  fi
  # Keep the disposable directory tree writable while applying later layers;
  # authoritative modes are checked from the ordered layer listings below.
  tar --no-same-owner --no-overwrite-dir -xf "$inspection/image-archive/$layer" -C "$inspection/image-rootfs"
done
layer_files=$(find "$inspection/image-rootfs" -type f -printf '%P\n' | sort)
if test "$layer_files" != "$expected"; then
  echo "failed: unexpected regular-file set in final image layers" >&2
  diff -u <(printf '%s\n' "$expected") <(printf '%s\n' "$layer_files") >&2 || true
  exit 1
fi
layer_directories=$(awk '$1 ~ /^d/ { path=$NF; sub(/^\.\//, "", path); sub(/\/$/, "", path); if (path != "" && path != ".") print path }' "$layer_listing" | sort -u)
if test "$layer_directories" != "$expected_directories"; then
  echo "failed: unexpected directory set in final image layers" >&2
  diff -u <(printf '%s\n' "$expected_directories") <(printf '%s\n' "$layer_directories") >&2 || true
  exit 1
fi
while IFS= read -r directory; do
  expected_metadata=dr-xr-xr-x:0/0
  if test "$directory" = tmp; then
    expected_metadata=drwxrwxrwt:0/0
  fi
  directory_metadata=$(awk -v wanted="$directory" '$1 ~ /^d/ { path=$NF; sub(/^\.\//, "", path); sub(/\/$/, "", path); if (path == wanted) metadata=$1 ":" $2 } END { print metadata }' "$layer_listing")
  if test "$directory_metadata" != "$expected_metadata"; then
    echo "failed: directory $directory layer metadata is $directory_metadata, expected $expected_metadata" >&2
    exit 1
  fi
done <<<"$layer_directories"
if test ! -d "$inspection/rootfs/tmp"; then
  echo "failed: /tmp is absent" >&2
  exit 1
fi
tmp_archive_metadata=$(tar --numeric-owner -tvf "$inspection/rootfs.tar" | awk '$NF == "tmp" || $NF == "tmp/" || $NF == "./tmp" || $NF == "./tmp/" {print $1 ":" $2}')
if test "$tmp_archive_metadata" != 'drwxrwxrwt:0/0'; then
  echo "failed: /tmp archive mode/owner is $tmp_archive_metadata, expected drwxrwxrwt:0/0" >&2
  exit 1
fi
runtime_symlinks=$(find "$inspection/rootfs" -type l -printf '%P\n' | sort)
if test -n "$runtime_symlinks" && test "$runtime_symlinks" != etc/mtab; then
  echo "failed: unexpected runtime symlink found" >&2
  exit 1
fi
if test -L "$inspection/rootfs/etc/mtab" && test "$(readlink "$inspection/rootfs/etc/mtab")" != /proc/mounts; then
  echo "failed: runtime /etc/mtab symlink has an unexpected target" >&2
  exit 1
fi
for required in etc/ssl/certs/ca-certificates.crt usr/local/share/xray/geoip.dat usr/local/share/xray/geosite.dat; do
  if test ! -s "$inspection/rootfs/$required"; then
    echo "failed: required runtime data file $required is empty" >&2
    exit 1
  fi
done
for executable in usr/local/bin/xray usr/local/bin/xray-entry; do
  archive_metadata=$(tar --numeric-owner -tvf "$inspection/rootfs.tar" | awk -v path="$executable" '$NF == path || $NF == "./" path {print $1 ":" $2}')
  if test "$archive_metadata" != '-r-xr-xr-x:0/0'; then
    echo "failed: $executable archive mode/owner is not 0555:0:0" >&2
    exit 1
  fi
done
for data_file in etc/ssl/certs/ca-certificates.crt usr/local/share/xray/geoip.dat usr/local/share/xray/geosite.dat; do
  archive_metadata=$(tar --numeric-owner -tvf "$inspection/rootfs.tar" | awk -v path="$data_file" '$NF == path || $NF == "./" path {print $1 ":" $2}')
  if test "$archive_metadata" != '-r--r--r--:0/0'; then
    echo "failed: $data_file archive mode/owner is not 0444:0:0" >&2
    exit 1
  fi
done
if grep -R -a -Fq "$canary" "$inspection/rootfs" "$inspection/image-rootfs"; then
  echo "failed: runtime canary found in final filesystem" >&2
  exit 1
fi
for forbidden in bin/sh bin/bash busybox curl wget ssh apk apt apt-get dpkg yum dnf; do
  if printf '%s\n' "$actual" | grep -Eq "(^|/)$forbidden($|/)"; then
    echo "forbidden runtime file: $forbidden" >&2
    exit 1
  fi
done
if ! command -v readelf >/dev/null 2>&1; then
  echo "failed: readelf is required for static ELF inspection" >&2
  exit 1
fi
for binary in usr/local/bin/xray usr/local/bin/xray-entry; do
  if ! readelf -h "$inspection/rootfs/$binary" >/dev/null 2>&1; then
    echo "failed: $binary is not a readable ELF executable" >&2
    exit 1
  fi
  if readelf -lW "$inspection/rootfs/$binary" | grep -q ' INTERP '; then
    echo "failed: $binary requires a dynamic loader" >&2
    exit 1
  fi
done
docker rm -f "$created" >/dev/null
rm -rf -- "$inspection"
trap - EXIT
echo "check: exact Xray version"
if ! docker run --rm --platform "$platform" "$IMAGE" version | grep -E '^Xray 26\.7\.28 '; then
  echo "failed: exact Xray version check" >&2
  exit 1
fi
echo "check: UUID command"
generated_uuid=$(docker run --rm --platform "$platform" "$IMAGE" uuid)
if ! printf '%s\n' "$generated_uuid" | grep -Eq '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
  echo "failed: UUID command output is invalid" >&2
  exit 1
fi
echo "image size bytes: $(docker image inspect -f '{{.Size}}' "$IMAGE")"
echo "integration and final-filesystem checks passed"
