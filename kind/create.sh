#!/usr/bin/env bash
# Creates a kind cluster that is ready for ./install.sh --secure.
# Running it again on an existing cluster refreshes the node's host entry.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 [flags]

  --name NAME          kind cluster name (default: snellius-demo)
  --issuer-host HOST   Keycloak's issuer host (default: $DEFAULT_ISSUER_HOST)
  --image IMAGE        kind node image; Kubernetes 1.34 or later (default: kind's own)
  --kubeconfig FILE    kubeconfig file kind writes the context to (default: kind's default)
EOF
}

NAME=snellius-demo
ISSUER_HOST=${ISSUER_HOST:-$DEFAULT_ISSUER_HOST}
IMAGE=""
KUBECONFIG_FILE=""
while (($#)); do
  case $1 in
    --name) NAME=$2; shift 2 ;;
    --issuer-host) ISSUER_HOST=$2; shift 2 ;;
    --image) IMAGE=$2; shift 2 ;;
    --kubeconfig) KUBECONFIG_FILE=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown flag: $1" ;;
  esac
done
need kind docker openssl

ensure_ca
mkdir -p "$STATE_DIR/kind"
render_auth_config "$(issuer_url "$ISSUER_HOST")" v1 >"$STATE_DIR/kind/authentication-config.yaml"

kind_args=(--name "$NAME")
[[ -n $KUBECONFIG_FILE ]] && kind_args+=(--kubeconfig "$KUBECONFIG_FILE")
if kind get clusters 2>/dev/null | grep -qx "$NAME"; then
  log "kind cluster $NAME exists"
else
  log "Creating kind cluster $NAME"
  create_args=("${kind_args[@]}" --config kind/cluster-secure.yaml --wait 120s)
  [[ -n $IMAGE ]] && create_args+=(--image "$IMAGE")
  # The config's hostPath is relative to the repository root.
  (cd "$REPO_ROOT" && kind create cluster "${create_args[@]}")
fi

# Inside the node, the issuer host is the node itself, where Keycloak's NodePort listens.
# Docker rewrites /etc/hosts when the node restarts, so run this script again after a restart.
if ! is_ip "$ISSUER_HOST"; then
  node=$NAME-control-plane
  node_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$node" | awk '{print $1}')
  [[ -n $node_ip ]] || die "no IP for node $node"
  # The API server pod keeps its own copy of /etc/hosts from when it started, so
  # set the entry in both. Rewrite in place: both files are bind mounts.
  # shellcheck disable=SC2016 # expanded by the node's shell
  docker exec "$node" sh -c '
    ip=$1 host=$2
    set_entry() { grep -v " $host\$" "$1" >/tmp/hosts.snellius; echo "$ip $host" >>/tmp/hosts.snellius; cat /tmp/hosts.snellius >"$1"; }
    set_entry /etc/hosts
    id=$(crictl ps --name kube-apiserver -q | head -n1)
    pod_hosts=$(crictl inspect "$id" | grep -o "/var/lib/kubelet/pods/[^\"]*/etc-hosts" | head -n1)
    [ -n "$pod_hosts" ] && set_entry "$pod_hosts"
    rm -f /tmp/hosts.snellius' sh "$node_ip" "$ISSUER_HOST"
  log "Node $node and its API server resolve $ISSUER_HOST to $node_ip"
fi

kc=""
[[ -n $KUBECONFIG_FILE ]] && kc="KUBECONFIG=$KUBECONFIG_FILE "
cat <<EOF

The cluster is ready for secure mode. Next:

  ${kc}./install.sh --context kind-$NAME --secure --issuer-host $ISSUER_HOST
EOF
