# shellcheck shell=bash disable=SC2034
# Shared helpers for install.sh, uninstall.sh, show-credentials.sh and kind/create.sh.

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Local state: the demo CA and the API server config. Never committed (.gitignore).
STATE_DIR=${SNELLIUS_DEMO_STATE_DIR:-$REPO_ROOT/.demo}
PKI_DIR=$STATE_DIR/pki

# Keycloak listens on this port as a NodePort and as its Service port, so the
# issuer URL is the same from the browser, the API server and the Snellius pod.
KEYCLOAK_PORT=30443
REALM=snellius
CLIENT_ID=snellius
UI_PORT=${UI_PORT:-8080}
DEFAULT_ISSUER_HOST=keycloak.localhost

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf 'warning: %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
  local missing=()
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
  ((${#missing[@]} == 0)) || die "missing tools: ${missing[*]}"
}

# K and H always name the context; the current context is never switched.
K() { kubectl --context "$CONTEXT" "$@"; }
H() { helm --kube-context "$CONTEXT" "$@"; }

is_ip() { [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

issuer_url() { printf 'https://%s:%s/realms/%s' "$1" "$KEYCLOAK_PORT" "$REALM"; }

# ensure_ca creates the demo CA once and keeps it.
ensure_ca() {
  mkdir -p "$PKI_DIR"
  chmod 700 "$STATE_DIR" "$PKI_DIR"
  [[ -f $PKI_DIR/ca.pem && -f $PKI_DIR/ca.key ]] && return 0
  log "Creating the demo CA in $PKI_DIR"
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 -subj "/CN=Snellius Demo CA" \
    -keyout "$PKI_DIR/ca.key" -out "$PKI_DIR/ca.pem" \
    -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "subjectKeyIdentifier=hash" -addext "authorityKeyIdentifier=keyid:always" 2>/dev/null
  chmod 600 "$PKI_DIR/ca.key"
}

# ensure_keycloak_cert issues Keycloak's serving certificate for host $1.
# It is reissued only when the host changes.
ensure_keycloak_cert() {
  local host=$1 san
  if [[ -f $PKI_DIR/keycloak.crt && "$(cat "$PKI_DIR/keycloak.host" 2>/dev/null)" == "$host" ]]; then
    return 0
  fi
  if is_ip "$host"; then san="IP:$host"; else san="DNS:$host"; fi
  san="$san,DNS:keycloak.keycloak.svc,DNS:keycloak.keycloak.svc.cluster.local"
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$host" \
    -keyout "$PKI_DIR/keycloak.key" -out "$PKI_DIR/keycloak.csr" 2>/dev/null
  printf 'subjectAltName=%s\nbasicConstraints=CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' \
    "$san" >"$PKI_DIR/keycloak.ext"
  openssl x509 -req -in "$PKI_DIR/keycloak.csr" -CA "$PKI_DIR/ca.pem" -CAkey "$PKI_DIR/ca.key" \
    -CAcreateserial -days 825 -extfile "$PKI_DIR/keycloak.ext" -out "$PKI_DIR/keycloak.crt" 2>/dev/null
  chmod 600 "$PKI_DIR/keycloak.key"
  printf '%s' "$host" >"$PKI_DIR/keycloak.host"
}

# render_auth_config prints the API server's structured authentication config
# for issuer URL $1, with the demo CA inline. $2 is the API version (v1 or v1beta1).
render_auth_config() {
  local issuer=$1 version=${2:-v1}
  cat <<EOF
# Structured authentication configuration: the API server trusts Keycloak's tokens.
# apiserver.config.k8s.io/v1 needs Kubernetes 1.34+; 1.30 to 1.33 take v1beta1.
apiVersion: apiserver.config.k8s.io/$version
kind: AuthenticationConfiguration
jwt:
  - issuer:
      url: $issuer
      # Snellius passes the user's ID token on, so the audience is Snellius's client ID.
      audiences: [$CLIENT_ID]
      certificateAuthority: |
$(sed 's/^/        /' "$PKI_DIR/ca.pem")
    claimMappings:
      # preferred_username, not sub: dev-mode Keycloak makes new user IDs on each realm import.
      username:
        claim: preferred_username
        prefix: "oidc:"
      groups:
        claim: groups
        prefix: "oidc:"
EOF
}

# server_minor prints the API server's minor version, e.g. 34.
server_minor() {
  K version -o json 2>/dev/null | jq -r '.serverVersion.minor' | tr -dc '0-9'
}
