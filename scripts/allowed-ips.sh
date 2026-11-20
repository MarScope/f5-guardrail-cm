#!/usr/bin/env bash
# Shows and changes which source addresses may reach the F5 AI Security
# load balancer created by guardrails-poc.sh.
#
# The list lives in ALLOWED_SOURCE_CIDRS in the config file. This script edits
# that setting and then applies it with "guardrails-poc.sh access", so the
# config and the live load balancer always agree.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="$ROOT_DIR/config/guardrails-poc.env"
DRY_RUN=false
ACTION=""
ARGS=()

usage() {
  cat <<'EOF'
Usage:
  scripts/allowed-ips.sh [--config FILE] [--dry-run] show
  scripts/allowed-ips.sh [--config FILE] [--dry-run] add ADDRESS [ADDRESS...]
  scripts/allowed-ips.sh [--config FILE] [--dry-run] remove ADDRESS [ADDRESS...]
  scripts/allowed-ips.sh [--config FILE] [--dry-run] set ADDRESS [ADDRESS...]
  scripts/allowed-ips.sh [--config FILE] [--dry-run] refresh

Actions:
  show      Print the configured list, what the load balancer accepts right now,
            this machine's public IP, and the matching security group rules.
  add       Allow more addresses, keeping the ones already allowed.
  remove    Stop allowing the given addresses.
  set       Replace the whole list.
  refresh   Re-apply the list. Use it after your own public IP changes.

ADDRESS is an IPv4 address (203.0.113.10), an IPv4 range in CIDR form
(203.0.113.0/24), or the word "me" for the public IP of this machine.
"me" is stored as "auto", so it follows this machine when its IP changes
and you run refresh.

Examples:
  scripts/allowed-ips.sh show
  scripts/allowed-ips.sh add 203.0.113.10
  scripts/allowed-ips.sh add me 198.51.100.0/24
  scripts/allowed-ips.sh remove 203.0.113.10
  scripts/allowed-ips.sh set me
  scripts/allowed-ips.sh refresh
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a file path"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    show|add|remove|set|refresh)
      [[ -z "$ACTION" ]] || die "Only one action is allowed"
      ACTION="$1"
      shift
      ;;
    *)
      [[ -n "$ACTION" ]] || die "Unknown action: $1 (run with --help)"
      ARGS+=("$1")
      shift
      ;;
  esac
done

