#!/usr/bin/env bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
cd "$repo_root"

source test/final-release-workflow-helpers.sh

tmp_dir=$(mktemp -d)
trap 'rm -rf -- "$tmp_dir"' EXIT
mock_bin="$tmp_dir/bin"
mkdir -p "$mock_bin"

cat > "$mock_bin/docker" <<'EOF'
#!/usr/bin/env bash
set -u

count=0
if [[ -f $MOCK_DOCKER_COUNT ]]; then
  read -r count < "$MOCK_DOCKER_COUNT"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$MOCK_DOCKER_COUNT"

case "$MOCK_SCENARIO:$count" in
  absent:1)
    echo "ERROR: $MOCK_REFERENCE: manifest unknown" >&2
    exit 1
    ;;
  unexpected-error:1)
    echo "ERROR: $MOCK_REFERENCE: registry request timed out" >&2
    exit 1
    ;;
  second-inspect-not-found:2)
    echo "ERROR: $MOCK_REFERENCE: not found" >&2
    exit 1
    ;;
  conditional-regression:1)
    echo "ERROR: $MOCK_REFERENCE: manifest unknown" >&2
    exit 42
    ;;
esac

# Every command after the selected failure succeeds. This is intentional: the
# conditional-context regression must prove that inspect_reference returns
# immediately instead of reaching a later successful command.
printf '%s\n' '{}'
EOF

cat > "$mock_bin/jq" <<'EOF'
#!/usr/bin/env bash
set -u

printf '%s\n' "$*" >> "$MOCK_JQ_LOG"
if [[ $MOCK_SCENARIO == jq-parse-failure ]]; then
  echo 'parse error: malformed registry JSON' >&2
  exit 4
fi

query=$*
case "$query" in
  *'.digest'*)
    case "$MOCK_SCENARIO" in
      missing-digest|conditional-regression) printf '' ;;
      malformed-digest) printf '%s\n' 'sha256:not-a-digest' ;;
      different-digest) printf '%s\n' 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' ;;
      *) printf '%s\n' 'sha256:a100a4b10ef8aefb658fa9f54359839f983fcab6dbd40431780e09e36bde0ba8' ;;
    esac
    ;;
  *'.mediaType'*)
    printf '%s\n' 'application/vnd.docker.distribution.manifest.v2+json'
    ;;
  *'.os'*)
    printf '%s\n' linux
    ;;
  *'.architecture'*)
    if [[ $MOCK_SCENARIO == validate-remote-failure ]]; then
      printf '%s\n' amd64
    else
      printf '%s\n' arm64
    fi
    ;;
  *)
    echo 'unexpected jq query' >&2
    exit 5
    ;;
esac
EOF

chmod +x "$mock_bin/docker" "$mock_bin/jq"
PATH="$mock_bin:$PATH"
export PATH

accepted=sha256:a100a4b10ef8aefb658fa9f54359839f983fcab6dbd40431780e09e36bde0ba8
reference=pospa/xray-core:26.7.28-0.2-arm64
pass_count=0

prepare_case() {
  local scenario=$1
  work_dir="$tmp_dir/work-$scenario"
  rm -rf -- "$work_dir"
  mkdir -p "$work_dir"
  MOCK_SCENARIO=$scenario
  MOCK_REFERENCE=$reference
  MOCK_DOCKER_COUNT="$work_dir/docker-count"
  MOCK_JQ_LOG="$work_dir/jq-calls"
  export MOCK_SCENARIO MOCK_REFERENCE MOCK_DOCKER_COUNT MOCK_JQ_LOG
}

record_pass() {
  local name=$1
  ((pass_count += 1))
  printf 'PASS: %s\n' "$name"
}

fail_test() {
  local name=$1
  echo "expected PASS: $name" >&2
  exit 1
}

prepare_case valid-rc
if digest=$(inspect_reference "$reference" accepted-rc "$accepted"); then
  [[ $digest == "$accepted" ]] || fail_test 'valid RC digest'
else
  fail_test 'valid RC inspection'
