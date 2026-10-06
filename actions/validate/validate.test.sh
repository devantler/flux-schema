#!/usr/bin/env bash

# Copyright 2026 The Flux authors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
helper="$here/validate.sh"
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin" "$fixture/repository with spaces/overlay" "$fixture/empty"
cat >"$fixture/repository with spaces/configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: standalone
YAML
newline_manifest="$fixture/repository with spaces/line"$'\n'"break.yaml"
cp "$fixture/repository with spaces/configmap.yaml" "$newline_manifest"
cat >"$fixture/repository with spaces/overlay/kustomization.yaml" <<'YAML'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
YAML

cat >"$fixture/bin/find" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
count=0
[[ ! -f "$CASE_DIR/scans" ]] || read -r count <"$CASE_DIR/scans"
count=$((count + 1))
printf '%s\n' "$count" >"$CASE_DIR/scans"
if [[ "$count" == "$FAIL_SCAN" ]]; then
  if [[ "$PARTIAL_SCAN" == yes ]]; then
    "$REAL_FIND" "$@"
  fi
  printf 'fixture traversal failure at scan %s\n' "$count" >&2
  exit 81
fi
exec "$REAL_FIND" "$@"
STUB
cat >"$fixture/bin/flux-schema" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  version)
    # Report a development build, which the action's version check accepts.
    printf '0.0.0-dev.0\n'
    exit 0
    ;;
  discover)
    # The fixture has no kustomize bases or components to report.
    exit 0
    ;;
  validate) ;;
  *)
    printf 'unexpected backend command\n' >&2
    exit 97
    ;;
esac
printf '%s\0' "$@" >>"$CASE_DIR/backend-args"
printf '\n' >>"$CASE_DIR/backend-calls"
if [[ "$BACKEND_STATUS" != 0 ]]; then
  printf 'fixture backend failed\n' >&2
  exit "$BACKEND_STATUS"
fi
printf 'Summary: Valid: 1, Invalid: 0, Skipped: 0\n'
STUB
cat >"$fixture/bin/flux" <<'STUB'
#!/usr/bin/env bash
# Force the documented standalone backend path; never invoke an installed plugin.
exit 1
STUB
chmod +x "$fixture/bin/find" "$fixture/bin/flux-schema" "$fixture/bin/flux"
real_find="$(command -v find)"
real_mktemp="$(command -v mktemp)"
cat >"$fixture/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${FAIL_MKTEMP:-no}" == yes ]]; then
  printf 'fixture temporary scan storage unavailable\n' >&2
  exit 82
fi
exec "$REAL_MKTEMP" "$@"
STUB
chmod +x "$fixture/bin/mktemp"
failures=0
cases=0

run_case() {
  local name="$1" fail_scan="$2" partial_scan="$3" expected_status="$4"
  local root="$5" backend_status="${6:-0}" fail_mktemp="${7:-no}" status=0 case_dir
  case_dir="$fixture/$name"
  mkdir -p "$case_dir/tmp"
  PATH="$fixture/bin:/usr/bin:/bin" CASE_DIR="$case_dir" REAL_FIND="$real_find" \
    REAL_MKTEMP="$real_mktemp" FAIL_MKTEMP="$fail_mktemp" \
    FAIL_SCAN="$fail_scan" PARTIAL_SCAN="$partial_scan" BACKEND_STATUS="$backend_status" \
    TMPDIR="$case_dir/tmp" bash "$helper" -d "$root" >"$case_dir/output" 2>&1 || status=$?
  cases=$((cases + 1))
  if [[ "$status" != "$expected_status" ]]; then
    printf 'FAIL %s: expected status %s, got %s\n' "$name" "$expected_status" "$status" >&2
    cat "$case_dir/output" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ "$expected_status" != 0 ]]; then
    if grep -Fq 'All validations passed' "$case_dir/output"; then
      printf 'FAIL %s: a failed scan claimed success\n' "$name" >&2
      failures=$((failures + 1))
      return
    fi
    if [[ "$fail_scan" != 0 ]] && ! grep -Fq 'fixture traversal failure' "$case_dir/output"; then
      printf 'FAIL %s: traversal diagnostic was lost\n' "$name" >&2
      failures=$((failures + 1))
      return
    fi
  elif ! grep -Fq 'All validations passed' "$case_dir/output"; then
    printf 'FAIL %s: readable control did not report success\n' "$name" >&2
    failures=$((failures + 1))
    return
  fi
  if [[ -n "$("$real_find" "$case_dir/tmp" -type f -print)" ]]; then
    printf 'FAIL %s: temporary scan file was not cleaned\n' "$name" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'PASS %s\n' "$name"
}

