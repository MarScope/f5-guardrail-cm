#!/usr/bin/env bash
# Estimate what the lab deployment will cost, from the same config file that
# guardrails-poc.sh uses. Read-only: it creates and changes nothing.
#
#   scripts/cost-estimate.sh                      # 4 hours, one deployment
#   scripts/cost-estimate.sh --hours 8
#   scripts/cost-estimate.sh --students 12        # a whole class
#   scripts/cost-estimate.sh --offline            # built-in prices only
#   scripts/cost-estimate.sh --config FILE
#
# Server prices are read from the AWS Price List API when the signed-in role
# allows it (pricing:GetProducts). Otherwise, and for every other item, the
# script uses the built-in us-east-1 list prices below, recorded 2026-11-20.
# The result is an estimate of AWS infrastructure charges only.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${LAB_CONFIG_FILE:-$ROOT_DIR/config/guardrails-poc.env}"
EXAMPLE_CONFIG="$ROOT_DIR/config/guardrails-poc.env.example"
HOURS=4
STUDENTS=1
OFFLINE=false

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)   CONFIG_FILE="${2:-}"; [[ -n "$CONFIG_FILE" ]] || die "--config requires a file path"; shift 2 ;;
    --hours)    HOURS="${2:-}"; shift 2 ;;
    --students) STUDENTS="${2:-}"; shift 2 ;;
    --offline)  OFFLINE=true; shift ;;
    -h|--help)  sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$HOURS" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "--hours must be a number, for example 4 or 6.5"
[[ "$STUDENTS" =~ ^[1-9][0-9]*$ ]] || die "--students must be a whole number of 1 or more"

if [[ ! -f "$CONFIG_FILE" ]]; then
  if [[ -f "$EXAMPLE_CONFIG" ]]; then
    printf 'Config %s not found; using the example config.\n' "$CONFIG_FILE"
    CONFIG_FILE="$EXAMPLE_CONFIG"
  else
    die "Config file not found: $CONFIG_FILE"
  fi
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

# Defaults match load_config in guardrails-poc.sh. Keep the two in step.
export AWS_REGION="${AWS_REGION:-us-east-1}"
export CLUSTER_NAME="${CLUSTER_NAME:-f5-guardrails-poc}"
export GUARDRAIL_NODE_TYPE="${GUARDRAIL_NODE_TYPE:-g5.4xlarge}"
export GUARDRAIL_NODE_COUNT="${GUARDRAIL_NODE_COUNT:-1}"
export GUARDRAIL_NODE_VOLUME_SIZE="${GUARDRAIL_NODE_VOLUME_SIZE:-150}"
export ENABLE_RED_TEAM="${ENABLE_RED_TEAM:-false}"
export RED_TEAM_NODE_TYPE="${RED_TEAM_NODE_TYPE:-g6e.2xlarge}"
export RED_TEAM_NODE_COUNT="${RED_TEAM_NODE_COUNT:-1}"
export RED_TEAM_NODE_VOLUME_SIZE="${RED_TEAM_NODE_VOLUME_SIZE:-150}"
export VPC_NAT_MODE="${VPC_NAT_MODE:-Disable}"
export TUNE_NODE_VOLUMES="${TUNE_NODE_VOLUMES:-true}"
export NODE_VOLUME_IOPS="${NODE_VOLUME_IOPS:-6000}"
export NODE_VOLUME_THROUGHPUT="${NODE_VOLUME_THROUGHPUT:-500}"
export ROUTE53_ENABLED="${ROUTE53_ENABLED:-false}"
export EST_HOURS="$HOURS" EST_STUDENTS="$STUDENTS" EST_CONFIG="$CONFIG_FILE"

