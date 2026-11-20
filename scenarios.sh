#!/usr/bin/env bash
# Deploys and removes the walkthrough scenarios in scenarios/. See scenarios/README.md.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

SCENARIO_DIR=$REPO_ROOT/scenarios

usage() {
  cat <<EOF
Usage: $0 [--context NAME] <command>

  up [NN...|all]     deploy scenarios; all skips 22, which you deploy on its own
  down [NN...|all]   delete the namespaces of scenarios, by their scenario label
  list               list the scenarios

  --context NAME     kubeconfig context (default: the current context)
EOF
}

CONTEXT=${KUBE_CONTEXT:-}
args=()
while (($#)); do
  case $1 in
    --context) CONTEXT=$2; shift 2 ;;
    -h | --help) usage; exit 0 ;;
    -*) usage >&2; die "unknown flag: $1" ;;
    *) args+=("$1"); shift ;;
  esac
done
((${#args[@]} > 0)) || { usage >&2; exit 1; }
cmd=${args[0]}
ids=()
for a in "${args[@]:1}"; do
  # Accept 1 as well as 01.
  if [[ $a =~ ^[0-9]+$ ]]; then ids+=("$(printf '%02d' $((10#$a)))"); else ids+=("$a"); fi
done

# file_of prints the file of scenario $1, such as scenarios/11-missing-service.yaml.
file_of() {
  local f
  for f in "$SCENARIO_DIR/$1"-*.yaml; do
    [[ -f $f ]] && { echo "$f"; return 0; }
  done
  die "no scenario $1; run '$0 list'"
}

all_ids() {
  local f
  for f in "$SCENARIO_DIR"/[0-9][0-9]-*.yaml; do
    basename "$f" | cut -c1-2
  done
}

# title prints the first comment line of a scenario file, without the leading "# NN ".
title() { head -n1 "$1" | sed -E 's/^# [0-9]+ //'; }

list() {
  local id
  for id in $(all_ids); do
    printf '%s  %s\n' "$id" "$(title "$(file_of "$id")")"
  done
}

# Scenarios that need a self-signed TLS Secret: id, namespace, Secret name, host.
TLS_SECRETS=(
  "01 uc-01-storefront storefront-tls *.store.example"
  "10 uc-10-l4 secure-tls tls.l4.example"
)

# ensure_tls creates the TLS Secrets of scenario $1. The key never leaves the cluster and a temp folder.
ensure_tls() {
  local entry id ns name host tmp
  for entry in "${TLS_SECRETS[@]}"; do
    read -r id ns name host <<<"$entry"
    [[ $id == "$1" ]] || continue
    K get namespace "$ns" >/dev/null 2>&1 || K create namespace "$ns" --save-config >/dev/null
    K label namespace "$ns" app.kubernetes.io/part-of=snellius-demo scenario="$id" --overwrite >/dev/null
    K -n "$ns" get secret "$name" >/dev/null 2>&1 && continue
    tmp=$(mktemp -d)
    openssl req -x509 -newkey rsa:2048 -nodes -days 365 -subj "/CN=$host" -addext "subjectAltName=DNS:$host" \
      -keyout "$tmp/tls.key" -out "$tmp/tls.crt" 2>/dev/null
    K -n "$ns" create secret tls "$name" --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
    rm -rf "$tmp"
  done
}

# watches_selected_namespaces is true when a kgateway controller in the cluster sets discoveryNamespaceSelectors.
watches_selected_namespaces() {
  K get deployments -A -o json | jq -e '[.items[].spec.template.spec.containers[].env[]?
    | select(.name == "KGW_DISCOVERY_NAMESPACE_SELECTORS" and (.value // "[]") != "[]" and .value != "")] | length > 0' >/dev/null
}

up_one() {
  local id=$1 file
  file=$(file_of "$id")
  if [[ $id == 17 ]] && ! watches_selected_namespaces; then
    warn "skipping 17: kgateway watches every namespace. Scenario 17 needs discoveryNamespaceSelectors (see scenarios/README.md)."
    return 0
  fi
  # 20 builds on 19's Gateway.
  [[ $id == 20 ]] && ! K get namespace uc-19-infra >/dev/null 2>&1 && up_one 19
  ensure_tls "$id"
  log "Scenario $id: $(title "$file")"
  # A proxy that starts with rejected config never gets ready, so such objects wait for ready proxies.
  if grep -q "$LATER" "$file"; then
    K apply -f "$file" -l "${LATER%%:*}!=after-proxy-ready" >/dev/null
    wait_for_proxies "$id"
  fi
  K apply -f "$file" >/dev/null
}

LATER="snellius-demo/apply: after-proxy-ready"

# wait_for_proxies waits until the Gateway proxies in the namespaces of scenario $1 are available.
wait_for_proxies() {
  local ns sel=gateway.networking.k8s.io/gateway-name
  for ns in $(K get namespaces -l scenario="$1" -o jsonpath='{.items[*].metadata.name}'); do
    K get gateways -n "$ns" -o name | grep -q . || continue
    for _ in $(seq 1 60); do
      K -n "$ns" get deployments -l "$sel" -o name | grep -q . && break
      sleep 2
    done
    K -n "$ns" wait --for=condition=Available deployments -l "$sel" --timeout=180s >/dev/null ||
      warn "the proxies in $ns are not ready; applying the rest anyway"
  done
}

up() {
  local id
  if [[ ${ids[*]-} == all ]]; then
    ids=()
    for id in $(all_ids); do [[ $id == 22 ]] || ids+=("$id"); done
    echo "Deploying every scenario except 22, which affects every Gateway. Deploy it on its own with: $0 up 22"
  fi
  ((${#ids[@]} > 0)) || die "name the scenarios to deploy, such as: $0 up 01 11, or: $0 up all"
  for id in "${ids[@]}"; do
    if [[ $id == 22 ]] && K get namespaces -l scenario -o name | grep -v uc-22- | grep -q .; then
      warn "scenario 22 makes every proxy of the install reject a cluster, including the other scenarios' Gateways"
    fi
    up_one "$id"
  done
  echo "Done. Findings show in Snellius within a minute; some, such as 16's, take 30 s more."
}

down() {
  local id selector
  ((${#ids[@]} > 0)) || die "name the scenarios to delete, such as: $0 down 11, or: $0 down all"
  if [[ ${ids[*]} == all ]]; then
    selector=scenario
  else
    for id in "${ids[@]}"; do file_of "$id" >/dev/null; done
    selector="scenario in ($(IFS=,; echo "${ids[*]}"))"
  fi
  log "Deleting the namespaces with label $selector"
  K delete namespace -l "$selector" --wait=true
}

need kubectl jq openssl
[[ -n $CONTEXT ]] || CONTEXT=$(kubectl config current-context 2>/dev/null) || die "no current context; pass --context"
case $cmd in
  list) list ;;
  up) K cluster-info >/dev/null 2>&1 || die "cannot reach the cluster of context $CONTEXT"; up ;;
  down) down ;;
  *) usage >&2; die "unknown command: $cmd" ;;
esac
