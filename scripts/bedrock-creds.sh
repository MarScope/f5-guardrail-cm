#!/usr/bin/env bash
# Hands your AWS credentials to the F5 AI Security Bedrock connection without
# ever showing them on screen.
#
# The Bedrock connection (lab guide step 3.2) signs each request to Bedrock
# with AWS credentials stored as six secrets. The platform's secret field cuts
# long values short, so the session token has to be entered in four pieces.
# This script reads the credentials of your current AWS sign-in, splits the
# token, and puts each value on the clipboard in turn while it tells you which
# field to paste it into.
#
#   scripts/bedrock-creds.sh             guided copy of all six secrets
#   scripts/bedrock-creds.sh check       show lengths and expiry only
#   scripts/bedrock-creds.sh template    copy the connection template only
#
# Nothing is written to disk and no secret value is printed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_FILE="$ROOT_DIR/config/bedrock-converse-template.yaml"
PART_SIZE=249
PROMPT_DEVICE="${BEDROCK_CREDS_TTY:-/dev/tty}"
ACTION="${1:-guide}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

case "$ACTION" in
  guide|check|template) ;;
  -h|--help) sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown action: $ACTION (use guide, check, or template)" ;;
esac

# --- clipboard -------------------------------------------------------------

CLIP_CMD=""
find_clipboard() {
  if command -v pbcopy >/dev/null 2>&1; then CLIP_CMD="pbcopy"
  elif command -v clip.exe >/dev/null 2>&1; then CLIP_CMD="clip.exe"
  elif command -v wl-copy >/dev/null 2>&1; then CLIP_CMD="wl-copy"
  elif command -v xclip >/dev/null 2>&1; then CLIP_CMD="xclip -selection clipboard"
  elif command -v xsel >/dev/null 2>&1; then CLIP_CMD="xsel --clipboard --input"
  else
    die "No clipboard command found. On Linux install one: sudo apt-get install -y xclip
(macOS has pbcopy and WSL has clip.exe already.)"
  fi
}

to_clipboard() {
  # shellcheck disable=SC2086
  printf '%s' "$1" | $CLIP_CMD
}

wait_for_enter() {
  printf '%s' "$1"
  local _reply
  read -r _reply < "$PROMPT_DEVICE" || true
}

# --- credentials -----------------------------------------------------------

load_credentials() {
  command -v aws >/dev/null 2>&1 || die "The aws command is required"
  local exported
  exported="$(aws configure export-credentials --format env 2>/dev/null)" \
    || die "Could not read your AWS credentials. Sign in again as in lab guide step 1.4, then rerun this script.
(Method 1: aws sso login --profile \"\$AWS_PROFILE\")"
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION
  eval "$exported"
  [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]] \
    || die "Your AWS sign-in returned no access key. Sign in again as in lab guide step 1.4."
  TOKEN="${AWS_SESSION_TOKEN:-}"
}

# Size of each token piece: 249 characters, or a quarter of the token if it is
# longer than four pieces of 249.
piece_size() {
  local len="${#TOKEN}" size="$PART_SIZE"
  if [[ "$len" -gt $((PART_SIZE * 4)) ]]; then
    size=$(( (len + 3) / 4 ))
  fi
  printf '%s' "$size"
}