# Look up the Linux on-demand hourly price of one instance type. Prints the
# price, or nothing if the lookup is not possible.
live_instance_price() {
  local itype="$1" json
  [[ "$OFFLINE" == false ]] || return 0
  command -v aws >/dev/null 2>&1 || return 0
  json="$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 --max-items 1 --output json \
    --filters \
      "Type=TERM_MATCH,Field=instanceType,Value=$itype" \
      "Type=TERM_MATCH,Field=regionCode,Value=$AWS_REGION" \
      "Type=TERM_MATCH,Field=operatingSystem,Value=Linux" \
      "Type=TERM_MATCH,Field=tenancy,Value=Shared" \
      "Type=TERM_MATCH,Field=preInstalledSw,Value=NA" \
      "Type=TERM_MATCH,Field=capacitystatus,Value=Used" 2>/dev/null)" || return 0
  PRICE_JSON="$json" python3 - <<'PY' 2>/dev/null || true
import json, os
try:
    data = json.loads(os.environ["PRICE_JSON"])
    item = data["PriceList"][0]
    if isinstance(item, str):
        item = json.loads(item)
    for term in item["terms"]["OnDemand"].values():
        for dim in term["priceDimensions"].values():
            usd = float(dim["pricePerUnit"]["USD"])
            if usd > 0:
                print(usd)
                raise SystemExit
except SystemExit:
    raise
except Exception:
    pass
PY
}

export LIVE_GUARDRAIL_PRICE LIVE_RED_TEAM_PRICE=""
LIVE_GUARDRAIL_PRICE="$(live_instance_price "$GUARDRAIL_NODE_TYPE")"
if [[ "$ENABLE_RED_TEAM" == "true" ]]; then
  LIVE_RED_TEAM_PRICE="$(live_instance_price "$RED_TEAM_NODE_TYPE")"
fi

python3 - <<'PY'
import os

E = os.environ
HOURS_PER_MONTH = 730.0

# Built-in us-east-1 list prices in USD, recorded 2026-11-20.
INSTANCE_PRICES = {
    "g5.xlarge": 1.006, "g5.2xlarge": 1.212, "g5.4xlarge": 1.624, "g5.8xlarge": 2.448,
    "g6.xlarge": 0.8048, "g6.2xlarge": 0.9776, "g6.4xlarge": 1.3232,
    "g6e.xlarge": 1.861, "g6e.2xlarge": 2.2421, "g6e.4xlarge": 3.0042,
}
EKS_CLUSTER_HOUR = 0.10          # standard Kubernetes version support
NLB_HOUR = 0.0225                # plus usage, small for a lab
PUBLIC_IPV4_HOUR = 0.005
NAT_GATEWAY_HOUR = 0.045         # plus $0.045 per GB processed
GP3_GB_MONTH = 0.08
GP3_IOPS_MONTH = 0.005           # per IOPS above 3000
GP3_THROUGHPUT_MONTH = 0.04      # per MiB/s above 125
AVAILABILITY_ZONES = 2           # eksctl default for this script

region = E["AWS_REGION"]
hours = float(E["EST_HOURS"])
students = int(E["EST_STUDENTS"])
red_team = E["ENABLE_RED_TEAM"].lower() == "true"
tune = E["TUNE_NODE_VOLUMES"].lower() == "true"
iops = int(E["NODE_VOLUME_IOPS"])
throughput = int(E["NODE_VOLUME_THROUGHPUT"])

rows = []      # (item, detail, hourly cost or None)
notes = []
unknown = []


def instance_row(label, itype, count, live):
    if live:
        price, source = float(live), "live price"
    elif itype in INSTANCE_PRICES:
        price, source = INSTANCE_PRICES[itype], "built-in price"
        if region != "us-east-1":
            source = "built-in us-east-1 price"
    else:
        unknown.append(itype)
        rows.append((label, f"{count} x {itype}, price not known", None))
        return
    rows.append((label, f"{count} x {itype} at ${price:.4f}/h ({source})", count * price))


def disk_row(label, count, size_gb):
    monthly = size_gb * GP3_GB_MONTH
    detail = f"{count} x {size_gb} GB gp3"
    if tune:
        monthly += max(iops - 3000, 0) * GP3_IOPS_MONTH
        monthly += max(throughput - 125, 0) * GP3_THROUGHPUT_MONTH
        detail += f", {iops} IOPS, {throughput} MiB/s"
    rows.append((label, detail, count * monthly / HOURS_PER_MONTH))


