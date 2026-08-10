#!/usr/bin/env bash
# Record a PR-ready task: validate any project-owned delivery rule, store one
# validated canonical pr=<url> and the forge's exact pr_head=<sha> when
# available, then atomically arm a static merge poll.
# The watcher check source is byte-for-byte bin/fm-pr-poll.sh; task and PR data
# live only in a private sidecar and are never interpolated into shell source.
# GitHub and Forgejo pull request URLs and GitLab merge request URLs are
# accepted, including self-hosted Forgejo and GitLab instances.
# Usage: fm-pr-check.sh <task-id> <pr-url>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

if [ "$#" -ne 2 ]; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
ID=$1
RAW_URL=$2
if ! fm_pr_task_id_valid "$ID" || ! fm_pr_url_parse "$RAW_URL"; then
  echo "error: invalid PR check request" >&2
  exit 2
fi
URL=$FM_PR_URL
PROVIDER=$FM_PR_PROVIDER
HOST=$FM_PR_HOST
PROJECT_PATH=$FM_PR_PATH
NUMBER=$FM_PR_NUMBER

# Task-derived paths are constructed only after the canonical ID validation.
META="$STATE/$ID.meta"
if [ ! -f "$META" ] || [ -L "$META" ] || [ "$(fm_pr_file_link_count "$META")" != 1 ]; then
  echo "error: task metadata is unavailable" >&2
  exit 1
fi

load_task_metadata_fields() {
  PROJECT=$(grep '^project=' "$META" | tail -1 | cut -d= -f2- || true)
  ISSUE_KEY=$(grep '^issue_key=' "$META" | tail -1 | cut -d= -f2- || true)
  DELIVERY_TITLE_RULE=$(grep '^delivery_title_rule=' "$META" | tail -1 | cut -d= -f2- || true)
  DELIVERY_LINK_RULE=$(grep '^delivery_link_rule=' "$META" | tail -1 | cut -d= -f2- || true)
  WT=$(grep '^worktree=' "$META" | tail -1 | cut -d= -f2- || true)
}

validate_task_metadata_fields() {
  if [ -n "$ISSUE_KEY" ] && ! printf '%s\n' "$ISSUE_KEY" | grep -Eq '^[A-Z][A-Z0-9]*-[0-9]+$'; then
    echo "error: task metadata carries an invalid issue key" >&2
    return 1
  fi
  if [ -n "$DELIVERY_TITLE_RULE" ] || [ -n "$DELIVERY_LINK_RULE" ]; then
    if [ -z "$DELIVERY_TITLE_RULE" ] || [ -z "$DELIVERY_LINK_RULE" ] \
      || ! fm_pr_delivery_rule_valid "$DELIVERY_TITLE_RULE" \
      || ! fm_pr_delivery_rule_valid "$DELIVERY_LINK_RULE"; then
        echo "error: task metadata carries an invalid delivery rule" >&2
        return 1
    fi
  fi
  DELIVERY_RULE=0
  [ -z "$ISSUE_KEY" ] || [ -z "$DELIVERY_TITLE_RULE" ] || [ -z "$DELIVERY_LINK_RULE" ] || DELIVERY_RULE=1
  if [ "$PROVIDER" = forgejo ] && ! fm_pr_forgejo_project_authorized "$PROJECT" "$HOST"; then
    echo "error: Forgejo host is not authorized by the task project remotes" >&2
    return 1
  fi
}

validate_provider_delivery_fields() {
  if [ "$DELIVERY_RULE" = 1 ]; then
    [ -n "$PR_TITLE" ] && [ -n "$PR_BODY" ] || {
      echo "error: could not read PR title and body for delivery validation" >&2
      return 1
    }
    fm_pr_delivery_title_matches "$PR_TITLE" "$DELIVERY_TITLE_RULE" "$ISSUE_KEY" || {
      echo "error: PR title does not match the declared delivery rule" >&2
      return 1
    }
    fm_pr_delivery_body_links_issue "$PR_BODY" "$DELIVERY_LINK_RULE" "$ISSUE_KEY" || {
      echo "error: PR body does not link the expected issue" >&2
      return 1
    }
  fi
}

load_task_metadata_fields
validate_task_metadata_fields || exit 1
INITIAL_PROJECT=$PROJECT
INITIAL_ISSUE_KEY=$ISSUE_KEY
INITIAL_DELIVERY_TITLE_RULE=$DELIVERY_TITLE_RULE
INITIAL_DELIVERY_LINK_RULE=$DELIVERY_LINK_RULE
INITIAL_WT=$WT

# A prior exact merged result may have queued its durable wake immediately
# before interruption.
# Finish only its identity-bound receipt before publishing a replacement poll.
fm_pr_poll_retirement_recover_one "$STATE" "$ID" "$SCRIPT_DIR/fm-pr-poll.sh" || {
  echo "error: pending PR poll retirement could not be validated" >&2
  exit 1
}