[[ -n "$ACTION" ]] || { usage; exit 1; }
[[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE
Create it first: cp config/guardrails-poc.env.example config/guardrails-poc.env"

case "$ACTION" in
  add|remove|set)
    [[ ${#ARGS[@]} -gt 0 ]] || die "$ACTION needs at least one address (run with --help)"
    ;;
  show|refresh)
    [[ ${#ARGS[@]} -eq 0 ]] || die "$ACTION takes no addresses"
    ;;
esac

# Read the settings this script needs without touching the caller's environment.
read_setting() {
  local name="$1" fallback="$2"
  (
    set +u
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" >/dev/null 2>&1
    eval "printf '%s' \"\${$name:-$fallback}\""
  )
}

AWS_REGION_VALUE="$(read_setting AWS_REGION us-east-1)"
CLUSTER_NAME_VALUE="$(read_setting CLUSTER_NAME f5-guardrails-poc)"
INGRESS_NAMESPACE_VALUE="$(read_setting INGRESS_NAMESPACE nginx-ingress)"
INGRESS_SERVICE_VALUE="$(read_setting INGRESS_CONTROLLER_SERVICE nginx-ingress-controller)"
RESTRICT_VALUE="$(read_setting RESTRICT_INGRESS_SOURCE true)"
CURRENT_LIST="$(read_setting ALLOWED_SOURCE_CIDRS auto)"
LOOKUP_URL="$(read_setting PUBLIC_IP_LOOKUP_URL https://checkip.amazonaws.com)"

public_ip() {
  curl -fsS --max-time 10 "$LOOKUP_URL" 2>/dev/null | tr -d '[:space:]' || true
}

poc() {
  local -a cmd
  cmd=("$SCRIPT_DIR/guardrails-poc.sh" --config "$CONFIG_FILE")
  if [[ "$DRY_RUN" == true ]]; then
    cmd+=(--dry-run)
  fi
  "${cmd[@]}" "$@"
}

show() {
  local live my_ip sg_id node_ports
  printf 'Config file:               %s\n' "$CONFIG_FILE"
  printf 'Configured list:           %s\n' "$CURRENT_LIST"
  if [[ "$RESTRICT_VALUE" != "true" ]]; then
    printf 'WARNING: RESTRICT_INGRESS_SOURCE is not true, so the list is not enforced.\n'
  fi

  my_ip="$(public_ip)"
  printf 'This machine (public IP):  %s\n' "${my_ip:-could not be detected}"

  if [[ "$DRY_RUN" == true ]]; then
    printf '(dry run: not querying the cluster or AWS)\n'
    return
  fi

  if ! aws eks update-kubeconfig --name "$CLUSTER_NAME_VALUE" --region "$AWS_REGION_VALUE" >/dev/null 2>&1; then
    printf 'Cluster:                   %s not reachable in %s (not deployed yet, or not signed in to AWS)\n' "$CLUSTER_NAME_VALUE" "$AWS_REGION_VALUE"
    return
  fi

  live="$(kubectl get svc -n "$INGRESS_NAMESPACE_VALUE" "$INGRESS_SERVICE_VALUE" -o jsonpath='{.spec.loadBalancerSourceRanges[*]}' 2>/dev/null || true)"
  if ! kubectl get svc -n "$INGRESS_NAMESPACE_VALUE" "$INGRESS_SERVICE_VALUE" >/dev/null 2>&1; then
    printf 'Load balancer accepts:     ingress service not found (run guardrails-poc.sh up)\n'
    return
  fi
  printf 'Load balancer accepts:     %s\n' "${live:-EVERY ADDRESS (no restriction is set)}"

  if [[ -n "$my_ip" && -n "$live" ]]; then
    # shellcheck disable=SC2086
    python3 - "$my_ip" $live <<'PY'
import ipaddress
import sys

ip = ipaddress.ip_address(sys.argv[1])
allowed = any(ip in ipaddress.ip_network(c, strict=False) for c in sys.argv[2:])
print("This machine is allowed:   %s" % ("yes" if allowed else "NO - run: scripts/allowed-ips.sh refresh"))
PY
  fi

  node_ports="$(kubectl get svc -n "$INGRESS_NAMESPACE_VALUE" "$INGRESS_SERVICE_VALUE" -o jsonpath='{.spec.ports[*].nodePort}' 2>/dev/null || true)"
  sg_id="$(aws eks describe-cluster --name "$CLUSTER_NAME_VALUE" --region "$AWS_REGION_VALUE" --query 'cluster.resourcesVpcConfig.clusterSecurityGroupId' --output text 2>/dev/null || true)"
  printf 'Node security group:       %s\n' "${sg_id:-unknown}"
  printf 'Node ports:                %s\n' "${node_ports:-unknown}"
  [[ -n "$sg_id" && "$sg_id" != "None" && -n "$node_ports" ]] || return 0

  printf '\nSecurity group rules for those ports (what AWS enforces):\n'
  # shellcheck disable=SC2086
  aws ec2 describe-security-group-rules --region "$AWS_REGION_VALUE" \
    --filters "Name=group-id,Values=$sg_id" \
    --query 'SecurityGroupRules[?IsEgress==`false`].[FromPort,ToPort,CidrIpv4,Description]' \
    --output text 2>/dev/null | python3 -c '
import sys

ports = set(sys.argv[1:])
rows = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) < 3:
        continue
    start, end, cidr = parts[0], parts[1], parts[2]
    desc = parts[3] if len(parts) > 3 else ""
    if cidr in ("None", ""):
        continue
    if start in ports or end in ports:
        rows.append((start, cidr, desc))
if not rows:
    print("  none found yet (rules can take a minute to appear)")
for start, cidr, desc in sorted(rows):
    flag = "   <-- OPEN TO EVERY ADDRESS" if cidr == "0.0.0.0/0" else ""
    print("  port %-6s %-20s %s%s" % (start, cidr, "" if desc == "None" else desc, flag))
' $node_ports || printf '  could not read the security group rules\n'
}

# Prints the new value for ALLOWED_SOURCE_CIDRS on stdout, notes on stderr.
new_list() {
  python3 - "$ACTION" "$CURRENT_LIST" "$@" <<'PY'
import ipaddress
import sys

action, current, args = sys.argv[1], sys.argv[2], sys.argv[3:]


def parse(item):
    if item.lower() in ("me", "auto"):
        return "auto"
    try:
        net = ipaddress.ip_network(item if "/" in item else item + "/32", strict=False)
    except ValueError:
        sys.exit("Not a valid IPv4 address or CIDR: %s" % item)
    if net.version != 4:
        sys.exit("Only IPv4 addresses and CIDRs are supported: %s" % item)
    return str(net)


def unique(items):
    out = []
    for item in items:
        if item not in out:
            out.append(item)
    return out


existing = unique(parse(i) for i in current.replace(",", " ").split())
wanted = unique(parse(a) for a in " ".join(args).replace(",", " ").split())

if action == "set":
    result = wanted
elif action == "add":
    result = unique(existing + wanted)
    for item in wanted:
        if item in existing:
            sys.stderr.write("Already allowed: %s\n" % item)
else:
    result = [i for i in existing if i not in wanted]
    for item in wanted:
        if item not in existing:
            sys.stderr.write("Was not in the list: %s\n" % item)

if not result:
    sys.exit("That would leave the list empty, which would lock everyone out. Nothing was changed.")
if "0.0.0.0/0" in result:
    sys.stderr.write("WARNING: 0.0.0.0/0 allows every address on the internet.\n")
print(" ".join(result))
PY
}

case "$ACTION" in
  show)
    show
    ;;
  refresh)
    [[ "$RESTRICT_VALUE" == "true" ]] || die "RESTRICT_INGRESS_SOURCE is not true in $CONFIG_FILE. Set it to \"true\" first."
    poc access
    ;;
  add|remove|set)
    [[ "$RESTRICT_VALUE" == "true" ]] || die "RESTRICT_INGRESS_SOURCE is not true in $CONFIG_FILE. Set it to \"true\" first."
    UPDATED="$(new_list "${ARGS[@]}")"
    printf 'Allowed list was:  %s\n' "$CURRENT_LIST"
    printf 'Allowed list now:  %s\n' "$UPDATED"
    case " $UPDATED " in
      *" auto "*) ;;
      *)
        ME="$(public_ip)"
        if [[ -n "$ME" ]] && ! python3 -c '
import ipaddress, sys
ip = ipaddress.ip_address(sys.argv[1])
sys.exit(0 if any(ip in ipaddress.ip_network(c, strict=False) for c in sys.argv[2:]) else 1)
' "$ME" $UPDATED; then
          printf 'WARNING: this machine (%s) is not in the new list. You will lose access to the UI from here.\n' "$ME"
          printf '         kubectl and this script keep working, so you can undo it with: scripts/allowed-ips.sh add me\n'
        fi
        ;;
    esac
    if [[ "$DRY_RUN" == true ]]; then
      printf '(dry run: %s was not changed)\n' "$CONFIG_FILE"
      exit 0
    fi
    LAB_CONFIG_FILE="$CONFIG_FILE" "$SCRIPT_DIR/labvar" --config ALLOWED_SOURCE_CIDRS "$UPDATED" >/dev/null
    printf 'Saved in %s\n' "$CONFIG_FILE"
    poc access
    ;;
esac
