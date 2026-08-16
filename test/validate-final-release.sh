#!/usr/bin/env bash
set -euo pipefail

die() {
  echo "final-release validation failed: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage:
  validate-final-release.sh [--repo-root PATH] repository vMAJOR.MINOR
  validate-final-release.sh [--repo-root PATH] preauth tag vMAJOR.MINOR GITHUB_SHA [GITHUB_OUTPUT]
  validate-final-release.sh validate-immutability ENABLED ALL_TAG_RULE_COUNT
  validate-final-release.sh require-rc-state STATE
  validate-final-release.sh validate-remote LABEL DIGEST MEDIA_TYPE OS ARCH [EXPECTED_DIGEST]
  validate-final-release.sh decide-final ACCEPTED_DIGEST STATE [FINAL_DIGEST]
  validate-final-release.sh validate-promotion ACCEPTED_DIGEST PROMOTED_DIGEST
  validate-final-release.sh verify-post ACCEPTED_DIGEST RC_DIGEST FINAL_DIGEST
  validate-final-release.sh missing-error REFERENCE ERROR_FILE
EOF
  exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
if [[ ${1:-} == --repo-root ]]; then
  [[ $# -ge 3 ]] || usage
  repo_root=$2
  shift 2
fi

is_digest() {
  [[ $1 =~ ^sha256:[0-9a-f]{64}$ ]]
}

metadata_value() {
  local key=$1
  local file=$2
  local count value
  count=$(grep -c "^${key}=" "$file" || true)
  [[ $count -eq 1 ]] || die "$file must contain exactly one $key"
  value=$(grep "^${key}=" "$file")
  printf '%s' "${value#*=}"
}

declare -A parsed_metadata=()
parse_release_metadata() {
  local file=$1
  local line key value
  local line_count=0
  local -a required=(
    WRAPPER_RELEASE
    XRAY_VERSION
    PLATFORM
    ACCEPTED_SOURCE_SHA
    ACCEPTED_RC_TAG
    ACCEPTED_MANIFEST_DIGEST
    HARDWARE_ACCEPTANCE
    HARDWARE_ACCEPTANCE_RECORD
  )

  [[ -f $file && ! -L $file ]] || die "$file must be a regular, non-symlink file"
  parsed_metadata=()
  while IFS= read -r line || [[ -n $line ]]; do
    ((line_count += 1))
    [[ $line =~ ^([A-Z][A-Z0-9_]*)=([A-Za-z0-9._/:+-]+)$ ]] \
      || die "$file contains malformed metadata"
    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    case "$key" in
      WRAPPER_RELEASE|XRAY_VERSION|PLATFORM|ACCEPTED_SOURCE_SHA|ACCEPTED_RC_TAG|ACCEPTED_MANIFEST_DIGEST|HARDWARE_ACCEPTANCE|HARDWARE_ACCEPTANCE_RECORD) ;;
      *) die "$file contains an unknown metadata key" ;;
    esac
    [[ ! ${parsed_metadata[$key]+present} ]] || die "$file contains duplicate metadata"
    parsed_metadata[$key]=$value
  done < "$file"

  [[ $line_count -eq ${#required[@]} ]] || die "$file has missing or extra metadata"
  for key in "${required[@]}"; do
    [[ ${parsed_metadata[$key]+present} ]] || die "$file is missing $key"
  done
}

require_exact_evidence_line() {
  local file=$1
  local expected=$2
  local count
  count=$(grep -Fxc -- "$expected" "$file" || true)
  [[ $count -eq 1 ]] || die "hardware evidence is missing or conflicts with accepted RC metadata"
}

validate_repository_binding() {
  local final_tag=$1
  local release metadata_dir metadata_file file filename file_release
  local env_release env_xray env_platform image_name short_sha rc_image evidence
  local -a files=()
  local -A seen_releases=()

  [[ $final_tag =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] \
    || die "final Git tag must match v<major>.<minor>"
  release=${final_tag#v}

  cd "$repo_root"
  bash test/validate-metadata.sh

  env_release=$(metadata_value WRAPPER_RELEASE .env)
  env_xray=$(metadata_value XRAY_VERSION .env)
  env_platform=$(metadata_value PLATFORM .env)
  image_name=$(metadata_value IMAGE_NAME .env)
  [[ $release == "$env_release" ]] || die "final Git tag version does not match WRAPPER_RELEASE"

  metadata_dir=release/final
  [[ -d $metadata_dir && ! -L $metadata_dir ]] \
    || die "release provenance metadata directory is missing or unsafe"
  mapfile -d '' files < <(find -P "$metadata_dir" -mindepth 1 -maxdepth 1 -print0)
  [[ ${#files[@]} -gt 0 ]] || die "release provenance metadata is missing"

  metadata_file=
  for file in "${files[@]}"; do
    [[ -f $file && ! -L $file ]] || die "release provenance directory contains an unsafe entry"
    filename=$(basename -- "$file")
    [[ $filename =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.env$ ]] \
      || die "release provenance directory contains an unexpected file"
    file_release=${filename#v}
    file_release=${file_release%.env}
    parse_release_metadata "$file"
    [[ ${parsed_metadata[WRAPPER_RELEASE]} == "$file_release" ]] \
      || die "release provenance filename conflicts with WRAPPER_RELEASE"
    [[ ! ${seen_releases[$file_release]+present} ]] \
      || die "release provenance is ambiguous"
    seen_releases[$file_release]=$file
    if [[ $file_release == "$release" ]]; then
      metadata_file=$file
    fi
  done
  [[ -n $metadata_file ]] || die "release provenance metadata is missing for $final_tag"

  parse_release_metadata "$metadata_file"
  [[ ${parsed_metadata[XRAY_VERSION]} == "$env_xray" ]] \
    || die "accepted RC Xray version conflicts with repository metadata"
  [[ ${parsed_metadata[PLATFORM]} == "$env_platform" ]] \
    || die "accepted RC platform conflicts with repository metadata"
  [[ ${parsed_metadata[PLATFORM]} == linux/arm64 ]] \
    || die "final release platform must be exactly linux/arm64"
  [[ ${parsed_metadata[ACCEPTED_SOURCE_SHA]} =~ ^[0-9a-f]{40}$ ]] \
    || die "accepted source SHA must be 40 lowercase hex characters"
  short_sha=${parsed_metadata[ACCEPTED_SOURCE_SHA]:0:12}
  [[ ${parsed_metadata[ACCEPTED_RC_TAG]} == "rc-v${release}-${short_sha}" ]] \
    || die "accepted RC tag does not match release and source SHA"
  is_digest "${parsed_metadata[ACCEPTED_MANIFEST_DIGEST]}" \
    || die "accepted RC manifest digest is malformed"
  [[ ${parsed_metadata[HARDWARE_ACCEPTANCE]} == PASS ]] \
    || die "hardware acceptance is not PASS"
  [[ ${parsed_metadata[HARDWARE_ACCEPTANCE_RECORD]} == docs/HARDWARE-ACCEPTANCE.md ]] \
    || die "hardware acceptance record path is not authoritative"

  git cat-file -e "${parsed_metadata[ACCEPTED_SOURCE_SHA]}^{commit}" 2>/dev/null \
    || die "accepted source commit does not exist"
  [[ $(git rev-parse --verify "refs/tags/${parsed_metadata[ACCEPTED_RC_TAG]}^{commit}" 2>/dev/null) == "${parsed_metadata[ACCEPTED_SOURCE_SHA]}" ]] \
    || die "accepted RC Git tag does not resolve to the accepted source commit"

  evidence=${parsed_metadata[HARDWARE_ACCEPTANCE_RECORD]}
  [[ -f $evidence && ! -L $evidence ]] || die "hardware acceptance evidence is missing or unsafe"
  rc_image="${image_name}:${env_xray}-${release}-rc-${short_sha}-arm64"
  require_exact_evidence_line "$evidence" "| Source commit | \`${parsed_metadata[ACCEPTED_SOURCE_SHA]}\` |"
  require_exact_evidence_line "$evidence" "| Short source SHA | \`${short_sha}\` |"
  require_exact_evidence_line "$evidence" "| RC Git tag | \`${parsed_metadata[ACCEPTED_RC_TAG]}\` |"
  require_exact_evidence_line "$evidence" "| RC image | \`${rc_image}\` |"
  require_exact_evidence_line "$evidence" "| OCI manifest digest | \`${parsed_metadata[ACCEPTED_MANIFEST_DIGEST]}\` |"
  require_exact_evidence_line "$evidence" '| Device | MikroTik `L009UiGS-2HaxD` |'
  require_exact_evidence_line "$evidence" '| RouterOS | `7.23.3 (stable)` |'
  require_exact_evidence_line "$evidence" '| Architecture | `arm64` |'
  require_exact_evidence_line "$evidence" "**RC ${release} hardware acceptance: PASS**"
  [[ $(grep -Ec "^\\*\\*RC ${release//./\\.} hardware acceptance:" "$evidence" || true) -eq 1 ]] \
    || die "hardware acceptance evidence contains conflicting release conclusions"

  RELEASE=$release
  XRAY_VERSION=$env_xray
  PLATFORM=$env_platform
  IMAGE_NAME=$image_name
  ACCEPTED_SOURCE_SHA=${parsed_metadata[ACCEPTED_SOURCE_SHA]}
  ACCEPTED_SHORT_SHA=$short_sha
  ACCEPTED_RC_TAG=${parsed_metadata[ACCEPTED_RC_TAG]}
  ACCEPTED_MANIFEST_DIGEST=${parsed_metadata[ACCEPTED_MANIFEST_DIGEST]}
  RC_IMAGE=$rc_image
  FINAL_IMAGE="${image_name}:${env_xray}-${release}-arm64"
}

mode=${1:-}
[[ -n $mode ]] || usage
shift

case "$mode" in
  repository)
    [[ $# -eq 1 ]] || usage
    validate_repository_binding "$1"
    ;;
  preauth)
    [[ $# -ge 3 && $# -le 4 ]] || usage
    ref_type=$1
    ref_name=$2
    github_sha=$3
    output_file=${4:-}
    event_commit=
    final_tag_commit=
    [[ $ref_type == tag ]] || die "final release must be triggered by a Git tag"
    [[ $github_sha =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA must be 40 lowercase hex characters"
    validate_repository_binding "$ref_name"
    cd "$repo_root"
    event_commit=$(git rev-parse --verify "${github_sha}^{commit}" 2>/dev/null) \
      || die "GITHUB_SHA does not resolve to a commit"
    final_tag_commit=$(git rev-parse --verify "refs/tags/${ref_name}^{commit}" 2>/dev/null) \
      || die "final Git tag does not resolve to a commit"
    [[ $final_tag_commit == "$event_commit" ]] \
      || die "final Git tag does not resolve to GITHUB_SHA"
    git merge-base --is-ancestor "$ACCEPTED_SOURCE_SHA" "$event_commit" \
      || die "accepted runtime source is not an ancestor of the final release metadata commit"
    if [[ -n $output_file ]]; then
      {
        printf 'release=%s\n' "$RELEASE"
        printf 'xray_version=%s\n' "$XRAY_VERSION"
        printf 'platform=%s\n' "$PLATFORM"
        printf 'image_name=%s\n' "$IMAGE_NAME"
        printf 'accepted_source_sha=%s\n' "$ACCEPTED_SOURCE_SHA"
        printf 'accepted_short_sha=%s\n' "$ACCEPTED_SHORT_SHA"
        printf 'accepted_rc_tag=%s\n' "$ACCEPTED_RC_TAG"
        printf 'accepted_manifest_digest=%s\n' "$ACCEPTED_MANIFEST_DIGEST"
        printf 'rc_image=%s\n' "$RC_IMAGE"
        printf 'final_image=%s\n' "$FINAL_IMAGE"
      } >> "$output_file"
    fi
    ;;
  validate-immutability)
    [[ $# -eq 2 ]] || usage
    [[ $1 == true && $2 =~ ^[1-9][0-9]*$ ]] \
      || die "Docker Hub all-tag immutability is not enabled"
    ;;
  require-rc-state)
    [[ $# -eq 1 ]] || usage
    [[ $1 == present ]] || die "accepted RC image is missing or indeterminate"
    ;;
  validate-remote)
    [[ $# -ge 5 && $# -le 6 ]] || usage
    label=$1
    digest=$2
    media_type=$3
    os=$4
    arch=$5
    expected_digest=${6:-}
    [[ $label =~ ^[a-z0-9-]+$ ]] || die "remote descriptor label is invalid"
    is_digest "$digest" || die "$label has no concrete immutable manifest digest"
    case "$media_type" in
      application/vnd.docker.distribution.manifest.v2+json|application/vnd.oci.image.manifest.v1+json) ;;
      *) die "$label is not a single-platform image manifest" ;;
    esac
    [[ $os == linux && $arch == arm64 ]] || die "$label platform is not exactly linux/arm64"
    if [[ -n $expected_digest ]]; then
      is_digest "$expected_digest" || die "expected digest is malformed"
      [[ $digest == "$expected_digest" ]] || die "$label digest changed unexpectedly"
    fi
    ;;
  decide-final)
    [[ $# -ge 2 && $# -le 3 ]] || usage
    accepted_digest=$1
    state=$2
    final_digest=${3:-}
    is_digest "$accepted_digest" || die "accepted digest is malformed"
    case "$state" in
      missing)
        [[ -z $final_digest ]] || die "missing final tag unexpectedly has a digest"
        printf '%s\n' promote
        ;;
      present)
        is_digest "$final_digest" || die "existing final tag has no concrete digest"
        [[ $final_digest == "$accepted_digest" ]] \
          || die "refusing to overwrite final tag with a different digest"
        printf '%s\n' idempotent
        ;;
      *) die "final tag state is indeterminate" ;;
    esac
    ;;
  validate-promotion)
    [[ $# -eq 2 ]] || usage
    is_digest "$1" && is_digest "$2" || die "promotion digest is malformed"
    [[ $1 == "$2" ]] || die "promotion did not preserve the accepted digest"
    ;;
  verify-post)
    [[ $# -eq 3 ]] || usage
    is_digest "$1" && is_digest "$2" && is_digest "$3" \
      || die "post-promotion digest is malformed"
    [[ $1 == "$2" && $1 == "$3" ]] \
      || die "RC and final tags do not resolve to the accepted digest"
    ;;
  missing-error)
    [[ $# -eq 2 ]] || usage
    [[ -f $2 && ! -L $2 ]] || die "registry inspection error record is unsafe"
    grep -Fq -- "$1" "$2" || die "registry error does not identify the expected reference"
    grep -Eqi 'manifest unknown|no such manifest|not found' "$2" \
      || die "registry error does not prove that the tag is absent"
    ;;
  *) usage ;;
esac