g_count = int(E["GUARDRAIL_NODE_COUNT"])
r_count = int(E["RED_TEAM_NODE_COUNT"]) if red_team else 0

rows.append(("EKS control plane", "1 cluster, standard version support", EKS_CLUSTER_HOUR))
instance_row("Guardrails GPU node", E["GUARDRAIL_NODE_TYPE"], g_count, E.get("LIVE_GUARDRAIL_PRICE", ""))
if red_team:
    instance_row("Red Team GPU node", E["RED_TEAM_NODE_TYPE"], r_count, E.get("LIVE_RED_TEAM_PRICE", ""))
disk_row("Guardrails node disk", g_count, int(E["GUARDRAIL_NODE_VOLUME_SIZE"]))
if red_team:
    disk_row("Red Team node disk", r_count, int(E["RED_TEAM_NODE_VOLUME_SIZE"]))
rows.append(("Network Load Balancer", "1 load balancer, hourly charge only", NLB_HOUR))

nat_mode = E["VPC_NAT_MODE"].lower()
nat_gateways = {"disable": 0, "single": 1, "highlyavailable": AVAILABILITY_ZONES}.get(nat_mode, 0)
if nat_gateways:
    rows.append(("NAT gateway", f"{nat_gateways} gateway(s), hourly charge only", nat_gateways * NAT_GATEWAY_HOUR))

ipv4 = g_count + r_count + AVAILABILITY_ZONES + nat_gateways
rows.append(("Public IPv4 addresses", f"{ipv4} addresses (nodes, load balancer"
             + (", NAT" if nat_gateways else "") + ")", ipv4 * PUBLIC_IPV4_HOUR))

hourly = sum(r[2] for r in rows if r[2] is not None)


def money(value):
    return f"${value:,.2f}"


print()
print("Cost estimate for the F5 AI Security lab deployment")
print("===================================================")
print(f"Config file:   {E['EST_CONFIG']}")
print(f"Cluster:       {E['CLUSTER_NAME']} ({region})")
print(f"Red Team:      {'enabled' if red_team else 'disabled'}")
print()
width = max(len(r[0]) for r in rows)
for item, detail, cost in rows:
    cost_text = f"${cost:8.4f}/h" if cost is not None else "   unknown  "
    print(f"  {item:<{width}}  {cost_text}  {detail}")
print()
print(f"  Per hour, one deployment:        {money(hourly)}")
print(f"  For {hours:g} hours, one deployment:   {money(hourly * hours)}")
if students > 1:
    print(f"  For {hours:g} hours, {students} deployments:  {money(hourly * hours * students)}")
print(f"  If left running for 24 hours:    {money(hourly * 24)}" + (f"  ({money(hourly * 24 * students)} for {students})" if students > 1 else ""))
print(f"  If left running for 30 days:     {money(hourly * 24 * 30)}" + (f"  ({money(hourly * 24 * 30 * students)} for {students})" if students > 1 else ""))
print()
print("Not included:")
print("  - Amazon Bedrock model usage, billed per token. Small for the lab's test prompts.")
print("  - The platform's own persistent disks (database and similar), a few GB.")
print("  - Data transfer and load balancer usage charges, small for a lab.")
if E["ROUTE53_ENABLED"].lower() == "true":
    print("  - The Route 53 hosted zone ($0.50 per month) and DNS queries.")
print("  - F5 licensing.")
print("  - Taxes, support plans, and any discounts or credits on the account.")
print()
if unknown:
    print("WARNING: no price was found for " + ", ".join(sorted(set(unknown))) + ".")
    print("         The totals above leave it out. Look it up at https://aws.amazon.com/ec2/pricing/on-demand/")
    print()
if region != "us-east-1":
    print(f"NOTE: built-in prices are for us-east-1. Prices in {region} can differ by a few percent.")
    print()
print("Charges run from the moment `up` starts creating the cluster until `down` finishes.")
print("Tear down with: ./scripts/guardrails-poc.sh down --yes")
print()
PY