# Refuse to arm a GitLab watch with no glab on PATH. The poll is silent on
# every error by design, so a missing CLI would be indistinguishable from a
# merge request that is never merged. Arming is the one point where that can be
# reported, so the absent tool stops the watch here instead of watching nothing.
if [ "$PROVIDER" = gitlab ] && ! command -v glab >/dev/null 2>&1; then
  echo "error: watching a GitLab merge request requires glab on PATH" >&2
  exit 1
fi
if [ "$PROVIDER" = forgejo ] && ! command -v forgejo-axi >/dev/null 2>&1; then
  echo "error: watching a Forgejo pull request requires forgejo-axi on PATH" >&2
  exit 1
fi

"$FM_ROOT/bin/fm-guard.sh" || true

# pr_head is recorded only when the forge's CLI can supply it without an extra
# JSON dependency. GitLab records none. Teardown and review-diff tolerate that
# omission through their content-check and local-branch fallbacks.
PR_HEAD=
PR_TITLE=
PR_BODY=
PROVIDER_FIELDS_REQUIRED=1
[ "$PROVIDER" = gitlab ] && PROVIDER_FIELDS_REQUIRED=$DELIVERY_RULE
fm_pr_provider_fields_load "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$WT" \
  "$PROVIDER_FIELDS_REQUIRED" || exit 1
PR_TITLE=$FM_PR_PROVIDER_TITLE
PR_BODY=$FM_PR_PROVIDER_BODY
if fm_pr_head_valid "$FM_PR_PROVIDER_HEAD"; then
  PR_HEAD=$FM_PR_PROVIDER_HEAD
fi

validate_provider_delivery_fields || exit 1

META_TMP=
META_LOCK=
META_LOCK_HELD=0
pr_check_cleanup() {
  fm_pr_poll_cleanup
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  if [ "$META_LOCK_HELD" = 1 ]; then
    fm_lock_release "$META_LOCK" || true
    META_LOCK_HELD=0
  fi
}
trap pr_check_cleanup EXIT
trap 'exit 1' HUP INT TERM
META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task metadata is unavailable" >&2; exit 1; }
META_DEVICE=$(fm_pr_file_device "$META") || exit 1
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
[ "$META_DEVICE" = "$STATE_DEVICE" ] || { echo "error: task metadata is unavailable" >&2; exit 1; }
load_task_metadata_fields
validate_task_metadata_fields || exit 1
[ "$PROJECT" = "$INITIAL_PROJECT" ] \
  && [ "$ISSUE_KEY" = "$INITIAL_ISSUE_KEY" ] \
  && [ "$DELIVERY_TITLE_RULE" = "$INITIAL_DELIVERY_TITLE_RULE" ] \
  && [ "$DELIVERY_LINK_RULE" = "$INITIAL_DELIVERY_LINK_RULE" ] \
  && [ "$WT" = "$INITIAL_WT" ] || {
    echo "error: task metadata changed during PR validation" >&2
    exit 1
  }
validate_provider_delivery_fields || exit 1

# Neutralize any pre-fix poll before recording or arming this task. The
# migration never executes legacy artifacts and holds watcher exclusion while
# it quarantines or rebuilds them.
"$SCRIPT_DIR/fm-pr-check-migrate.sh" --checks-safe || exit 1
fm_pr_poll_prepare "$STATE" "$ID" "$PROVIDER" "$URL" "$HOST" "$PROJECT_PATH" "$NUMBER" "$SCRIPT_DIR/fm-pr-poll.sh" \
  || { echo "error: could not prepare PR poll" >&2; exit 1; }

META_TMP=$(mktemp "$STATE/.fm-pr-meta.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    pr=*|pr_head=*) ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
printf 'pr=%s\n' "$URL" >> "$META_TMP" || exit 1
[ -z "$PR_HEAD" ] || printf 'pr_head=%s\n' "$PR_HEAD" >> "$META_TMP" || exit 1
chmod 0600 "$META_TMP" || exit 1
fm_pr_private_file_valid "$META_TMP" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META_TMP" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1
fm_pr_regular_destination_on_device_or_absent "$META" "$STATE_DEVICE" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=
fm_pr_private_file_valid "$META" 600 "$STATE_DEVICE" || exit 1
fm_pr_metadata_identity_parse "$META" || exit 1
[ "$FM_PR_META_PROVIDER" = "$PROVIDER" ] && [ "$FM_PR_META_URL" = "$URL" ] \
  && [ "$FM_PR_META_HOST" = "$HOST" ] && [ "$FM_PR_META_PATH" = "$PROJECT_PATH" ] \
  && [ "$FM_PR_META_NUMBER" = "$NUMBER" ] || exit 1

fm_pr_poll_publish_prepared || {
  echo "error: could not publish PR poll" >&2
  exit 1
}
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0
printf 'armed: state/%s.check.sh\n' "$ID"
