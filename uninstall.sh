#!/usr/bin/env bash
# Removes what install.sh installed. kgateway and the Gateway API CRDs are removed
# only when install.sh installed them; --keep-crds leaves all CRDs in place.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 [flags]

  --context NAME   kubeconfig context (default: the current context)
  --keep-crds      keep the Gateway API and kgateway CRDs
  --yes            do not ask for confirmation
EOF
}

CONTEXT=${KUBE_CONTEXT:-}
KEEP_CRDS=false
YES=false
while (($#)); do
  case $1 in
    --context) CONTEXT=$2; shift 2 ;;
    --keep-crds) KEEP_CRDS=true; shift ;;
    --yes | -y) YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown flag: $1" ;;
  esac
done
need kubectl helm jq
[[ -n $CONTEXT ]] || CONTEXT=$(kubectl config current-context 2>/dev/null) || die "no current context; pass --context"
K cluster-info >/dev/null 2>&1 || die "cannot reach the cluster of context $CONTEXT"

if ! $YES; then
  [[ -t 0 ]] || die "not a terminal; pass --yes to uninstall without confirmation"
  read -r -p "Remove the Snellius demo from context $CONTEXT? [y/N] " answer
  [[ $answer == [yY]* ]] || die "cancelled"
fi

STATE_NS=default
STATE_CM=snellius-demo-state
state() { K -n "$STATE_NS" get configmap "$STATE_CM" -o jsonpath="{.data.$1}" 2>/dev/null || true; }
gwapi=$(state gatewayAPI)
kgw=$(state kgateway)
secure=false
K get namespace keycloak >/dev/null 2>&1 && secure=true

log "Removing Snellius"
H -n snellius uninstall ui --wait >/dev/null 2>&1 || true
K delete namespace snellius --ignore-not-found --wait=false >/dev/null

log "Removing Keycloak, RBAC and the use cases"
K delete -f "$REPO_ROOT/manifests/rbac.yaml" --ignore-not-found >/dev/null
K delete namespace keycloak --ignore-not-found --wait=false >/dev/null
# Gateways go first, while kgateway still runs to clean up their proxies.
K delete -f "$REPO_ROOT/manifests/use-cases.yaml" --ignore-not-found --wait=true >/dev/null 2>&1 || true

if [[ $kgw == installed ]]; then
  log "Removing kgateway"
  H -n kgateway-system uninstall kgateway --wait >/dev/null 2>&1 || true
  if ! $KEEP_CRDS; then
    H -n kgateway-system uninstall kgateway-crds --wait >/dev/null 2>&1 || true
  fi
  K delete namespace kgateway-system --ignore-not-found >/dev/null
elif [[ $kgw == preexisting ]]; then
  log "kgateway was there before the demo; leaving it"
fi

if [[ $gwapi == installed ]] && ! $KEEP_CRDS; then
  log "Removing the Gateway API CRDs"
  K get crd -o name | { grep -E '\.gateway\.networking\.(x-)?k8s\.io$' || true; } |
    while read -r crd; do K delete "$crd" >/dev/null; done
fi

K -n "$STATE_NS" delete configmap "$STATE_CM" --ignore-not-found >/dev/null
K wait --for=delete namespace/snellius namespace/keycloak --timeout=180s >/dev/null 2>&1 || true

echo "Done."
if $secure; then
  cat <<EOF
The API server still trusts the demo's issuer; this script does not change it.
See docs/api-server-oidc.md to remove its authentication config, or delete the cluster.
The demo CA stays in $PKI_DIR; delete that folder to forget it.
EOF
fi
