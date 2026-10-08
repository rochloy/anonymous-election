#!/bin/bash
# scripts/test-db-security.sh [local|hosted|prove-red]
#
# Runs the standing read-only security-invariant suite
# (supabase/test_db_security.sql) against:
#   local     the disposable Docker fixture (default): ae-hmac-test / ae_e_test
#   hosted    the production database via SUPABASE_DB_URL (read-only suite;
#             credentials are sourced from /tmp/opencode/.sbdburl if unset and
#             passed by inherited environment, never in argv)
#   prove-red local only: applies the sabotage file, EXPECTS the suite to fail
#             (listing every fired check), restores, and expects it to pass —
#             the reproducible RED proof required by the
#             test-a-guard-against-known-bad-input rule.
#
# Exit codes: 0 = all checks passed (or, for prove-red, the full RED->GREEN
# cycle behaved as expected); 1 = failures or an anomalous run.
set -uo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
SUITE="$DIR/supabase/test_db_security.sql"
SABOTAGE="$DIR/supabase/test_db_security_sabotage.sql"
RESTORE="$DIR/supabase/test_db_security_restore.sql"
CONTAINER=ae-hmac-test
DATABASE=ae_e_test
MODE="${1:-local}"

psql_local() {
  docker exec -i "$CONTAINER" psql -U postgres -d "$DATABASE" \
    -v ON_ERROR_STOP=0 -P pager=off -f - < "$1" 2>&1
}

psql_hosted() {
  if [ -z "${SUPABASE_DB_URL:-}" ]; then
    if [ -f /tmp/opencode/.sbdburl ]; then
      set -a; . /tmp/opencode/.sbdburl; set +a
    else
      echo "HOSTED: SUPABASE_DB_URL not set and /tmp/opencode/.sbdburl missing" >&2
      return 2
    fi
  fi
  docker run --rm -i --network host -e SUPABASE_DB_URL --entrypoint psql \
    public.ecr.aws/supabase/postgres:17.6.1.156 "$SUPABASE_DB_URL" \
    -v ON_ERROR_STOP=0 -P pager=off -f - < "$1" 2>&1 \
    | sed -E "s#postgres(ql)?://[^[:space:]]*#<redacted>#g"
}

# run_suite <local|hosted> — echoes output; returns 0 iff all checks passed.
run_suite() {
  local OUT RC FAILS ERRORS
  if [ "$1" = local ]; then OUT="$(psql_local "$SUITE")"; else OUT="$(psql_hosted "$SUITE")"; fi
  RC=$?
  echo "$OUT" | grep -vE '^\s*$'
  FAILS=$(echo "$OUT" | grep -c 'DB-SECURITY-FAIL') || FAILS=0
  ERRORS=$(echo "$OUT" | grep -cE 'ERROR:') || ERRORS=0
  if [ $RC -ne 0 ]; then
    echo ">>> psql itself failed (rc=$RC) — treating as FAILURE"
    return 1
  fi
  if ! echo "$OUT" | grep -q 'SUITE-COMPLETE'; then
    echo ">>> SUITE DID NOT RUN TO COMPLETION (sentinel missing) — treating as FAILURE"
    return 1
  fi
  if [ "$ERRORS" != "$FAILS" ]; then
    echo ">>> anomalous run: $ERRORS ERROR line(s) but $FAILS check failure(s) — a broken check must never read as green. FAILURE"
    return 1
  fi
  if [ "$FAILS" -gt 0 ]; then
    echo ">>> $FAILS security check(s) FAILED"
    return 1
  fi
  echo ">>> ALL CHECKS PASSED"
  return 0
}

case "$MODE" in
  local|hosted)
    run_suite "$MODE"
    ;;
  prove-red)
    [ "$CONTAINER" ] && docker exec "$CONTAINER" true 2>/dev/null || { echo "prove-red requires the local container $CONTAINER"; exit 1; }
    echo "########## 1/4 apply sabotage ##########"
    psql_local "$SABOTAGE" | grep -vE '^\s*$'
    echo
    echo "########## 2/4 run suite — MUST FAIL ##########"
    if run_suite local; then
      echo ">>> PROVE-RED FAILED: the suite passed against a sabotaged database (structurally incapable of failing)."
      exit 1
    fi
    echo ">>> RED CONFIRMED (suite failed against known-bad state)"
    echo
    echo "########## 3/4 restore ##########"
    psql_local "$RESTORE" | grep -vE '^\s*$'
    echo
    echo "########## 4/4 run suite — MUST PASS ##########"
    run_suite local
    ;;
  *)
    echo "usage: $0 [local|hosted|prove-red]" >&2
    exit 2
    ;;
esac
