#!/usr/bin/env bash
# Installs kgateway, Snellius and the demo use cases into an existing cluster.
# With --secure it adds Keycloak and runs Snellius in secure mode. Safe to run again.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/lib/common.sh"

usage() {
  cat <<EOF
Usage: $0 [flags]

  --context NAME            kubeconfig context to install into (default: the current context)
  --secure                  add Keycloak and run Snellius in secure mode
  --issuer-host HOST        host name or IP of Keycloak's issuer URL (default: $DEFAULT_ISSUER_HOST)
  --kgateway-version VER    kgateway release, e.g. v2.5.2 (default: the latest release)
  --gateway-api-version VER Gateway API release (default: the one that kgateway release is built on)
  --snellius-version VER    Snellius chart version, e.g. 0.8.0 (default: the latest release)
  --ui-port PORT            local port of the Snellius port-forward (default: 8080)
  --yes                     do not ask for confirmation
  -h, --help                show this help

Environment variables KGATEWAY_VERSION, GATEWAY_API_VERSION, SNELLIUS_VERSION,
ISSUER_HOST and UI_PORT set the same defaults. Secure mode needs an API server that trusts
Keycloak first: see docs/api-server-oidc.md.
EOF
}

CONTEXT=${KUBE_CONTEXT:-}
SECURE=false
YES=false
ISSUER_HOST=${ISSUER_HOST:-$DEFAULT_ISSUER_HOST}
KGW_VERSION=${KGATEWAY_VERSION:-}
GWAPI_VERSION=${GATEWAY_API_VERSION:-}
SNELLIUS_VERSION=${SNELLIUS_VERSION:-}

while (($#)); do
  case $1 in
    --context) CONTEXT=$2; shift 2 ;;
    --secure) SECURE=true; shift ;;
    --issuer-host) ISSUER_HOST=$2; shift 2 ;;
    --kgateway-version) KGW_VERSION=$2; shift 2 ;;
    --gateway-api-version) GWAPI_VERSION=$2; shift 2 ;;
    --snellius-version) SNELLIUS_VERSION=$2; shift 2 ;;
    --ui-port) UI_PORT=$2; shift 2 ;;
    --yes | -y) YES=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) usage >&2; die "unknown flag: $1" ;;
  esac
done

need kubectl helm openssl curl jq

TMP=$(mktemp -d)
chmod 700 "$TMP"
trap 'rm -rf "$TMP"' EXIT

