#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
validator="$repo_root/test/validate-final-release.sh"
tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
log_file="$tmp_dir/test.log"
pass_count=0

expect_pass() {
  local name=$1
  shift
  if "$@" >"$log_file" 2>&1; then
    ((pass_count += 1))
  else
    echo "expected PASS: $name" >&2
    sed 's/^/  /' "$log_file" >&2
    exit 1
  fi
}

expect_fail() {
  local name=$1
  shift
  if "$@" >"$log_file" 2>&1; then
    echo "expected FAIL: $name" >&2
    exit 1
  fi
  ((pass_count += 1))
}

make_case() {
  local name=$1
  local target="$tmp_dir/$name"
  if git clone --quiet "$base_fixture" "$target"; then
    :
  else
    return 1
  fi
  printf '%s' "$target"
}

base_fixture="$tmp_dir/base"
git clone --quiet "$repo_root" "$base_fixture"
mkdir -p "$base_fixture/release/final"
cp "$repo_root/.env" "$base_fixture/.env"
cp "$repo_root/Dockerfile" "$base_fixture/Dockerfile"
cp "$repo_root/docs/HARDWARE-ACCEPTANCE.md" "$base_fixture/docs/HARDWARE-ACCEPTANCE.md"
cp "$repo_root/test/validate-metadata.sh" "$base_fixture/test/validate-metadata.sh"
cp "$repo_root/test/validate-final-release.sh" "$base_fixture/test/validate-final-release.sh"
cp "$repo_root/test/final-release-workflow-helpers.sh" "$base_fixture/test/final-release-workflow-helpers.sh"
cp "$repo_root/release/final/v0.2.env" "$base_fixture/release/final/v0.2.env"
cp "$repo_root/.github/workflows/release-xray.yaml" "$base_fixture/.github/workflows/release-xray.yaml"
git -C "$base_fixture" add .
if ! git -C "$base_fixture" diff --cached --quiet; then
  git -C "$base_fixture" -c user.name=fixture -c user.email=fixture.invalid commit --quiet -m fixture
fi
git -C "$base_fixture" tag -f v0.2
fixture_head=$(git -C "$base_fixture" rev-parse HEAD)

expect_pass "valid v0.2 provenance" \
  "$validator" --repo-root "$base_fixture" preauth tag v0.2 "$fixture_head"

case_dir=$(make_case malformed-tag)
expect_fail "malformed final tag" \
  "$validator" --repo-root "$case_dir" preauth tag v0.2.0 "$fixture_head"

case_dir=$(make_case version-mismatch)
cp "$case_dir/release/final/v0.2.env" "$case_dir/release/final/v0.3.env"
sed -i 's/^WRAPPER_RELEASE=0\.2$/WRAPPER_RELEASE=0.3/' "$case_dir/release/final/v0.3.env"
expect_fail "final version mismatch" \
  "$validator" --repo-root "$case_dir" repository v0.3

case_dir=$(make_case wrong-source)
sed -i 's/^ACCEPTED_SOURCE_SHA=.*/ACCEPTED_SOURCE_SHA=0000000000000000000000000000000000000000/' "$case_dir/release/final/v0.2.env"
expect_fail "wrong accepted source SHA" \
  "$validator" --repo-root "$case_dir" repository v0.2

case_dir=$(make_case rc-suffix)
sed -i 's/^ACCEPTED_RC_TAG=.*/ACCEPTED_RC_TAG=rc-v0.2-000000000000/' "$case_dir/release/final/v0.2.env"
expect_fail "accepted RC suffix mismatch" \
  "$validator" --repo-root "$case_dir" repository v0.2

case_dir=$(make_case duplicate-rc)
printf '%s\n' 'ACCEPTED_RC_TAG=rc-v0.2-ce1f39efaafc' >> "$case_dir/release/final/v0.2.env"
expect_fail "ambiguous accepted RC metadata" \
  "$validator" --repo-root "$case_dir" repository v0.2

case_dir=$(make_case missing-rc)
rm -f -- "$case_dir/release/final/v0.2.env"
expect_fail "missing accepted RC metadata" \
  "$validator" --repo-root "$case_dir" repository v0.2

case_dir=$(make_case hardware-fail)
sed -i 's/^HARDWARE_ACCEPTANCE=PASS$/HARDWARE_ACCEPTANCE=FAIL/' "$case_dir/release/final/v0.2.env"
expect_fail "hardware acceptance not PASS" \
  "$validator" --repo-root "$case_dir" repository v0.2

accepted=sha256:a100a4b10ef8aefb658fa9f54359839f983fcab6dbd40431780e09e36bde0ba8
different=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

expect_pass "all-tag registry immutability enabled" \
  "$validator" validate-immutability true 1
expect_fail "registry immutability disabled" \
  "$validator" validate-immutability false 1
expect_fail "missing accepted RC image" \
  "$validator" require-rc-state missing
expect_pass "accepted RC image exists" \
  "$validator" require-rc-state present
expect_pass "valid linux/arm64 RC descriptor" \
  "$validator" validate-remote accepted-rc "$accepted" application/vnd.docker.distribution.manifest.v2+json linux arm64
expect_fail "RC tag changed from the bound digest" \
  "$validator" validate-remote accepted-rc "$different" application/vnd.docker.distribution.manifest.v2+json linux arm64 "$accepted"
expect_fail "wrong RC architecture" \
  "$validator" validate-remote accepted-rc "$accepted" application/vnd.docker.distribution.manifest.v2+json linux amd64
expect_pass "final absent permits promotion" \
  "$validator" decide-final "$accepted" missing
expect_pass "same final digest is idempotent" \
  "$validator" decide-final "$accepted" present "$accepted"
expect_fail "different final digest refuses overwrite" \
  "$validator" decide-final "$accepted" present "$different"
expect_pass "promotion preserved digest" \
  "$validator" validate-promotion "$accepted" "$accepted"
expect_fail "promotion returned a different digest" \
  "$validator" validate-promotion "$accepted" "$different"
expect_pass "post-promotion digest equality" \
  "$validator" verify-post "$accepted" "$accepted" "$accepted"
expect_fail "post-promotion source/final mismatch" \
  "$validator" verify-post "$accepted" "$accepted" "$different"

missing_error="$tmp_dir/missing-error.txt"
printf '%s\n' 'ERROR: pospa/xray-core:26.7.28-0.2-arm64: not found' > "$missing_error"
expect_pass "explicit final-tag absence" \
  "$validator" missing-error pospa/xray-core:26.7.28-0.2-arm64 "$missing_error"
printf '%s\n' 'ERROR: registry request timed out' > "$missing_error"
expect_fail "indeterminate registry error" \
  "$validator" missing-error pospa/xray-core:26.7.28-0.2-arm64 "$missing_error"

printf 'final-release validation tests passed: %d\n' "$pass_count"
