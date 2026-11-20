# Helper commands for the AI Security - EKS lab guide.
# This file is loaded by ~/f5-ai-lab/lab.env. Do not run it directly.
# Because it lives in the repository, "git pull" keeps these commands current.
#
#   labvar NAME VALUE    save a value in lab.env and reload it
#   labvar NAME          same, but paste the value unseen (use for secrets)
#   labcfg NAME VALUE    save a setting in f5-guardrail-cm/config/guardrails-poc.env
#   labsecrets           store the Harbor login and F5 license for the deployment script
#   labrefresh           rebuild lab.env from the latest example, keeping your values

_lab_env="${LAB_ENV_FILE:-$HOME/f5-ai-lab/lab.env}"
_lab_helper="$HOME/f5-ai-lab/f5-guardrail-cm/scripts/labvar"

labvar() { "$_lab_helper" "$@" && source "$_lab_env"; }
labcfg() { "$_lab_helper" --config "$@"; }
labsecrets() { "$_lab_helper" --f5-secrets; }
labrefresh() { "$_lab_helper" --refresh-env && source "$_lab_env"; }