expiry_summary() {
  EXPIRY="${AWS_CREDENTIAL_EXPIRATION:-}" python3 - <<'PY'
import os
from datetime import datetime, timezone
raw = os.environ.get("EXPIRY", "")
if not raw:
    print("Expires:            no expiry reported (long-lived access key, or the sign-in method does not say)")
else:
    try:
        when = datetime.fromisoformat(raw.replace("Z", "+00:00"))
        left = int((when - datetime.now(timezone.utc)).total_seconds() // 60)
        local = when.astimezone().strftime("%Y-%m-%d %H:%M %Z")
        print("Expires:            %s  (%s UTC)" % (local, when.astimezone(timezone.utc).strftime("%H:%M")))
        if left <= 0:
            print("WARNING: these credentials have already expired. Sign in again (step 1.4) and rerun.")
        elif left < 60:
            print("WARNING: only %d minutes left. Sign in again (step 1.4) first to get a full session." % left)
        else:
            print("Time left:          %d h %02d min. Every model call fails after that, until you refresh." % (left // 60, left % 60))
    except Exception:
        print("Expires:            %s" % raw)
PY
}

summary() {
  local kind="unknown" size
  case "$AWS_ACCESS_KEY_ID" in
    ASIA*) kind="temporary (starts with ASIA)" ;;
    AKIA*) kind="long-lived (starts with AKIA)" ;;
  esac
  size="$(piece_size)"
  printf 'Access key ID:      %s characters, %s\n' "${#AWS_ACCESS_KEY_ID}" "$kind"
  printf 'Secret access key:  %s characters\n' "${#AWS_SECRET_ACCESS_KEY}"
  if [[ -n "$TOKEN" ]]; then
    printf 'Session token:      %s characters, entered as 4 pieces of up to %s\n' "${#TOKEN}" "$size"
  else
    printf 'Session token:      none (long-lived access key). Leave the four token secrets empty.\n'
  fi
  expiry_summary
  [[ "${#AWS_ACCESS_KEY_ID}" -eq 20 ]] || printf 'WARNING: an access key ID is normally 20 characters.\n'
  [[ "${#AWS_SECRET_ACCESS_KEY}" -eq 40 ]] || printf 'WARNING: a secret access key is normally 40 characters.\n'
  if [[ "$size" -gt "$PART_SIZE" ]]; then
    printf 'WARNING: your session token is longer than %s characters, so each piece is %s characters.\n' "$((PART_SIZE * 4))" "$size"
    printf '         Pieces above %s characters have not been tested and the platform may cut them short.\n' "$PART_SIZE"
    printf '         If the connection test reports an invalid security token, tell your instructor.\n'
  fi
}

copy_step() {
  local number="$1" total="$2" name="$3" value="$4"
  to_clipboard "$value"
  printf '\n[%s/%s] Copied %s (%s characters).\n' "$number" "$total" "$name" "${#value}"
  printf '      In the connection form, clear the secret named  %s  and paste.\n' "$name"
  wait_for_enter '      Press Enter when you have pasted it. '
}

copy_template() {
  [[ -f "$TEMPLATE_FILE" ]] || die "Template not found: $TEMPLATE_FILE"
  to_clipboard "$(cat "$TEMPLATE_FILE")"
  printf 'Copied the connection template to the clipboard (%s lines).\n' "$(wc -l < "$TEMPLATE_FILE" | tr -d ' ')"
  printf 'Paste it into the YAML box of the connection form, replacing whatever is there.\n'
}

case "$ACTION" in
  template)
    find_clipboard
    copy_template
    ;;
  check)
    load_credentials
    summary
    ;;
  guide)
    find_clipboard
    load_credentials
    printf 'Credentials for the Bedrock connection\n'
    printf '======================================\n'
    summary
    printf '\nSecret names are case sensitive and must match exactly.\n'
    printf 'Each value goes on your clipboard. Nothing secret is shown here.\n'

    if [[ -n "$TOKEN" ]]; then
      size="$(piece_size)"
      copy_step 1 6 awsAccessKeyId "$AWS_ACCESS_KEY_ID"
      copy_step 2 6 awsSecretAccessKey "$AWS_SECRET_ACCESS_KEY"
      copy_step 3 6 awsSessionTokenPart1 "${TOKEN:0:size}"
      copy_step 4 6 awsSessionTokenPart2 "${TOKEN:size:size}"
      copy_step 5 6 awsSessionTokenPart3 "${TOKEN:size*2:size}"
      copy_step 6 6 awsSessionTokenPart4 "${TOKEN:size*3}"
    else
      copy_step 1 2 awsAccessKeyId "$AWS_ACCESS_KEY_ID"
      copy_step 2 2 awsSecretAccessKey "$AWS_SECRET_ACCESS_KEY"
      printf '\nLeave awsSessionTokenPart1 to awsSessionTokenPart4 empty.\n'
    fi

    INPUTS="modelId: ${BEDROCK_MODEL:-us.amazon.nova-lite-v1:0}
awsRegion: ${BEDROCK_REGION:-us-east-1}
maxTokens: 2048
temperature: 0.2
topP: 0.9"
    to_clipboard "$INPUTS"
    cat <<EOF

The clipboard no longer holds a secret. It now holds the inputs for the same
form, which are not secret. Paste them into the inputs section:

$INPUTS

Then select Test and connect.
EOF
    ;;
esac

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_CREDENTIAL_EXPIRATION TOKEN
