#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_UNDER_TEST="$ROOT_DIR/scripts/manage-login-waf.sh"

RULE_ID="rule_login_rate_limit_observation_6Qv4nI"
RULE_NAME="Login rate-limit observation"
PROJECT_ID="prj_Ha0FArHnIMgFTLhWMAZsVf86J3k0"
TEAM_ID="team_W8yuVa7lHUXqrhvWCc1bmcfH"

pass_count=0
fail_count=0

note_pass() { pass_count=$((pass_count + 1)); printf 'PASS: %s\n' "$1"; }
note_fail() { fail_count=$((fail_count + 1)); printf 'FAIL: %s\n' "$1"; }

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq -- "$needle" "$file" || { printf 'Expected "%s" in %s\n' "$needle" "$file" >&2; printf '%s\n' "--- $file ---" >&2; cat "$file" >&2; printf '%s\n' "-----------" >&2; return 1; }
}

assert_not_contains() {
  local needle="$1" file="$2"
  grep -Fq -- "$needle" "$file" && { printf 'Did not expect "%s" in %s\n' "$needle" "$file" >&2; return 1; }
  return 0
}

setup_case() {
  CASE_DIR="$(mktemp -d)"
  BIN_DIR="$CASE_DIR/bin"
  LINKED_MAIN="$CASE_DIR/linked-main"
  STATE_DIR="$CASE_DIR/state"
  mkdir -p "$BIN_DIR" "$LINKED_MAIN/.vercel" "$STATE_DIR"

  cp "$SCRIPT_UNDER_TEST" "$CASE_DIR/manage-login-waf.sh"
  chmod +x "$CASE_DIR/manage-login-waf.sh"

  cat >"$LINKED_MAIN/.vercel/project.json" <<JSON
{"projectId":"$PROJECT_ID","orgId":"$TEAM_ID","projectName":"anonymous-election"}
JSON

  cat >"$STATE_DIR/live_rule.json" <<'JSON'
{
  "name": "Login rate-limit observation",
  "active": true,
  "action": {
    "mitigate": {
      "redirect": null,
      "action": "rate_limit",
      "rateLimit": {
        "limit": 10,
        "action": "log",
        "window": 60,
        "algo": "fixed_window",
        "keys": ["ip"]
      },
      "actionDuration": null
    }
  },
  "id": "rule_login_rate_limit_observation_6Qv4nI",
  "conditionGroup": [
    {
      "conditions": [
        {"type": "path", "value": "/api/admin/login", "op": "eq"},
        {"type": "method", "op": "eq", "value": "POST"}
      ]
    }
  ],
  "valid": true,
  "validationErrors": null,
  "_status": "live"
}
JSON

  printf '[]' >"$STATE_DIR/draft_changes.json"
  printf '[]' >"$STATE_DIR/calls.log"

  cat >"$BIN_DIR/vercel" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

STATE_DIR="${FAKE_VERCEL_STATE_DIR:?}"
CALLS_FILE="$STATE_DIR/calls.log"
LIVE_RULE="$STATE_DIR/live_rule.json"
DRAFT_CHANGES="$STATE_DIR/draft_changes.json"

append_call() {
  local raw="$1"
  jq -c --arg raw "$raw" '. + [$raw]' "$CALLS_FILE" >"$STATE_DIR/calls.tmp"
  mv "$STATE_DIR/calls.tmp" "$CALLS_FILE"
}

ensure_cwd_linked() {
  local cwd_seen=""
  local i=1
  while (( i <= $# )); do
    arg="${!i}"
    if [[ "$arg" == "--cwd" ]]; then
      j=$((i + 1))
      cwd_seen="${!j:-}"
      break
    fi
    i=$((i + 1))
  done
  [[ -n "$cwd_seen" ]] || { echo "missing --cwd" >&2; exit 97; }
  [[ "$cwd_seen" == "${FAKE_LINKED_MAIN:?}" ]] || { echo "bad --cwd target" >&2; exit 98; }
}

render_rules_list() {
  local has_draft pending
  has_draft=false
  pending=0
  if [[ "${FAKE_FORCE_HAS_DRAFT:-0}" == "1" ]]; then
    has_draft=true
  fi
  if [[ "${FAKE_FORCE_PENDING_CHANGES:-0}" == "1" ]]; then
    pending=1
  fi
  local draft_len
  draft_len="$(jq -r 'length' "$DRAFT_CHANGES" 2>/dev/null || printf '0')"
  [[ "$draft_len" =~ ^[0-9]+$ ]] || draft_len=0
  if [[ "$draft_len" != "0" ]]; then
    has_draft=true
    pending="$draft_len"
  fi
  jq -cn --argfile rule "$LIVE_RULE" --arg hd "$has_draft" --argjson pc "$pending" '{rules:[$rule],hasDraft:($hd=="true"),pendingChanges:$pc}'
}

with_unknown_field_if_requested() {
  local json="$1"
  if [[ "${FAKE_LIVE_EXTRA_FIELD:-0}" == "1" ]]; then
    jq -c '. + {unexpectedField: "x"}' <<<"$json"
  else
    printf '%s\n' "$json"
  fi
}

compute_expected_draft_from_live() {
  local mode="$1" enforce_limit="${2:-}"
  if [[ "$mode" == "observe" ]]; then
    jq -c '.active=true | .action.mitigate.rateLimit.action="log"' "$LIVE_RULE"
  elif [[ "$mode" == "enforce" ]]; then
    jq -c --argjson lim "$enforce_limit" '.active=true | .action.mitigate.rateLimit.action="rate_limit" | .action.mitigate.rateLimit.limit=$lim' "$LIVE_RULE"
  else
    jq -c '.active=false' "$LIVE_RULE"
  fi
}

emit_diff_change() {
  local action="$1" id="$2" value_json="$3"
  local draft_value
  draft_value="$(jq -c '{name,active,conditionGroup,action}' <<<"$value_json")"
  jq -nc \
    --arg action "$action" \
    --arg id "$id" \
    --argjson value "$draft_value" \
    '{changes:[{action:$action,username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:$id,value:$value}]}'
}

build_rate_limit_action_from_flags() {
  local requests="$1" window="$2" algo="$3" keys_csv="$4" exceed_action="$5"
  local keys_json
  IFS=',' read -r -a key_parts <<<"$keys_csv"
  keys_json="$(printf '%s\n' "${key_parts[@]}" | jq -R . | jq -cs .)"
  jq -cn \
    --arg exceed_action "$exceed_action" \
    --argjson requests "$requests" \
    --argjson window "$window" \
    --arg algo "$algo" \
    --argjson keys "$keys_json" \
    '{
      mitigate: {
        redirect: null,
        action: "rate_limit",
        rateLimit: {
          limit: $requests,
          action: $exceed_action,
          window: $window,
          algo: $algo,
          keys: $keys
        },
        actionDuration: null
      }
    }'
}

sub1="${1:-}"; sub2="${2:-}"; sub3="${3:-}"
append_call "$*"
ensure_cwd_linked "$@"

if [[ "$sub1" != "firewall" ]]; then
  echo "unsupported" >&2
  exit 96
fi

if [[ "$sub2" == "rules" && "$sub3" == "list" ]]; then
  render_rules_list
  exit 0
fi

if [[ "$sub2" == "diff" ]]; then
  cnt_file="$STATE_DIR/diff_count"
  cnt=0
  [[ -f "$cnt_file" ]] && cnt="$(cat "$cnt_file")"
  cnt=$((cnt + 1))
  printf '%s' "$cnt" >"$cnt_file"

  if [[ "${FAKE_DIFF_UNKNOWN_SHAPE:-0}" == "1" ]]; then
    printf '{"weird":true}\n'
    exit 0
  fi
  if [[ "${FAKE_DIFF_WRONG_ACTION:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe)"
    emit_diff_change "rules.add" "rule_login_rate_limit_observation_6Qv4nI" "$val"
    exit 0
  fi
  if [[ "${FAKE_DIFF_WRONG_ID:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe)"
    emit_diff_change "rules.update" "wrong_id" "$val"
    exit 0
  fi
  if [[ "${FAKE_DIFF_EXTRA_AUDIT_FIELD:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe)"
    emit_diff_change "rules.update" "rule_login_rate_limit_observation_6Qv4nI" "$val" | jq -c '.changes[0] += {auditSource:"manual"}'
    exit 0
  fi
  if [[ "${FAKE_DIFF_ADDED_CONDITION:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '.conditionGroup[0].conditions += [{"type":"header","op":"eq","value":"x"}]')"
    emit_diff_change "rules.update" "rule_login_rate_limit_observation_6Qv4nI" "$val"
    exit 0
  fi
  if [[ "${FAKE_DIFF_CHANGED_BASE_ACTION:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '.action.mitigate.action="redirect"')"
    emit_diff_change "rules.update" "rule_login_rate_limit_observation_6Qv4nI" "$val"
    exit 0
  fi
  if [[ "${FAKE_DIFF_EXTRA_CONFIG_FIELD:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '.action.mitigate.rateLimit += {burst:2}')"
    emit_diff_change "rules.update" "rule_login_rate_limit_observation_6Qv4nI" "$val"
    exit 0
  fi
  if [[ "${FAKE_DIFF_VALUE_HAS_ID:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '. + {id:"rule_login_rate_limit_observation_6Qv4nI"}')"
    jq -nc --argjson value "$val" '{changes:[{action:"rules.update",username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:"rule_login_rate_limit_observation_6Qv4nI",value:$value}]}'
    exit 0
  fi
  if [[ "${FAKE_DIFF_VALUE_HAS_VALID:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '. + {valid:true}')"
    jq -nc --argjson value "$val" '{changes:[{action:"rules.update",username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:"rule_login_rate_limit_observation_6Qv4nI",value:$value}]}'
    exit 0
  fi
  if [[ "${FAKE_DIFF_VALUE_HAS_VALIDATION_ERRORS:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '. + {validationErrors:null}')"
    jq -nc --argjson value "$val" '{changes:[{action:"rules.update",username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:"rule_login_rate_limit_observation_6Qv4nI",value:$value}]}'
    exit 0
  fi
  if [[ "${FAKE_DIFF_VALUE_HAS_STATUS:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '. + {_status:"draft"}')"
    jq -nc --argjson value "$val" '{changes:[{action:"rules.update",username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:"rule_login_rate_limit_observation_6Qv4nI",value:$value}]}'
    exit 0
  fi
  if [[ "${FAKE_DIFF_VALUE_EXTRA_TOP_LEVEL_KEY:-0}" == "1" && "$cnt" -ge 2 ]]; then
    val="$(compute_expected_draft_from_live observe | jq -c '. + {newConfigKey:"unexpected"}')"
    jq -nc --argjson value "$val" '{changes:[{action:"rules.update",username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:"rule_login_rate_limit_observation_6Qv4nI",value:$value}]}'
    exit 0
  fi

  if [[ "${FAKE_ADD_CONCURRENT_DRAFT_AFTER_CONFIRM:-0}" == "1" ]]; then
    if (( cnt >= 2 )); then
      val="$(compute_expected_draft_from_live observe)"
      jq -nc --argjson value "$val" '{changes:[{action:"rules.update",username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn",id:"rule_login_rate_limit_observation_6Qv4nI",value:$value},{action:"rules.update",username:"other",createdAt:"2026-10-02T12:56:27.000Z",userId:"other",id:"other_rule",value:{id:"other_rule"}}]}'
      exit 0
    fi
  fi

  if [[ "${FAKE_FORCE_EMPTY_DIFF_AFTER_EDIT:-0}" == "1" && "$cnt" -ge 2 ]]; then
    jq -cn '{changes:[]}'
    exit 0
  fi

  jq -cn --argfile changes "$DRAFT_CHANGES" '{changes:($changes | map(.value = (.value | {name,active,conditionGroup,action}) | . + {username:"rochloy-8233",createdAt:"2026-10-02T12:56:26.524Z",userId:"GPzn63UcdImAIFGJp4aFhmUn"}))}'
  exit 0
fi

if [[ "$sub2" == "rules" && "$sub3" == "edit" ]]; then
  rule_id="${4:-}"
  [[ "$rule_id" == "rule_login_rate_limit_observation_6Qv4nI" ]] || exit 95
  req=""
  window=""
  action=""
  exceed_action=""
  algo="fixed_window"
  keys_csv="ip"
  enabled=0
  i=5
  while (( i <= $# )); do
    arg="${!i}"
    case "$arg" in
      --action)
        j=$((i + 1)); action="${!j}"; i=$((i + 2));;
      --rate-limit-window)
        j=$((i + 1)); window="${!j}"; i=$((i + 2));;
      --rate-limit-requests)
        j=$((i + 1)); req="${!j}"; i=$((i + 2));;
      --rate-limit-algo)
        j=$((i + 1)); algo="${!j}"; i=$((i + 2));;
      --rate-limit-keys)
        j=$((i + 1)); keys_csv="${!j}"; i=$((i + 2));;
      --rate-limit-action)
        j=$((i + 1)); exceed_action="${!j}"; i=$((i + 2));;
      --enabled)
        enabled=1; i=$((i + 1));;
      --yes|--cwd)
        i=$((i + 1))
        if [[ "$arg" == "--cwd" ]]; then i=$((i + 1)); fi
        ;;
      *)
        i=$((i + 1));;
    esac
  done

  [[ "$action" == "rate_limit" ]] || { echo "missing/invalid --action rate_limit" >&2; exit 89; }
  [[ "$window" =~ ^[0-9]+$ ]] || { echo "missing/invalid --rate-limit-window" >&2; exit 88; }
  [[ "$req" =~ ^[0-9]+$ ]] || { echo "missing/invalid --rate-limit-requests" >&2; exit 87; }
  [[ "$enabled" -eq 1 ]] || { echo "missing --enabled" >&2; exit 86; }
  [[ "$algo" == "fixed_window" ]] || { echo "invalid --rate-limit-algo" >&2; exit 85; }
  [[ "$keys_csv" == "ip" ]] || { echo "invalid --rate-limit-keys" >&2; exit 84; }
  [[ "$exceed_action" == "log" || "$exceed_action" == "rate_limit" ]] || { echo "invalid --rate-limit-action" >&2; exit 83; }

  draft="$(cat "$LIVE_RULE")"
  draft_action="$(build_rate_limit_action_from_flags "$req" "$window" "$algo" "$keys_csv" "$exceed_action")"
  draft="$(jq -c --argjson a "$draft_action" '.active=true | .action=$a' <<<"$draft")"
  printf '[{"action":"rules.update","id":"rule_login_rate_limit_observation_6Qv4nI","value":%s}]\n' "$draft" >"$DRAFT_CHANGES"
  exit 0
fi

if [[ "$sub2" == "rules" && "$sub3" == "disable" ]]; then
  rule_id="${4:-}"
  [[ "$rule_id" == "rule_login_rate_limit_observation_6Qv4nI" ]] || exit 94
  draft="$(jq -c '.active=false' "$LIVE_RULE")"
  printf '[{"action":"rules.update","id":"rule_login_rate_limit_observation_6Qv4nI","value":%s}]\n' "$draft" >"$DRAFT_CHANGES"
  exit 0
fi

if [[ "$sub2" == "publish" ]]; then
  if [[ "${FAKE_BLOCK_PUBLISH:-0}" == "1" ]]; then
    echo "publish attempted when blocked" >&2
    exit 93
  fi
  if [[ "${FAKE_PUBLISH_FAIL:-0}" == "1" ]]; then
    exit 92
  fi
  len="$(jq -r 'length' "$DRAFT_CHANGES")"
  [[ "$len" == "1" ]] || exit 91
  jq -e '.[0].action=="rules.update" and .[0].id=="rule_login_rate_limit_observation_6Qv4nI"' "$DRAFT_CHANGES" >/dev/null || exit 90
  jq -c '.[0].value' "$DRAFT_CHANGES" >"$LIVE_RULE"
  jq -c '[]' >"$DRAFT_CHANGES"
  exit 0
fi

echo "unsupported command: $*" >&2
exit 99
FAKE
  chmod +x "$BIN_DIR/vercel"

  TEST_STDOUT="$CASE_DIR/stdout.txt"
  TEST_STDERR="$CASE_DIR/stderr.txt"
}

run_script() {
  local mode="$1" input="${2:-}"
  set +e
  if [[ -n "$input" ]]; then
    env PATH="$BIN_DIR:$PATH" FAKE_VERCEL_STATE_DIR="$STATE_DIR" FAKE_LINKED_MAIN="$LINKED_MAIN" MANAGE_LOGIN_WAF_LINKED_MAIN="$LINKED_MAIN" bash "$CASE_DIR/manage-login-waf.sh" "$mode" >"$TEST_STDOUT" 2>"$TEST_STDERR" <<<"$input"
  else
    env PATH="$BIN_DIR:$PATH" FAKE_VERCEL_STATE_DIR="$STATE_DIR" FAKE_LINKED_MAIN="$LINKED_MAIN" MANAGE_LOGIN_WAF_LINKED_MAIN="$LINKED_MAIN" bash "$CASE_DIR/manage-login-waf.sh" "$mode" >"$TEST_STDOUT" 2>"$TEST_STDERR"
  fi
  RC=$?
  set -e
}

run_script_args() {
  local input="$1"
  shift
  set +e
  if [[ -n "$input" ]]; then
    env PATH="$BIN_DIR:$PATH" FAKE_VERCEL_STATE_DIR="$STATE_DIR" FAKE_LINKED_MAIN="$LINKED_MAIN" MANAGE_LOGIN_WAF_LINKED_MAIN="$LINKED_MAIN" bash "$CASE_DIR/manage-login-waf.sh" "$@" >"$TEST_STDOUT" 2>"$TEST_STDERR" <<<"$input"
  else
    env PATH="$BIN_DIR:$PATH" FAKE_VERCEL_STATE_DIR="$STATE_DIR" FAKE_LINKED_MAIN="$LINKED_MAIN" MANAGE_LOGIN_WAF_LINKED_MAIN="$LINKED_MAIN" bash "$CASE_DIR/manage-login-waf.sh" "$@" >"$TEST_STDOUT" 2>"$TEST_STDERR"
  fi
  RC=$?
  set -e
}

run_script_env() {
  local mode="$1" input="$2"
  shift 2
  set +e
  env PATH="$BIN_DIR:$PATH" FAKE_VERCEL_STATE_DIR="$STATE_DIR" FAKE_LINKED_MAIN="$LINKED_MAIN" MANAGE_LOGIN_WAF_LINKED_MAIN="$LINKED_MAIN" "$@" bash "$CASE_DIR/manage-login-waf.sh" "$mode" >"$TEST_STDOUT" 2>"$TEST_STDERR" <<<"$input"
  RC=$?
  set -e
}

teardown_case() { rm -rf "$CASE_DIR"; }

run_case() {
  local name="$1"; shift
  setup_case
  if "$@"; then note_pass "$name"; else note_fail "$name"; fi
  teardown_case
}

case_status_read_only_even_with_draft_warning() {
  run_script_env status "" FAKE_FORCE_HAS_DRAFT=1
  [[ "$RC" -eq 0 ]] || return 1
  assert_contains "Status mode is read-only" "$TEST_STDOUT" || return 1
  assert_contains "WARNING: Draft markers are present" "$TEST_STDOUT" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_observe_success_schema_and_immutability() {
  jq '.active=false | .action.mitigate.rateLimit.action="rate_limit" | .action.mitigate.rateLimit.limit=11' "$STATE_DIR/live_rule.json" >"$STATE_DIR/live_rule.tmp"
  mv "$STATE_DIR/live_rule.tmp" "$STATE_DIR/live_rule.json"

  jq -e '.active==false and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==11' "$STATE_DIR/live_rule.json" >/dev/null || return 1

  run_script observe $'PUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi

  assert_contains "firewall publish" "$STATE_DIR/calls.log" || return 1
  jq -e '.active==true and .action.mitigate.rateLimit.action=="log" and .action.mitigate.rateLimit.limit==11' "$STATE_DIR/live_rule.json" >/dev/null || return 1
}

case_observe_retains_existing_limit() {
  jq '.active=false | .action.mitigate.rateLimit.action="rate_limit" | .action.mitigate.rateLimit.limit=17' "$STATE_DIR/live_rule.json" >"$STATE_DIR/live_rule.tmp"
  mv "$STATE_DIR/live_rule.tmp" "$STATE_DIR/live_rule.json"

  run_script observe $'PUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi

  jq -e '.active==true and .action.mitigate.rateLimit.action=="log" and .action.mitigate.rateLimit.limit==17 and .action.mitigate.rateLimit.window==60 and .action.mitigate.rateLimit.algo=="fixed_window" and .action.mitigate.rateLimit.keys==["ip"]' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  assert_contains "--action rate_limit" "$STATE_DIR/calls.log" || return 1
  assert_contains "--rate-limit-window 60" "$STATE_DIR/calls.log" || return 1
  assert_contains "--rate-limit-requests 17" "$STATE_DIR/calls.log" || return 1
  assert_contains "--rate-limit-action log" "$STATE_DIR/calls.log" || return 1
}

case_enforce_success_operator_limit() {
  run_script enforce $'7\nPUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi
  jq -e '.active==true and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==7' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  assert_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_enforce_changes_limit_and_full_action_flags() {
  jq '.active=true | .action.mitigate.rateLimit.action="log" | .action.mitigate.rateLimit.limit=17' "$STATE_DIR/live_rule.json" >"$STATE_DIR/live_rule.tmp"
  mv "$STATE_DIR/live_rule.tmp" "$STATE_DIR/live_rule.json"

  run_script enforce $'2\nPUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi

  jq -e '.active==true and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==2 and .action.mitigate.rateLimit.window==60 and .action.mitigate.rateLimit.algo=="fixed_window" and .action.mitigate.rateLimit.keys==["ip"]' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  assert_contains "--action rate_limit" "$STATE_DIR/calls.log" || return 1
  assert_contains "--rate-limit-window 60" "$STATE_DIR/calls.log" || return 1
  assert_contains "--rate-limit-requests 2" "$STATE_DIR/calls.log" || return 1
  assert_contains "--rate-limit-action rate_limit" "$STATE_DIR/calls.log" || return 1
}

case_disable_success_only_active_changes() {
  before="$(cat "$STATE_DIR/live_rule.json")"
  run_script disable $'PUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi
  jq -e '.active==false' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  jq -e --argjson b "$before" '. as $a | ($a|del(.active)) == ($b|del(.active))' "$STATE_DIR/live_rule.json" >/dev/null || return 1
}

case_enforce_warns_on_leq5() {
  run_script enforce $'5\nPUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi
  assert_contains "WARNING: Requested threshold is <= 5." "$TEST_STDOUT"
}

case_input_validation_non_integer() {
  run_script enforce $'abc\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit must be a canonical decimal integer" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_input_validation_rejects_leading_zero_08() {
  run_script enforce $'08\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit must be a canonical decimal integer" "$TEST_STDERR" || return 1
  assert_not_contains "firewall rules edit" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules disable" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_input_validation_rejects_leading_zero_007() {
  run_script enforce $'007\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit must be a canonical decimal integer" "$TEST_STDERR" || return 1
  assert_not_contains "firewall rules edit" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules disable" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_input_validation_range() {
  run_script enforce $'0\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit out of range" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_input_validation_range_10000001() {
  run_script enforce $'10000001\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit out of range" "$TEST_STDERR" || return 1
  assert_not_contains "firewall rules edit" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules disable" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_input_validation_range_huge_digits() {
  local huge
  huge="$(printf '9%.0s' {1..120})"
  run_script enforce "$huge"$'\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit out of range" "$TEST_STDERR" || return 1
  assert_not_contains "firewall rules edit" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules disable" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_input_validation_empty() {
  run_script enforce $'\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Limit must be a canonical decimal integer" "$TEST_STDERR" || return 1
  assert_not_contains "firewall rules edit" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules disable" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_rejects_extra_argv() {
  run_script_args "" status extra
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Expected exactly one mode argument" "$TEST_STDERR" || return 1
  assert_not_contains "firewall rules list" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules edit" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall rules disable" "$STATE_DIR/calls.log" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_enforce_boundary_min_success() {
  run_script enforce $'1\nPUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi
  jq -e '.active==true and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==1' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  assert_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_enforce_boundary_max_success() {
  run_script enforce $'10000000\nPUBLISH\n'
  if [[ "$RC" -ne 0 ]]; then
    cat "$TEST_STDERR" >&2
    return 1
  fi
  jq -e '.active==true and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==10000000' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  assert_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_wrong_diff_action_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_WRONG_ACTION=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_wrong_diff_id_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_WRONG_ID=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_extra_condition_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_ADDED_CONDITION=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_changed_base_action_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_CHANGED_BASE_ACTION=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_extra_config_field_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_EXTRA_CONFIG_FIELD=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_extra_audit_field_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_EXTRA_AUDIT_FIELD=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_diff_value_forbidden_id_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_VALUE_HAS_ID=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_diff_value_forbidden_valid_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_VALUE_HAS_VALID=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_diff_value_forbidden_validation_errors_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_VALUE_HAS_VALIDATION_ERRORS=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_diff_value_forbidden_status_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_VALUE_HAS_STATUS=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_diff_value_unknown_top_level_key_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_VALUE_EXTRA_TOP_LEVEL_KEY=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_unknown_diff_shape_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_DIFF_UNKNOWN_SHAPE=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_empty_diff_after_edit_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_FORCE_EMPTY_DIFF_AFTER_EDIT=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Staged diff does not match exact intended single-rule update" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_preexisting_unrelated_draft_blocks_mutation() {
  run_script_env observe $'PUBLISH\n' FAKE_FORCE_PENDING_CHANGES=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Refusing mutate: explicit draft markers present" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_concurrent_draft_after_confirmation_blocks_publish() {
  run_script_env observe $'PUBLISH\n' FAKE_ADD_CONCURRENT_DRAFT_AFTER_CONFIRM=1
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

case_project_id_mismatch_blocks() {
  cat >"$LINKED_MAIN/.vercel/project.json" <<'JSON'
{"projectId":"wrong","orgId":"wrong","projectName":"anonymous-election"}
JSON
  run_script status
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "project/org mismatch" "$TEST_STDERR"
}

case_operator_refusal_blocks_publish() {
  jq '.active=false | .action.mitigate.rateLimit.action="rate_limit" | .action.mitigate.rateLimit.limit=13' "$STATE_DIR/live_rule.json" >"$STATE_DIR/live_rule.tmp"
  mv "$STATE_DIR/live_rule.tmp" "$STATE_DIR/live_rule.json"

  jq -e '.active==false and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==13' "$STATE_DIR/live_rule.json" >/dev/null || return 1

  run_script observe $'NOPE\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Publish cancelled by operator" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"

  # Verify staged draft changed, but live rule stayed disabled/enforcing.
  jq -e 'length==1 and .[0].action=="rules.update" and .[0].id=="rule_login_rate_limit_observation_6Qv4nI" and .[0].value.active==true and .[0].value.action.mitigate.rateLimit.action=="log" and .[0].value.action.mitigate.rateLimit.limit==13' "$STATE_DIR/draft_changes.json" >/dev/null || return 1
  jq -e '.active==false and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==13' "$STATE_DIR/live_rule.json" >/dev/null || return 1
}

case_known_bad_guard_live_immutable_until_publish() {
  jq '.active=false | .action.mitigate.rateLimit.action="rate_limit" | .action.mitigate.rateLimit.limit=17' "$STATE_DIR/live_rule.json" >"$STATE_DIR/live_rule.tmp"
  mv "$STATE_DIR/live_rule.tmp" "$STATE_DIR/live_rule.json"

  run_script observe $'NOPE\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log" || return 1

  # Known-bad guard: this fails if fake rules edit mutates live immediately.
  jq -e '.active==false and .action.mitigate.rateLimit.action=="rate_limit" and .action.mitigate.rateLimit.limit==17' "$STATE_DIR/live_rule.json" >/dev/null || return 1
  jq -e 'length==1 and .[0].value.active==true and .[0].value.action.mitigate.rateLimit.action=="log" and .[0].value.action.mitigate.rateLimit.limit==17' "$STATE_DIR/draft_changes.json" >/dev/null
}

case_known_bad_guard_blocks_publish() {
  jq '.action.mitigate.rateLimit.algo="sliding_window"' "$STATE_DIR/live_rule.json" >"$STATE_DIR/live_rule.tmp"
  mv "$STATE_DIR/live_rule.tmp" "$STATE_DIR/live_rule.json"
  run_script observe $'PUBLISH\n'
  [[ "$RC" -ne 0 ]] || return 1
  assert_contains "Pinned rule shape invalid" "$TEST_STDERR" || return 1
  assert_not_contains "firewall publish" "$STATE_DIR/calls.log"
}

run_case "status read-only with draft warning" case_status_read_only_even_with_draft_warning
run_case "observe succeeds with source schema" case_observe_success_schema_and_immutability
run_case "observe retains existing limit" case_observe_retains_existing_limit
run_case "enforce succeeds with operator limit" case_enforce_success_operator_limit
run_case "enforce changes limit with full action flags" case_enforce_changes_limit_and_full_action_flags
run_case "disable changes only active" case_disable_success_only_active_changes
run_case "enforce warns on <=5" case_enforce_warns_on_leq5
run_case "enforce rejects non-integer" case_input_validation_non_integer
run_case "enforce rejects leading-zero 08" case_input_validation_rejects_leading_zero_08
run_case "enforce rejects leading-zero 007" case_input_validation_rejects_leading_zero_007
run_case "enforce rejects out-of-range" case_input_validation_range
run_case "enforce rejects out-of-range 10000001" case_input_validation_range_10000001
run_case "enforce rejects huge digit input" case_input_validation_range_huge_digits
run_case "enforce rejects empty input" case_input_validation_empty
run_case "rejects extra argv" case_rejects_extra_argv
run_case "enforce accepts min boundary" case_enforce_boundary_min_success
run_case "enforce accepts max boundary" case_enforce_boundary_max_success
run_case "wrong diff action blocked" case_wrong_diff_action_blocks_publish
run_case "wrong diff id blocked" case_wrong_diff_id_blocks_publish
run_case "extra condition blocked" case_extra_condition_blocks_publish
run_case "changed base action blocked" case_changed_base_action_blocks_publish
run_case "extra config field blocked" case_extra_config_field_blocks_publish
run_case "extra audit field blocked" case_extra_audit_field_blocks_publish
run_case "diff value forbidden id blocked" case_diff_value_forbidden_id_blocks_publish
run_case "diff value forbidden valid blocked" case_diff_value_forbidden_valid_blocks_publish
run_case "diff value forbidden validationErrors blocked" case_diff_value_forbidden_validation_errors_blocks_publish
run_case "diff value forbidden _status blocked" case_diff_value_forbidden_status_blocks_publish
run_case "diff value unknown top-level key blocked" case_diff_value_unknown_top_level_key_blocks_publish
run_case "unknown diff shape blocked" case_unknown_diff_shape_blocks_publish
run_case "empty diff after edit blocked" case_empty_diff_after_edit_blocks_publish
run_case "preexisting draft markers block mutation" case_preexisting_unrelated_draft_blocks_mutation
run_case "concurrent draft after confirm blocks publish" case_concurrent_draft_after_confirmation_blocks_publish
run_case "project mismatch blocks" case_project_id_mismatch_blocks
run_case "operator refusal blocks publish" case_operator_refusal_blocks_publish
run_case "known-bad guard live immutable until publish" case_known_bad_guard_live_immutable_until_publish
run_case "known-bad guard prevents publish" case_known_bad_guard_blocks_publish

printf '\nTotal: %d passed, %d failed\n' "$pass_count" "$fail_count"
(( fail_count == 0 ))
