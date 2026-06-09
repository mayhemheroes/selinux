#!/usr/bin/env bash
#
# selinux/mayhem/test.sh — RUN libsepol's own CUnit unit-test suite (PATCH-grade functional oracle).
#
# mayhem/build.sh built libsepol/tests/libsepol-tests with the project's NORMAL flags (no
# SANITIZER_FLAGS / libFuzzer), and pre-generated the m4 test policies + the downgrade policy.hi, so
# this only RUNS the binary (it never compiles). It maps CUnit's "Run Summary" `tests` row
# (Total/Ran/Passed/Failed) to a CTRF summary. Requires libcunit1-dev (installed in mayhem/Dockerfile).
#
# NOTE: libsepol-tests' main() calls CU_basic_run_tests() TWICE (non-MLS then MLS), so CUnit prints
# TWO "Run Summary" blocks — we SUM the `tests` row across both runs (fio/leveldb run their suite once).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Run the test binary built by mayhem/build.sh (normal flags). Do NOT rebuild here. The Makefile's
# `test:` recipe runs it from inside libsepol/tests (the policy paths it loads are relative to cwd).
BIN=libsepol-tests
[ -x "libsepol/tests/$BIN" ] || { echo "missing libsepol/tests/$BIN — run mayhem/build.sh first" >&2; exit 2; }
out="$(cd libsepol/tests && "./$BIN" 2>&1)"; rc=$?
echo "$out"

# CUnit "Run Summary" tests row: "tests  <Total> <Ran> <Passed> <Failed> <Inactive>". main() runs the
# suite twice (non-MLS + MLS), so SUM every `tests` row. inactive (registered-but-not-run) -> skipped.
read -r total ran passed failed skipped < <(awk '
  /^[[:space:]]*tests[[:space:]]/ {
    tot += $2; ran += $3; pass += $4; fail += $5;
    inact += ($6 == "" ? 0 : $6);
  }
  END { print tot+0, ran+0, pass+0, fail+0, inact+0 }' <<<"$out")
: "${total:=0}" "${ran:=0}" "${passed:=0}" "${failed:=0}" "${skipped:=0}"

# Belt-and-suspenders: if the binary exited non-zero but CUnit reported no failed tests (e.g. a
# registry/init error before any summary), count it as one failure so the oracle doesn't pass blindly.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ] && [ "$total" -eq 0 ]; then failed=1; fi

emit_ctrf "cunit" "$passed" "$failed" "$skipped"