fi
record_pass 'valid RC inspection'

prepare_case absent
absent_error="$work_dir/inspect-error"
if digest=$(inspect_reference "$reference" final-image 2>"$absent_error"); then
  fail_test 'absent final tag returned failure'
else
  inspect_status=$?
fi
[[ $inspect_status -eq $INSPECT_REFERENCE_LOOKUP_FAILED ]] \
  || fail_test 'absent final tag used lookup-failed status'
if bash test/validate-final-release.sh missing-error "$reference" "$absent_error"; then
  :
else
  fail_test 'absent final tag had an explicit missing error'
fi
if decision=$(bash test/validate-final-release.sh decide-final "$accepted" missing); then
  [[ $decision == promote ]] || fail_test 'absent final tag selected promote'
else
  fail_test 'absent final tag decision'
fi
record_pass 'final absent selects promote'

prepare_case valid-final
if digest=$(inspect_reference "$reference" final-image); then
  :
else
  fail_test 'existing final tag inspection'
fi
if decision=$(bash test/validate-final-release.sh decide-final "$accepted" present "$digest"); then
  [[ $decision == idempotent ]] || fail_test 'same final digest selected idempotent'
else
  fail_test 'same final digest decision'
fi
record_pass 'same final digest selects idempotent'

prepare_case unexpected-error
unexpected_error="$work_dir/inspect-error"
if digest=$(inspect_reference "$reference" final-image 2>"$unexpected_error"); then
  fail_test 'unexpected registry error propagated'
else
  inspect_status=$?
fi
[[ $inspect_status -eq $INSPECT_REFERENCE_LOOKUP_FAILED ]] \
  || fail_test 'unexpected registry lookup returned lookup-failed status'
if bash test/validate-final-release.sh missing-error "$reference" "$unexpected_error" >/dev/null 2>&1; then
  fail_test 'unexpected registry error rejected as indeterminate'
fi
record_pass 'unexpected registry error fails closed'

for scenario in missing-digest malformed-digest jq-parse-failure validate-remote-failure; do
  prepare_case "$scenario"
  if digest=$(inspect_reference "$reference" final-image >/dev/null 2>"$work_dir/inspect-error"); then
    fail_test "$scenario propagated failure"
  else
    inspect_status=$?
  fi
  [[ $inspect_status -eq 1 ]] || fail_test "$scenario returned internal-failure status"
  record_pass "$scenario propagates failure"
done

prepare_case different-digest
if digest=$(inspect_reference "$reference" final-image); then
  :
else
  fail_test 'different final digest inspection'
fi
if bash test/validate-final-release.sh decide-final "$accepted" present "$digest" >/dev/null 2>&1; then
  fail_test 'different final digest refused overwrite'
fi
record_pass 'different final digest fails closed'

prepare_case second-inspect-not-found
if digest=$(inspect_reference "$reference" final-image >/dev/null 2>"$work_dir/inspect-error"); then
  fail_test 'second inspect failure propagated'
else
  inspect_status=$?
fi
[[ $inspect_status -eq 1 ]] || fail_test 'second inspect failure cannot mean absent'
record_pass 'only the first registry lookup can signal absence'

prepare_case conditional-regression
regression_error="$work_dir/inspect-error"
if regression_digest=$(inspect_reference "$reference" final-image 2>"$regression_error"); then
  fail_test 'conditional-context first-command failure propagated'
else
  inspect_status=$?
fi
[[ $inspect_status -eq $INSPECT_REFERENCE_LOOKUP_FAILED ]] \
  || fail_test 'conditional-context failure status'
[[ -z $regression_digest ]] || fail_test 'conditional-context failure emitted no digest'
[[ $(<"$MOCK_DOCKER_COUNT") -eq 1 ]] || fail_test 'conditional-context returned before later docker command'
[[ ! -e $MOCK_JQ_LOG ]] || fail_test 'conditional-context returned before later jq command'
record_pass 'conditional-context failure cannot be masked by later success'

printf 'final-release workflow tests passed: %d\n' "$pass_count"
