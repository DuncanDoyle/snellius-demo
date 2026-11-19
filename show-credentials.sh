#!/usr/bin/env bash
# Prints the demo users' passwords and Keycloak's admin password.
# They are generated at install time and kept only in the cluster.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

CONTEXT=${KUBE_CONTEXT:-}
while (($#)); do
  case $1 in
    --context) CONTEXT=$2; shift 2 ;;
    -h | --help) echo "Usage: $0 [--context NAME]"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
done
need kubectl jq
[[ -n $CONTEXT ]] || CONTEXT=$(kubectl config current-context)

creds=$(K -n keycloak get secret keycloak-credentials -o json 2>/dev/null) ||
  die "no Keycloak credentials in context $CONTEXT; was install.sh run with --secure?"
field() { jq -r --arg k "$1" '.data[$k] | @base64d' <<<"$creds"; }
host=$(K -n keycloak get configmap keycloak-settings -o jsonpath='{.data.hostname}')
UI_PORT=$(K -n keycloak get configmap keycloak-settings -o jsonpath='{.data.ui-port}')

cat <<EOF
Snellius users (sign in at http://localhost:$UI_PORT):
  alice  $(field alice-password)   full read, cluster-wide
  bob    $(field bob-password)   read in team-a and team-b only

Keycloak admin console: $host/admin/
  admin  $(field admin-password)
EOF
