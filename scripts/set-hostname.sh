#!/usr/bin/env bash
# Shows and changes the hostname of a running F5 AI Security lab deployment.
#
# Use it when you cannot edit your hosts file and have no domain of your own.
# "auto" builds a hostname on a public wildcard DNS service (sslip.io or
# nip.io). Those services answer any name that contains an IP address with
# that address, so guardrails.203-0-113-10.sslip.io resolves to 203.0.113.10
# with nothing to set up.
#
# The script updates HOSTNAME in the config file and F5_HOST in lab.env, then
# runs "guardrails-poc.sh hostname" to re-apply the platform base URL, the
# certificate, and the ingress rule.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config/guardrails-poc.env"
LAB_ENV="${LAB_ENV_FILE:-$HOME/f5-ai-lab/lab.env}"
DRY_RUN=false
ACTION=""
NEW_NAME=""
SERVICE="sslip.io"
PREFIX="guardrails"

usage() {
  cat <<'EOF'
Usage:
  scripts/set-hostname.sh [--config FILE] show
  scripts/set-hostname.sh [--config FILE] [--dry-run] auto [--service sslip.io|nip.io] [--prefix NAME]
  scripts/set-hostname.sh [--config FILE] [--dry-run] set HOSTNAME

Actions:
  show   Print the current hostname, the load balancer's DNS name and IP
         addresses, what the hostname resolves to from this machine, and the
         name "auto" would choose.
  auto   Switch to a hostname on a public wildcard DNS service. No hosts file
         entry and no domain are needed. Turns Route 53 management off.
  set    Switch to a hostname you manage in your own DNS service. Create a
         CNAME record from that hostname to the load balancer DNS name that
         "show" prints.

After "auto" or "set":
  1. source ~/f5-ai-lab/lab.env
  2. Save the lab certificate again (lab guide step 2.8). It is issued for the
     exact hostname, so the old file no longer matches.
  3. Start the LobeChat containers again (step 4.1) if they were running.

Examples:
  scripts/set-hostname.sh show
  scripts/set-hostname.sh auto
  scripts/set-hostname.sh auto --service nip.io
  scripts/set-hostname.sh set guardrails.lab.example.com
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)  [[ $# -ge 2 ]] || die "--config requires a file path"; CONFIG_FILE="$2"; shift 2 ;;
    --service) [[ $# -ge 2 ]] || die "--service requires sslip.io or nip.io"; SERVICE="$2"; shift 2 ;;
    --prefix)  [[ $# -ge 2 ]] || die "--prefix requires a name"; PREFIX="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage; exit 0 ;;
    show|auto|set)
      [[ -z "$ACTION" ]] || die "Only one action is allowed"
      ACTION="$1"; shift ;;
    *)
      [[ "$ACTION" == "set" && -z "$NEW_NAME" ]] || die "Unknown argument: $1 (run with --help)"
      NEW_NAME="$1"; shift ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 1; }
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE
Create it first: cp config/guardrails-poc.env.example config/guardrails-poc.env"
[[ "$SERVICE" == "sslip.io" || "$SERVICE" == "nip.io" ]] || die "--service must be sslip.io or nip.io"
[[ "$PREFIX" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "--prefix may contain only lowercase letters, digits, and hyphens"
if [[ "$ACTION" == "set" ]]; then
  [[ -n "$NEW_NAME" ]] || die "set needs a hostname (run with --help)"
  NEW_NAME="$(printf '%s' "$NEW_NAME" | tr '[:upper:]' '[:lower:]')"
  [[ "$NEW_NAME" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] \
    || die "\"$NEW_NAME\" is not a valid hostname. Give a full name such as guardrails.lab.example.com, without https://"
fi
for cmd in kubectl python3; do
  command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required"
done

# Read settings without touching the caller's environment.
read_setting() {
  local name="$1" fallback="$2"
  (
    set +u
    unset "$name"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" >/dev/null 2>&1
    eval "printf '%s' \"\${$name:-$fallback}\""
  )
}

CURRENT_HOSTNAME="$(read_setting HOSTNAME guardrails.f5demo.io)"
INGRESS_NAMESPACE_VALUE="$(read_setting INGRESS_NAMESPACE nginx-ingress)"
INGRESS_SERVICE_VALUE="$(read_setting INGRESS_CONTROLLER_SERVICE nginx-ingress-controller)"
ROUTE53_VALUE="$(read_setting ROUTE53_ENABLED false)"

poc() {
  local -a cmd
  cmd=("$SCRIPT_DIR/guardrails-poc.sh" --config "$CONFIG_FILE")
  if [[ "$DRY_RUN" == true ]]; then
    cmd+=(--dry-run)
  fi
  "${cmd[@]}" "$@"
}

lb_dns_name() {
  kubectl get svc -n "$INGRESS_NAMESPACE_VALUE" "$INGRESS_SERVICE_VALUE" \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true
}

# IPv4 addresses a name resolves to from this machine, one per line.
resolve_name() {
  python3 - "$1" <<'PY' 2>/dev/null || true
import socket, sys
seen = []
try:
    for info in socket.getaddrinfo(sys.argv[1], 443, socket.AF_INET, socket.SOCK_STREAM):
        ip = info[4][0]
        if ip not in seen:
            seen.append(ip)
except Exception:
    pass
print("\n".join(seen))
PY
}

# From a list of addresses, print the first that accepts a connection on 443,
# or the first one if none answers (for example when this machine's IP is not
# on the allowed list yet).
pick_address() {
  python3 - "$@" <<'PY'
import socket, sys
ips = sys.argv[1:]
for ip in ips:
    try:
        with socket.create_connection((ip, 443), timeout=4):
            print(ip)
            raise SystemExit
    except SystemExit:
        raise
    except Exception:
        continue
print(ips[0])
PY
}

LB_DNS="$(lb_dns_name)"
LB_IPS=""
if [[ -n "$LB_DNS" ]]; then
  LB_IPS="$(resolve_name "$LB_DNS")"
fi

auto_name() {
  local ip
  [[ -n "$LB_IPS" ]] || return 1
  # shellcheck disable=SC2086
  ip="$(pick_address $LB_IPS)"
  printf '%s.%s.%s' "$PREFIX" "${ip//./-}" "$SERVICE"
}

show() {
  local resolved suggestion
  printf 'Config file:               %s\n' "$CONFIG_FILE"
  printf 'Current hostname:          %s\n' "$CURRENT_HOSTNAME"
  printf 'Route 53 managed:          %s\n' "$ROUTE53_VALUE"
  if [[ -z "$LB_DNS" ]]; then
    printf 'Load balancer DNS name:    not found (run ./scripts/guardrails-poc.sh up first, and check that kubectl points at your cluster)\n'
    return
  fi
  printf 'Load balancer DNS name:    %s\n' "$LB_DNS"
  printf 'Load balancer addresses:   %s\n' "$(printf '%s' "${LB_IPS:-could not be resolved}" | tr '\n' ' ')"
  resolved="$(resolve_name "$CURRENT_HOSTNAME" | tr '\n' ' ')"
  printf 'Current hostname resolves: %s\n' "${resolved:-no (not in DNS; a hosts file entry is not checked here)}"
  if suggestion="$(auto_name)"; then
    printf '"auto" would use:          %s\n' "$suggestion"
  fi
  printf '\nFor your own DNS service, create this record and then run "set <hostname>":\n'
  printf '  <hostname>  CNAME  %s\n' "$LB_DNS"
}

apply_name() {
  local name="$1" turn_off_route53="$2"
  if [[ "$name" == "$CURRENT_HOSTNAME" ]]; then
    printf 'The hostname is already %s. Re-applying it.\n' "$name"
  else
    printf 'Changing the hostname from %s to %s\n' "$CURRENT_HOSTNAME" "$name"
  fi

  if [[ "$DRY_RUN" == true ]]; then
    printf '+ set HOSTNAME="%s" in %s\n' "$name" "$CONFIG_FILE"
    [[ "$turn_off_route53" != true ]] || printf '+ set ROUTE53_ENABLED="false" in %s\n' "$CONFIG_FILE"
    printf '+ set F5_HOST="%s" in %s\n' "$name" "$LAB_ENV"
    printf '(dry run: nothing is changed, so the lines below still show the current hostname)\n'
  else
    LAB_CONFIG_FILE="$CONFIG_FILE" "$SCRIPT_DIR/labvar" --config HOSTNAME "$name" >/dev/null
    if [[ "$turn_off_route53" == true && "$ROUTE53_VALUE" == "true" ]]; then
      LAB_CONFIG_FILE="$CONFIG_FILE" "$SCRIPT_DIR/labvar" --config ROUTE53_ENABLED false >/dev/null
      printf 'Route 53 management turned off, because the wildcard DNS service answers for this name.\n'
    fi
    if [[ -f "$LAB_ENV" ]]; then
      LAB_ENV_FILE="$LAB_ENV" "$SCRIPT_DIR/labvar" F5_HOST "$name" >/dev/null
    else
      printf 'NOTE: %s not found, so F5_HOST was not updated there.\n' "$LAB_ENV"
    fi
  fi

  poc hostname

  cat <<EOF

The hostname is now: $name
Open: https://$name

Do these next:
  1. source $LAB_ENV
  2. Save the lab certificate again (lab guide step 2.8). The old file was issued for the old hostname.
  3. If you added a hosts file entry for the old hostname, remove it, and run: unset F5_LB_IP
  4. If the LobeChat containers are running, start them again (step 4.1).
Your project tokens and Bedrock connection are unchanged.
EOF
}

case "$ACTION" in
  show)
    show
    ;;
  auto)
    [[ -n "$LB_DNS" ]] || die "The load balancer was not found. Run ./scripts/guardrails-poc.sh up first, and check that kubectl points at your cluster."
    [[ -n "$LB_IPS" ]] || die "Could not resolve the load balancer DNS name $LB_DNS from this machine. A new load balancer can take a few minutes to appear in DNS; try again shortly."
    NEW_NAME="$(auto_name)"
    expected="${NEW_NAME#"$PREFIX".}"; expected="${expected%."$SERVICE"}"; expected="${expected//-/.}"
    answer="$(resolve_name "$NEW_NAME" | head -1)"
    if [[ "$answer" != "$expected" ]]; then
      die "This network does not resolve $SERVICE names ($NEW_NAME returned \"${answer:-nothing}\", expected $expected).
Some company DNS servers block these services. Try the other one (--service nip.io or --service sslip.io),
try off VPN, or use a hostname in your own DNS service with: scripts/set-hostname.sh set <hostname>
Nothing was changed."
    fi
    apply_name "$NEW_NAME" true
    ;;
  set)
    if [[ -n "$LB_IPS" ]]; then
      answer="$(resolve_name "$NEW_NAME" | head -1)"
      if [[ -z "$answer" ]]; then
        printf 'WARNING: %s does not resolve from this machine yet. Create this DNS record:\n  %s  CNAME  %s\n\n' "$NEW_NAME" "$NEW_NAME" "$LB_DNS"
      elif ! grep -qx "$answer" <<<"$LB_IPS"; then
        printf 'WARNING: %s resolves to %s, which is not one of the load balancer addresses (%s).\n\n' "$NEW_NAME" "$answer" "$(printf '%s' "$LB_IPS" | tr '\n' ' ')"
      fi
    fi
    apply_name "$NEW_NAME" false
    ;;
esac
