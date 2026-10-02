#!/usr/bin/env bash
set -euo pipefail

RULE_ID="rule_login_rate_limit_observation_6Qv4nI"
RULE_NAME="Login rate-limit observation"
TARGET_PATH="/api/admin/login"
TARGET_METHOD="POST"
PINNED_PROJECT_ID="prj_Ha0FArHnIMgFTLhWMAZsVf86J3k0"
PINNED_TEAM_ID="team_W8yuVa7lHUXqrhvWCc1bmcfH"
LINKED_MAIN_DEFAULT="/home/rtaniman/Programs/opencode-projects/anonymous-election"
LINKED_MAIN="${MANAGE_LOGIN_WAF_LINKED_MAIN:-$LINKED_MAIN_DEFAULT}"

usage() {
  cat <<'USAGE'
Usage: scripts/manage-login-waf.sh <status|observe|enforce|disable>

Modes:
  status   Read-only: validate and print current rule state
  observe  Stage enable+log and publish after explicit confirmation
  enforce  Stage enable+rate_limit with operator limit and publish
  disable  Stage disable and publish
USAGE
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

json_tmp() { mktemp; }

run_vercel_firewall() {
  # Intentionally use documented/verified placement with --cwd at command end.
  vercel firewall "$@" --cwd "$LINKED_MAIN"
}

ensure_linked_checkout() {
  local project_file="$LINKED_MAIN/.vercel/project.json"
  [[ -f "$project_file" ]] || die "Missing linked checkout project file: $project_file"
  jq -e --arg pid "$PINNED_PROJECT_ID" --arg tid "$PINNED_TEAM_ID" '
    (.projectId // "") == $pid and (.orgId // "") == $tid
  ' "$project_file" >/dev/null || die "Linked checkout project/org mismatch for $project_file"
}

fetch_rules_json() {
  local out
  out="$(json_tmp)"
  run_vercel_firewall rules list --json >"$out" || {
    rm -f "$out"
    die "Failed to list firewall rules"
  }
  jq -e . "$out" >/dev/null || {
    rm -f "$out"
    die "Invalid JSON from firewall rules list"
  }
  printf '%s\n' "$out"
}

fetch_diff_json() {
  local out
  out="$(json_tmp)"
  run_vercel_firewall diff --json >"$out" || {
    rm -f "$out"
    die "Failed to read firewall diff"
  }
  jq -e . "$out" >/dev/null || {
    rm -f "$out"
    die "Invalid JSON from firewall diff"
  }
  printf '%s\n' "$out"
}

extract_target_rule() {
  local rules_file="$1"
  jq -ec --arg rid "$RULE_ID" --arg rname "$RULE_NAME" '
    if (type != "object") then error("rules list root must be object") else . end
    | if ((.rules | type) != "array") then error("rules list .rules must be array") else . end
    | [.rules[] | select((.id // "") == $rid and (.name // "") == $rname)] as $m
    | if (($m|length) != 1) then error("Expected exactly one pinned rule match") else . end
    | $m[0]
  ' "$rules_file"
}

validate_rule_shape() {
  local rule_json="$1"
  jq -e --arg path "$TARGET_PATH" --arg method "$TARGET_METHOD" '
    def is_obj: type == "object";
    def keys_exact($k): ((keys|sort) == ($k|sort));
    def cond_ok:
      ((type == "object") and keys_exact(["type","op","value"])) and
      (((.type == "path") and (.op == "eq") and (.value == $path)) or
       ((.type == "method") and (.op == "eq") and ((.value|ascii_upcase) == $method)));

    (is_obj) and
    keys_exact(["name","active","action","id","conditionGroup","valid","validationErrors","_status"]) and
    (.name == "Login rate-limit observation") and
    (.id == "rule_login_rate_limit_observation_6Qv4nI") and
    (.active | type == "boolean") and
    (.valid == true) and
    (.conditionGroup | type == "array") and
    ((.conditionGroup | length) == 1) and
    ((.conditionGroup[0] | type) == "object") and
    (((.conditionGroup[0] | keys | sort)) == ["conditions"]) and
    ((.conditionGroup[0].conditions | type) == "array") and
    ((.conditionGroup[0].conditions | length) == 2) and
    ((.conditionGroup[0].conditions | map(cond_ok) | all)) and
    ((.conditionGroup[0].conditions | map(.type) | sort) == ["method","path"]) and
    (.action | type == "object") and
    ((.action | keys | sort) == ["mitigate"]) and
    (.action.mitigate | type == "object") and
    ((.action.mitigate | keys | sort) == ["action","actionDuration","rateLimit","redirect"]) and
    (.action.mitigate.action == "rate_limit") and
    (.action.mitigate.rateLimit | type == "object") and
    ((.action.mitigate.rateLimit | keys | sort) == ["action","algo","keys","limit","window"]) and
    ((.action.mitigate.rateLimit.limit | type) == "number") and
    (.action.mitigate.rateLimit.window == 60) and
    (.action.mitigate.rateLimit.algo == "fixed_window") and
    (.action.mitigate.rateLimit.keys == ["ip"]) and
    ((.action.mitigate.rateLimit.action == "log") or (.action.mitigate.rateLimit.action == "rate_limit"))
  ' <<<"$rule_json" >/dev/null || die "Pinned rule shape invalid"
}

validate_rules_envelope() {
  local rules_file="$1"
  jq -e '
    (type == "object") and
    ((keys|sort) == ["hasDraft","pendingChanges","rules"]) and
    (.rules | type == "array") and
    (.hasDraft | type == "boolean") and
    (.pendingChanges | type == "number")
  ' "$rules_file" >/dev/null || die "Unsupported rules list envelope shape"
}

print_status() {
  local rule_json="$1"
  jq -r '
    "Rule: " + .name + " (" + .id + ")\n" +
    "Enabled: " + (.active|tostring) + "\n" +
    "Limit: " + (.action.mitigate.rateLimit.limit|tostring) + " per 60s per IP\n" +
    "Exceed action: " + .action.mitigate.rateLimit.action
  ' <<<"$rule_json"
}

assert_no_preexisting_drafts_or_changes() {
  local rules_file="$1"
  local diff_file="$2"

  jq -e '
    (.hasDraft == false) and (.pendingChanges == 0)
  ' "$rules_file" >/dev/null || die "Refusing mutate: explicit draft markers present (hasDraft/pendingChanges)"

  jq -e '
    (type == "object") and ((keys|sort) == ["changes"]) and (.changes | type == "array") and ((.changes|length) == 0)
  ' "$diff_file" >/dev/null || die "Refusing mutate: existing pending firewall diff detected"
}

build_expected_rule() {
  local pre_rule="$1"
  local mode="$2"
  local enforce_limit="${3:-}"

  if [[ "$mode" == "observe" ]]; then
    jq -c '.active = true | .action.mitigate.rateLimit.action = "log"' <<<"$pre_rule"
  elif [[ "$mode" == "enforce" ]]; then
    jq -c --argjson lim "$enforce_limit" '.active = true | .action.mitigate.rateLimit.action = "rate_limit" | .action.mitigate.rateLimit.limit = $lim' <<<"$pre_rule"
  else
    jq -c '.active = false' <<<"$pre_rule"
  fi
}

assert_diff_matches_expected() {
  local diff_file="$1"
  local expected_rule="$2"

  jq -e --arg rid "$RULE_ID" --argjson expected "$expected_rule" '
    def normalize_expected_for_diff_value:
      del(.id, .valid, .validationErrors, ._status);

    (type == "object") and
    ((keys|sort) == ["changes"]) and
    (.changes | type == "array") and
    ((.changes|length) == 1) and
    (.changes[0] | type == "object") and
    (((.changes[0] | keys | sort)) == ["action","createdAt","id","userId","username","value"]) and
    (.changes[0].action == "rules.update") and
    (.changes[0].createdAt | type == "string") and
    (.changes[0].userId | type == "string") and
    (.changes[0].username | type == "string") and
    (.changes[0].id == $rid) and
    (.changes[0].value | type == "object") and
    ((.changes[0].value | keys | sort) == ["action","active","conditionGroup","name"]) and
    (.changes[0].value == ($expected | normalize_expected_for_diff_value))
  ' "$diff_file" >/dev/null || die "Staged diff does not match exact intended single-rule update"
}

print_diff_summary() {
  local diff_file="$1"
  jq -r '
    .changes[0].value as $v
    | "Staged rule update summary:\n" +
      "- Enabled: " + ($v.active|tostring) + "\n" +
      "- Limit: " + ($v.action.mitigate.rateLimit.limit|tostring) + " per 60s per IP\n" +
      "- Exceed action: " + $v.action.mitigate.rateLimit.action
  ' "$diff_file"
}

confirm_publish() {
  local mode="$1"
  echo
  echo "About to publish firewall change for mode: $mode"
  echo "Type PUBLISH to continue (anything else aborts):"
  local response
  read -r response
  [[ "$response" == "PUBLISH" ]] || die "Publish cancelled by operator"
}

post_publish_verify() {
  local expected_rule="$1"

  local rules_after
  local diff_after
  rules_after="$(fetch_rules_json)"
  diff_after="$(fetch_diff_json)"

  validate_rules_envelope "$rules_after"
  jq -e '(.hasDraft == false) and (.pendingChanges == 0)' "$rules_after" >/dev/null || {
    rm -f "$rules_after" "$diff_after"
    die "Post-publish draft markers not clear (hasDraft/pendingChanges)"
  }

  local live_rule
  live_rule="$(extract_target_rule "$rules_after")"
  validate_rule_shape "$live_rule"

  jq -e --argjson expected "$expected_rule" '
    def strip_meta:
      del(.valid, .validationErrors, ._status, .hasDraft);
    ((. | strip_meta) == ($expected | strip_meta))
  ' <<<"$live_rule" >/dev/null || {
    rm -f "$rules_after" "$diff_after"
    die "Post-publish live rule mismatch"
  }

  jq -e '(type == "object") and ((keys|sort) == ["changes"]) and (.changes|type=="array") and ((.changes|length)==0)' "$diff_after" >/dev/null || {
    rm -f "$rules_after" "$diff_after"
    die "Post-publish diff is not empty"
  }

  rm -f "$rules_after" "$diff_after"
}

mutate_observe() {
  local current_limit="$1"
  run_vercel_firewall rules edit "$RULE_ID" \
    --action rate_limit \
    --rate-limit-window 60 \
    --rate-limit-requests "$current_limit" \
    --rate-limit-algo fixed_window \
    --rate-limit-keys ip \
    --rate-limit-action log \
    --enabled --yes >/dev/null
}
mutate_enforce() {
  local requested="$1"
  run_vercel_firewall rules edit "$RULE_ID" \
    --action rate_limit \
    --rate-limit-window 60 \
    --rate-limit-requests "$requested" \
    --rate-limit-algo fixed_window \
    --rate-limit-keys ip \
    --rate-limit-action rate_limit \
    --enabled --yes >/dev/null
}
mutate_disable() { run_vercel_firewall rules disable "$RULE_ID" --yes >/dev/null; }

[[ "$#" -eq 1 ]] || { usage; die "Expected exactly one mode argument"; }
mode="$1"

require_cmd vercel
require_cmd jq
ensure_linked_checkout

case "$mode" in
  status|observe|enforce|disable) ;;
  *) usage; die "Invalid mode: $mode" ;;
esac

rules_before="$(fetch_rules_json)"
validate_rules_envelope "$rules_before"
rule_before="$(extract_target_rule "$rules_before")"
validate_rule_shape "$rule_before"
print_status "$rule_before"

if [[ "$mode" == "status" ]]; then
  if ! jq -e '(.hasDraft == false) and (.pendingChanges == 0)' "$rules_before" >/dev/null; then
    echo
    echo "WARNING: Draft markers are present (hasDraft/pendingChanges). Status mode is read-only and will not mutate."
  fi
  diff_status="$(fetch_diff_json)"
  if ! jq -e '(type == "object") and ((keys|sort) == ["changes"]) and (.changes|type=="array") and ((.changes|length)==0)' "$diff_status" >/dev/null; then
    echo "WARNING: Non-empty or unexpected diff shape detected. Status mode is read-only and will not mutate."
  fi
  echo
  echo "Status mode is read-only. No draft/publish operations performed."
  rm -f "$rules_before" "$diff_status"
  exit 0
fi

diff_before="$(fetch_diff_json)"
assert_no_preexisting_drafts_or_changes "$rules_before" "$diff_before"
rm -f "$diff_before"

enforce_limit=""
if [[ "$mode" == "enforce" ]]; then
  echo "Enter allowed requests per public IP per 60 seconds (whole number 1..10000000):"
  read -r enforce_limit
  [[ "$enforce_limit" =~ ^(0|[1-9][0-9]*)$ ]] || die "Limit must be a canonical decimal integer"
  (( ${#enforce_limit} <= 8 )) || die "Limit out of range (must be 1..10000000)"
  (( 10#$enforce_limit >= 1 && 10#$enforce_limit <= 10000000 )) || die "Limit out of range (must be 1..10000000)"
  if (( 10#$enforce_limit <= 5 )); then
    cat <<'WARN'
WARNING: Requested threshold is <= 5.
- Shared/NAT public IPs can make multiple users share one bucket.
- WAF fixed-window buckets are independent from app-side login limiter.
WARN
  fi
fi

expected_rule="$(build_expected_rule "$rule_before" "$mode" "$enforce_limit")"
current_limit="$(jq -er '.action.mitigate.rateLimit.limit' <<<"$rule_before")"

echo
echo "Applying staged change for mode: $mode"
case "$mode" in
  observe) mutate_observe "$current_limit" ;;
  enforce) mutate_enforce "$enforce_limit" ;;
  disable) mutate_disable ;;
esac

diff_after_stage="$(fetch_diff_json)"
assert_diff_matches_expected "$diff_after_stage" "$expected_rule"
print_diff_summary "$diff_after_stage"

confirm_publish "$mode"

echo "Rechecking staged draft immediately before publish..."
diff_after_confirm="$(fetch_diff_json)"
assert_diff_matches_expected "$diff_after_confirm" "$expected_rule"
echo "WARNING: Residual TOCTOU risk remains; Vercel publish has no conditional version guard. Use an exclusive operator window."

if ! run_vercel_firewall publish --yes >/dev/null; then
  rm -f "$rules_before" "$diff_after_stage" "$diff_after_confirm"
  die "Publish failed. Script never auto-discards drafts; resolve drafts manually."
fi

post_publish_verify "$expected_rule"

echo "Publish succeeded and post-publish verification passed."
rm -f "$rules_before" "$diff_after_stage" "$diff_after_confirm"
