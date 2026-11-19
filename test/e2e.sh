#!/usr/bin/env bash
# Checks a demo install through Snellius's API. In secure mode it signs in as
# alice and bob through Keycloak, with curl, and checks that each sees what
# their RBAC allows. --local checks a local-mode install instead.
set -euo pipefail
# shellcheck source=lib/common.sh
source "$(dirname "$0")/../lib/common.sh"

CONTEXT=${KUBE_CONTEXT:-}
ISSUER_HOST=${ISSUER_HOST:-$DEFAULT_ISSUER_HOST}
MODE=secure
while (($#)); do
  case $1 in
    --context) CONTEXT=$2; shift 2 ;;
    --issuer-host) ISSUER_HOST=$2; shift 2 ;;
    --local) MODE=local; shift ;;
    *) die "unknown flag: $1" ;;
  esac
done
need kubectl curl jq
[[ -n $CONTEXT ]] || CONTEXT=$(kubectl config current-context)

TMP=$(mktemp -d)
chmod 700 "$TMP"
PF_PID=""
cleanup() {
  # wait reports the killed port-forward's status, which is not this script's.
  [[ -n $PF_PID ]] && { kill "$PF_PID"; wait "$PF_PID" || true; } 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

if [[ $MODE == secure ]]; then
  UI_PORT=$(K -n keycloak get configmap keycloak-settings -o jsonpath='{.data.ui-port}')
fi
BASE=http://localhost:$UI_PORT
# Another port-forward on the port would answer for this one.
curl -s -o /dev/null --max-time 2 "$BASE/" && die "port $UI_PORT is in use; stop what listens there or install with --ui-port"
FAILS=0
pass() { printf '  ok    %s\n' "$*"; }
fail() { printf '  FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
check() { if [[ $2 == "$3" ]]; then pass "$1: $2"; else fail "$1: got '$2', want '$3'"; fi; }

K -n snellius port-forward svc/ui-snellius "$UI_PORT:80" >"$TMP/pf.log" 2>&1 &
PF_PID=$!
for _ in $(seq 1 30); do
  curl -fs "$BASE/auth/status" >/dev/null 2>&1 && break
  sleep 1
done
check "auth mode" "$(curl -fs "$BASE/auth/status" | jq -r .mode)" "$MODE"

if [[ $MODE == local ]]; then
  # Local mode: no sign-in, and every route is visible.
  ID=$(curl -fsS "$BASE/api/v1/installs" | jq -r '.[0].id')
  check "routes" "$(curl -fsS "$BASE/api/v1/installs/$ID/routes?limit=200" | jq -r .total)" 11
  check "namespaces" "$(curl -fsS "$BASE/api/v1/installs/$ID/namespaces" | jq -r '.namespaces | join(",")')" "infra,team-a,team-b,team-c"
  ((FAILS == 0)) || { echo "$FAILS check(s) failed"; exit 1; }
  echo "All checks passed"
  exit 0
fi

# *.localhost is this machine, where kind's port mapping reaches Keycloak.
resolve=()
[[ $ISSUER_HOST == *.localhost ]] && resolve=(--resolve "$ISSUER_HOST:$KEYCLOAK_PORT:127.0.0.1")
CURL=(curl -fsS --max-time 20 --cacert "$PKI_DIR/ca.pem" ${resolve[@]+"${resolve[@]}"})

# sign_in runs the browser flow for user $1 and leaves its session in $TMP/$1.jar.
sign_in() {
  local user=$1 jar=$TMP/$1.jar page action final
  K -n keycloak get secret keycloak-credentials -o jsonpath="{.data.$user-password}" | base64 -d >"$TMP/$user.pw"
  rm -f "$jar"
  # /auth/login redirects to Keycloak's login form.
  page=$("${CURL[@]}" -L -c "$jar" -b "$jar" "$BASE/auth/login?return=/")
  action=$(grep -o 'action="[^"]*login-actions/authenticate[^"]*"' <<<"$page" | head -n1 | sed -e 's/^action="//' -e 's/"$//' -e 's/&amp;/\&/g')
  [[ -n $action ]] || { fail "$user: no Keycloak login form"; return 1; }
  # Posting the form redirects back to Snellius's callback, which sets the session cookie.
  final=$("${CURL[@]}" -L -c "$jar" -b "$jar" -o /dev/null -w '%{url_effective}' \
    --data-urlencode "username=$user" --data-urlencode "password@$TMP/$user.pw" -d credentialId= "$action")
  rm -f "$TMP/$user.pw"
  check "$user: sign-in ends on" "$final" "$BASE/"
}

api() { curl -fsS --max-time 30 -b "$TMP/$1.jar" "$BASE$2"; }

for user in alice bob; do
  echo "Signing in as $user"
  sign_in "$user" || continue
  check "$user: /auth/me" "$(api "$user" /auth/me | jq -r .username)" "oidc:$user"
done

ID=$(api alice /api/v1/installs | jq -r '.[0].id')
echo "Install $ID"

echo "Use case: routes and namespaces bob can't read are absent"
alice_routes=$(api alice "/api/v1/installs/$ID/routes?limit=200")
bob_routes=$(api bob "/api/v1/installs/$ID/routes?limit=200")
check "alice: routes" "$(jq -r .total <<<"$alice_routes")" 11
check "bob: routes" "$(jq -r .total <<<"$bob_routes")" 7
check "bob: route namespaces" "$(jq -r '[.items[].ref.namespace] | unique | join(",")' <<<"$bob_routes")" "team-a,team-b"
check "alice: namespace selector" "$(api alice "/api/v1/installs/$ID/namespaces" | jq -r '.namespaces | join(",")')" "infra,team-a,team-b,team-c"
check "bob: namespace selector" "$(api bob "/api/v1/installs/$ID/namespaces" | jq -r '.namespaces | join(",")')" "team-a,team-b"
code=$(curl -s -o /dev/null -w '%{http_code}' -b "$TMP/bob.jar" "$BASE/api/v1/installs/$ID/routes/gateway.networking.k8s.io/HTTPRoute/team-c/internal-admin")
if [[ $code == 200 ]]; then fail "bob: team-c/internal-admin answered 200"; else pass "bob: team-c/internal-admin answered $code"; fi

echo "Use case: install header details"
check "alice: limitedView" "$(api alice /api/v1/meta | jq -r '.limitedView // false')" false
check "bob: limitedView" "$(api bob /api/v1/meta | jq -r '.limitedView // false')" true
check "alice: install details hidden" "$(api alice /api/v1/installs | jq -r '.[0].detailsHidden // false')" false
check "bob: install details hidden" "$(api bob /api/v1/installs | jq -r '.[0].detailsHidden // false')" true

echo "Use case: a broken route bob can see"
for user in alice bob; do
  check "$user: finding on team-a/broken" \
    "$(api "$user" "/api/v1/installs/$ID/findings?limit=200" | jq -r '[.items[] | select(tostring | test("team-a/broken|\"broken\""))] | length > 0')" true
done

if ((FAILS > 0)); then
  echo "$FAILS check(s) failed"
  exit 1
fi
echo "All checks passed"