assert_backend_args() {
  local name="$1" expected="$fixture/$1/expected-args" reversed="$fixture/$1/reversed-args"
  local configmap="$fixture/repository with spaces/configmap.yaml" overlay="$fixture/repository with spaces/overlay"
  local flags=(--schema-location=ecosystem --skip-json-path=/sops --skip-missing-schemas --verbose --output=text)
  printf '%s\0' validate "${flags[@]}" "$configmap" "$newline_manifest" validate "${flags[@]}" "$overlay" >"$expected"
  printf '%s\0' validate "${flags[@]}" "$newline_manifest" "$configmap" validate "${flags[@]}" "$overlay" >"$reversed"
  # File enumeration order is not part of the contract; argument boundaries are.
  if ! cmp -s "$expected" "$fixture/$name/backend-args" && ! cmp -s "$reversed" "$fixture/$name/backend-args"; then
    printf 'FAIL %s: standalone or overlay arguments changed or split\n' "$name" >&2
    failures=$((failures + 1))
  fi
}

before="$(cksum "$fixture/repository with spaces/configmap.yaml" "$newline_manifest" "$fixture/repository with spaces/overlay/kustomization.yaml")"
for scan in 1 2 3 4 5; do
  run_case "empty-failure-$scan" "$scan" no 1 "$fixture/repository with spaces"
done
run_case partial-manifests 4 yes 1 "$fixture/repository with spaces"
run_case partial-overlays 5 yes 1 "$fixture/repository with spaces"
for name in partial-manifests partial-overlays; do
  if [[ ! -f "$fixture/$name/backend-calls" ]] || [[ "$(wc -l <"$fixture/$name/backend-calls")" -ne 2 ]]; then
    printf 'FAIL %s: partial scan did not continue validating both observed units\n' "$name" >&2
    failures=$((failures + 1))
  fi
  assert_backend_args "$name"
done
run_case readable 0 no 0 "$fixture/repository with spaces"
if [[ ! -f "$fixture/readable/backend-calls" ]] || [[ "$(wc -l <"$fixture/readable/backend-calls")" -ne 2 ]]; then
  printf 'FAIL readable: expected one standalone group and one overlay\n' >&2
  failures=$((failures + 1))
fi
assert_backend_args readable
run_case empty-repository 0 no 0 "$fixture/empty"
if [[ -e "$fixture/empty-repository/backend-calls" ]]; then
  printf 'FAIL empty-repository: backend was invoked without a validation unit\n' >&2
  failures=$((failures + 1))
fi
run_case backend-failure 0 no 1 "$fixture/repository with spaces" 81
run_case temporary-storage-failure 0 no 82 "$fixture/repository with spaces" 0 yes
if [[ -e "$fixture/temporary-storage-failure/backend-calls" ]]; then
  printf 'FAIL temporary-storage-failure: backend ran without scan storage\n' >&2
  failures=$((failures + 1))
fi
after="$(cksum "$fixture/repository with spaces/configmap.yaml" "$newline_manifest" "$fixture/repository with spaces/overlay/kustomization.yaml")"
if [[ "$before" != "$after" ]]; then
  printf 'FAIL input files were modified\n' >&2
  failures=$((failures + 1))
fi
printf 'validate action: %s cases, %s failures\n' "$cases" "$failures"
[[ "$failures" == 0 ]]