# github_get fetches a GitHub API path. GITHUB_TOKEN, when set, only raises the rate limit.
github_get() {
  local auth=()
  [[ -n ${GITHUB_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
  curl -fsSL ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

# ---------- Context and versions ----------
if [[ -z $CONTEXT ]]; then
  CONTEXT=$(kubectl config current-context 2>/dev/null) || die "no current context; pass --context"
fi
K cluster-info >/dev/null 2>&1 || die "cannot reach the cluster of context $CONTEXT"

if [[ -z $KGW_VERSION ]]; then
  KGW_VERSION=$(github_get repos/kgateway-dev/kgateway/releases/latest | jq -r .tag_name)
fi
[[ $KGW_VERSION == v* ]] || KGW_VERSION=v$KGW_VERSION
if [[ -z $GWAPI_VERSION ]]; then
  # The Gateway API version kgateway's release is built against, from its go.mod.
  # Read go.mod whole first: awk exits early, which would fail curl under pipefail.
  gomod=$(curl -fsSL "https://raw.githubusercontent.com/kgateway-dev/kgateway/$KGW_VERSION/go.mod")
  GWAPI_VERSION=$(awk '$1 == "sigs.k8s.io/gateway-api" { print $2; exit }' <<<"$gomod")
  [[ -n $GWAPI_VERSION ]] || die "could not find the Gateway API version of kgateway $KGW_VERSION; pass --gateway-api-version"
fi
if [[ -z $SNELLIUS_VERSION ]]; then
  SNELLIUS_VERSION=$(github_get repos/DuncanDoyle/snellius/releases/latest | jq -r .tag_name)
fi
SNELLIUS_VERSION=${SNELLIUS_VERSION#v}

MODE=local
$SECURE && MODE=secure
cat <<EOF
Context:      $CONTEXT
kgateway:     $KGW_VERSION (Gateway API $GWAPI_VERSION, standard channel)
Snellius:     $SNELLIUS_VERSION, $MODE mode
EOF
$SECURE && echo "Issuer:       $(issuer_url "$ISSUER_HOST")"
if ! $YES; then
  [[ -t 0 ]] || die "not a terminal; pass --yes to install without confirmation"
  read -r -p "Install into context $CONTEXT? [y/N] " answer
  [[ $answer == [yY]* ]] || die "cancelled"
fi

# ---------- What the cluster had before the first run ----------
# Kept in a ConfigMap so uninstall.sh removes only what this demo installed.
STATE_NS=default
STATE_CM=snellius-demo-state
if ! K -n "$STATE_NS" get configmap "$STATE_CM" >/dev/null 2>&1; then
  gwapi=installed kgw=installed
  K get crd gateways.gateway.networking.k8s.io >/dev/null 2>&1 && gwapi=preexisting
  H -n kgateway-system status kgateway >/dev/null 2>&1 && kgw=preexisting
  K -n "$STATE_NS" create configmap "$STATE_CM" --from-literal=gatewayAPI="$gwapi" --from-literal=kgateway="$kgw" >/dev/null
fi
state() { K -n "$STATE_NS" get configmap "$STATE_CM" -o jsonpath="{.data.$1}"; }

# ---------- 1. Gateway API CRDs ----------
if [[ $(state gatewayAPI) == preexisting ]]; then
  have=$(K get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}')
  log "Gateway API CRDs were already installed ($have); leaving them as they are"
  [[ $have == "$GWAPI_VERSION" ]] || warn "kgateway $KGW_VERSION expects Gateway API $GWAPI_VERSION"
else
  log "Installing Gateway API $GWAPI_VERSION CRDs"
  K apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GWAPI_VERSION/standard-install.yaml" >/dev/null
fi

# ---------- 2. kgateway ----------
if [[ $(state kgateway) == preexisting ]]; then
  log "kgateway was already installed in kgateway-system; leaving it as it is"
else
  log "Installing kgateway $KGW_VERSION"
  H upgrade -i kgateway-crds oci://cr.kgateway.dev/kgateway-dev/charts/kgateway-crds \
    --create-namespace --namespace kgateway-system --version "$KGW_VERSION" --wait >/dev/null
  H upgrade -i kgateway oci://cr.kgateway.dev/kgateway-dev/charts/kgateway \
    --namespace kgateway-system --version "$KGW_VERSION" --wait --timeout 5m >/dev/null
fi
K wait --for=condition=Accepted gatewayclass/kgateway --timeout=120s >/dev/null

# ---------- 3. The use cases ----------
log "Applying the use cases (namespaces infra, team-a, team-b, team-c)"
K apply -f "$REPO_ROOT/manifests/use-cases.yaml" >/dev/null

# ---------- 4. Keycloak and RBAC (secure mode) ----------
snellius_args=(-f "$REPO_ROOT/values/local.yaml")
if $SECURE; then
  ISSUER=$(issuer_url "$ISSUER_HOST")
  ensure_ca
  ensure_keycloak_cert "$ISSUER_HOST"

  log "Installing Keycloak"
  K create namespace keycloak --dry-run=client -o yaml | K apply -f - >/dev/null
  K label namespace keycloak app.kubernetes.io/part-of=snellius-demo --overwrite >/dev/null
  if ! K -n keycloak get secret keycloak-credentials >/dev/null 2>&1; then
    # Generated once; passwords stay in the cluster. ./show-credentials.sh prints them.
    for key in admin-password alice-password bob-password client-secret; do
      openssl rand -hex 12 | tr -d '\n' >"$TMP/$key"
    done
    K -n keycloak create secret generic keycloak-credentials \
      --from-file="$TMP/admin-password" --from-file="$TMP/alice-password" \
      --from-file="$TMP/bob-password" --from-file="$TMP/client-secret" >/dev/null
    rm -f "$TMP"/*-password "$TMP/client-secret"
  fi
  settings() { K -n keycloak get configmap keycloak-settings -o jsonpath='{.data}' 2>/dev/null || true; }
  old_settings=$(settings)
  old_cert=$(K -n keycloak get secret keycloak-tls -o jsonpath='{.data.tls\.crt}' 2>/dev/null || true)
  K -n keycloak create configmap keycloak-settings --from-literal=hostname="https://$ISSUER_HOST:$KEYCLOAK_PORT" \
    --from-literal=ui-port="$UI_PORT" --dry-run=client -o yaml | K apply -f - >/dev/null
  K -n keycloak create secret tls keycloak-tls --cert="$PKI_DIR/keycloak.crt" --key="$PKI_DIR/keycloak.key" \
    --dry-run=client -o yaml | K apply -f - >/dev/null
  new_cert=$(K -n keycloak get secret keycloak-tls -o jsonpath='{.data.tls\.crt}')
  realm() { K -n keycloak get configmap keycloak-realm -o jsonpath='{.data.snellius-realm\.json}' 2>/dev/null || true; }
  old_realm=$(realm)
  K apply -f "$REPO_ROOT/manifests/keycloak/keycloak.yaml" >/dev/null
  # Keycloak reads these only at start, so restart it when one changed.
  restart=false
  [[ -n $old_realm ]] &&
    [[ $old_settings != "$(settings)" || $old_cert != "$new_cert" || $old_realm != "$(realm)" ]] &&
    restart=true
  $restart && K -n keycloak rollout restart deployment/keycloak >/dev/null
  K -n keycloak rollout status deployment/keycloak --timeout=300s >/dev/null

  log "Applying RBAC for alice and bob"
  K apply -f "$REPO_ROOT/manifests/rbac.yaml" >/dev/null

  # The API server config for this issuer, for platforms where you add it yourself.
  minor=$(server_minor)
  api=v1
  ((minor < 34)) && api=v1beta1
  render_auth_config "$ISSUER" "$api" >"$STATE_DIR/authentication-config.yaml"

  # Snellius's client secret and the demo CA.
  K create namespace snellius --dry-run=client -o yaml | K apply -f - >/dev/null
  K -n keycloak get secret keycloak-credentials -o jsonpath='{.data.client-secret}' | base64 -d >"$TMP/client-secret"
  K -n snellius create secret generic snellius-oidc --from-file="$TMP/client-secret" \
    --dry-run=client -o yaml | K apply -f - >/dev/null
  rm -f "$TMP/client-secret"
  K -n snellius create configmap snellius-oidc-ca --from-file=ca.pem="$PKI_DIR/ca.pem" \
    --dry-run=client -o yaml | K apply -f - >/dev/null

  snellius_args=(-f "$REPO_ROOT/values/secure.yaml" --set "auth.oidc.issuerURL=$ISSUER"
    --set "auth.oidc.redirectURL=http://localhost:$UI_PORT/auth/callback")
  if ! is_ip "$ISSUER_HOST"; then
    # Inside the pod the issuer host name points at Keycloak's Service.
    kc_ip=$(K -n keycloak get service keycloak -o jsonpath='{.spec.clusterIP}')
    snellius_args+=(--set-json "hostAliases=[{\"ip\":\"$kc_ip\",\"hostnames\":[\"$ISSUER_HOST\"]}]")
  fi
fi

# ---------- 5. Snellius ----------
log "Installing Snellius $SNELLIUS_VERSION in $MODE mode"
H upgrade -i ui oci://ghcr.io/duncandoyle/charts/snellius --version "$SNELLIUS_VERSION" \
  --namespace snellius --create-namespace "${snellius_args[@]}" --wait --timeout 5m >/dev/null

log "Waiting for the demo Gateways"
K -n infra wait --for=condition=Programmed gateway/shared --timeout=180s >/dev/null ||
  warn "Gateway infra/shared is not programmed yet"
K -n team-a wait --for=condition=Programmed gateway/team-a --timeout=180s >/dev/null ||
  warn "Gateway team-a/team-a is not programmed yet"

# ---------- 6. Does the API server trust Keycloak? ----------
trusted=unknown
if $SECURE; then
  log "Checking that the API server accepts Keycloak's tokens"
  K -n keycloak get secret keycloak-credentials -o jsonpath='{.data.alice-password}' | base64 -d >"$TMP/password"
  K -n keycloak get secret keycloak-credentials -o jsonpath='{.data.client-secret}' | base64 -d >"$TMP/client-secret"
  trusted=no
  for _ in $(seq 1 12); do
    # Tokens stay in variables and on stdin; nothing here prints them.
    token=$(curl -fsS --max-time 10 --cacert "$PKI_DIR/ca.pem" "$ISSUER/protocol/openid-connect/token" \
      -d grant_type=password -d client_id="$CLIENT_ID" -d username=alice -d scope=openid \
      --data-urlencode "password@$TMP/password" --data-urlencode "client_secret@$TMP/client-secret" 2>/dev/null |
      jq -r '.id_token // empty') || token=""
    if [[ -z $token ]]; then
      trusted=unreachable
      sleep 5
      continue
    fi
    user=$(TOKEN=$token jq -n '{apiVersion: "authentication.k8s.io/v1", kind: "TokenReview", spec: {token: env.TOKEN}}' |
      K create -f - -o json | jq -r 'select(.status.authenticated == true) | .status.user.username') || user=""
    if [[ $user == "oidc:alice" ]]; then
      trusted=yes
      break
    fi
    trusted=no
    sleep 5
  done
  rm -f "$TMP/password" "$TMP/client-secret"
  unset token
  case $trusted in
    yes) echo "The API server accepts Keycloak's tokens: alice is oidc:alice." ;;
    unreachable) warn "could not reach $ISSUER from this machine, so the API server check was skipped. Your browser needs to reach it too." ;;
    *) warn "the API server does not accept Keycloak's tokens yet. Give it $STATE_DIR/authentication-config.yaml: see docs/api-server-oidc.md." ;;
  esac
fi

# ---------- Next steps ----------
cat <<EOF

Done. Open Snellius:

  kubectl --context $CONTEXT -n snellius port-forward svc/ui-snellius $UI_PORT:80

Then browse to http://localhost:$UI_PORT
EOF
if $SECURE; then
  cat <<EOF

Snellius sends you to Keycloak at $(issuer_url "$ISSUER_HOST").
Sign in as alice (sees everything) or bob (team-a and team-b only).
Print their passwords with: ./show-credentials.sh --context $CONTEXT
Your browser warns about Keycloak's certificate, which the demo CA issued.
Accept it, or trust $PKI_DIR/ca.pem.
EOF
fi
