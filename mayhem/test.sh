#!/usr/bin/env bash
# mayhem/test.sh: known-answer oracle over the pre-built (normal-flags) goaccess and bin2c.
# Asserts exact output values, so a patch that makes the program a no-op fails. Does not build.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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


TB="$SRC/mayhem/build-tests"
GA="$TB/goaccess"
B2C="$TB/bin2c"
LOG="$SRC/mayhem/test-data/access.clf"
passed=0; failed=0

for f in "$GA" "$B2C" "$LOG"; do
  [ -e "$f" ] || { echo "missing $f (mayhem/build.sh builds it)" >&2; emit_ctrf goaccess-kat 0 1; exit 1; }
done

check() {  # check <name> <haystack> <needle>
  if [[ "$2" == *"$3"* ]]; then passed=$((passed + 1)); echo "ok   $1"
  else failed=$((failed + 1)); echo "FAIL $1: expected <$3>" >&2; fi
}

OUT="$("$GA" --log-format=COMBINED --no-global-config -a -o json -f "$LOG" 2>/dev/null)"
check total_requests    "$OUT" '"total_requests": 6,'
check valid_requests    "$OUT" '"valid_requests": 5,'
check failed_requests   "$OUT" '"failed_requests": 1,'
check unique_visitors   "$OUT" '"unique_visitors": 3,'
check unique_files      "$OUT" '"unique_files": 2,'
check unique_referrers  "$OUT" '"unique_referrers": 2,'
check unique_not_found  "$OUT" '"unique_not_found": 1,'
check bandwidth         "$OUT" '"bandwidth": 3750,'
check start_date        "$OUT" '"start_date": "10/Oct/2020"'
check end_date          "$OUT" '"end_date": "11/Oct/2020"'
check top_request       "$OUT" '"hits": {"count": 3,"percent": "60.00"},"visitors": {"count": 3,"percent": "100.00"},"bytes": {"count": 3000,"percent": "80.00"},"method": "GET","protocol": "HTTP/1.1","data": "\/index.html"'
check browser_chrome    "$OUT" '"bytes": {"count": 1500,"percent": "40.00"},"data": "Chrome"'
check browser_curl      "$OUT" '"data": "curl\/7.68.0"'

COMMON="$(printf '%s\n' '10.0.0.1 - - [01/Jan/2021:00:00:01 +0000] "GET /a HTTP/1.1" 200 100' \
                        '10.0.0.2 - - [01/Jan/2021:00:00:02 +0000] "GET /a HTTP/1.1" 200 300' |
          "$GA" --log-format=COMMON --no-global-config -o json -f - 2>/dev/null)"
check common_total      "$COMMON" '"valid_requests": 2,'
check common_bandwidth  "$COMMON" '"bandwidth": 400,'

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
printf 'hello' > "$W/in.bin"
"$B2C" "$W/in.bin" "$W/out.h" arr 2>/dev/null
B2C_OUT="$(cat "$W/out.h" 2>/dev/null)"
check bin2c_bytes  "$B2C_OUT" '0x68, 0x65, 0x6c, 0x6c, 0x6f'
check bin2c_decl   "$B2C_OUT" 'const char arr[5] = {'
check bin2c_length "$B2C_OUT" 'const int arr_length = 5;'

emit_ctrf goaccess-kat "$passed" "$failed"
