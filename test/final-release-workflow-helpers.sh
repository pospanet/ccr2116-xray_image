#!/usr/bin/env bash

# This file is sourced by a workflow block that calls inspect_reference from
# conditional contexts. Do not rely on errexit here: every fallible operation
# in the helper must have explicit status handling.

# inspect_reference returns this status only when the first registry lookup
# fails. Callers must still validate the captured error before treating the
# reference as absent. Every other inspection failure returns status 1.
readonly INSPECT_REFERENCE_LOOKUP_FAILED=10

inspect_reference() {
  local reference=${1:-}
  local label=${2:-}
  local expected_digest=${3:-}
  local manifest_file image_file
  local digest media_type os arch

  if [[ -z $reference ]]; then
    echo 'registry inspection reference is empty' >&2
    return 1
  fi
  if [[ ! $label =~ ^[a-z0-9-]+$ ]]; then
    echo 'registry inspection label is invalid' >&2
    return 1
  fi
  if [[ -z ${work_dir:-} || ! -d $work_dir || -L $work_dir ]]; then
    echo 'registry inspection work directory is unsafe' >&2
    return 1
  fi

  manifest_file="$work_dir/${label}-manifest.json"
  image_file="$work_dir/${label}-image.json"

  if docker buildx imagetools inspect "$reference" --format '{{json .Manifest}}' > "$manifest_file"; then
    :
  else
    echo "registry manifest inspection failed for $reference" >&2
    return "$INSPECT_REFERENCE_LOOKUP_FAILED"
  fi
  if docker buildx imagetools inspect "$reference" --format '{{json .Image}}' > "$image_file"; then
    :
  else
    echo "registry image inspection failed for $reference" >&2
    return 1
  fi
  if digest=$(jq -er '.digest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))' "$manifest_file"); then
    :
  else
    echo "$label manifest digest extraction failed" >&2
    return 1
  fi
  if media_type=$(jq -er '.mediaType | select(type == "string")' "$manifest_file"); then
    :
  else
    echo "$label manifest media type extraction failed" >&2
    return 1
  fi
  if os=$(jq -er '.os | select(type == "string")' "$image_file"); then
    :
  else
    echo "$label image OS extraction failed" >&2
    return 1
  fi
  if arch=$(jq -er '.architecture | select(type == "string")' "$image_file"); then
    :
  else
    echo "$label image architecture extraction failed" >&2
    return 1
  fi

  if [[ -n $expected_digest ]]; then
    if bash test/validate-final-release.sh validate-remote \
      "$label" "$digest" "$media_type" "$os" "$arch" "$expected_digest"; then
      :
    else
      return 1
    fi
  else
    if bash test/validate-final-release.sh validate-remote \
      "$label" "$digest" "$media_type" "$os" "$arch"; then
      :
    else
      return 1
    fi
  fi

  if printf '%s' "$digest"; then
    :
  else
    return 1
  fi
}
