# Snellius demo

This repository installs [kgateway](https://kgateway.dev) and [Snellius](https://github.com/DuncanDoyle/snellius), a read-only UI for Kubernetes Gateway API, into a Kubernetes cluster you already have. It adds a small set of Gateways, routes and backends in four namespaces to look at. Optionally, it adds Keycloak and runs Snellius in secure mode: two users sign in, and each one sees only what their own Kubernetes RBAC allows. Learn more about Snellius at [snellius.dev](https://snellius.dev).

## Quick start

You need `kubectl`, `helm`, `openssl`, `curl` and `jq`. The scripts always pass `--context` to `kubectl` and `--kube-context` to `helm`, and never change your current context.

### Local mode, on any cluster

```sh
./install.sh --context <your-context>
kubectl --context <your-context> -n snellius port-forward svc/ui-snellius 8080:80
```

Open http://localhost:8080. Local mode has no sign-in: whoever can port-forward to Snellius sees everything it can read. The first page load in each browser tab plays a short intro of the Snellius prism; a click or key press skips it.

### Secure mode, on kind

```sh
./kind/create.sh                                     # a kind cluster whose API server trusts Keycloak
./install.sh --context kind-snellius-demo --secure
./show-credentials.sh --context kind-snellius-demo   # alice's and bob's passwords
kubectl --context kind-snellius-demo -n snellius port-forward svc/ui-snellius 8080:80
```

Open http://localhost:8080. Snellius sends you to Keycloak at https://keycloak.localhost:30443 to sign in. After you sign in, a short intro of the Snellius prism plays while the overview loads.

Secure mode only works where you can make the API server trust Keycloak. [docs/api-server-oidc.md](docs/api-server-oidc.md) explains how for kind, minikube, kubeadm and managed clusters.

### Flags

| Flag | Default | Meaning |
|---|---|---|
| `--context` | current context | The context to install into. The script prints it and asks before it starts. |
| `--yes` | off | Skip the question. |
| `--secure` | off | Add Keycloak and run Snellius in secure mode. |
| `--issuer-host` | `keycloak.localhost` | Host name or IP in Keycloak's issuer URL, `https://<host>:30443/realms/snellius`. |
| `--kgateway-version` | latest release | A kgateway release, such as `v2.5.2`. |
| `--gateway-api-version` | from kgateway's `go.mod` | The Gateway API release whose standard CRDs are installed. |
| `--snellius-version` | latest release | A Snellius chart version, such as `0.8.2`. |
| `--ui-port` | `8080` | The local port of the Snellius port-forward. In secure mode it is part of the redirect URL. |

The environment variables `KGATEWAY_VERSION`, `GATEWAY_API_VERSION`, `SNELLIUS_VERSION`, `ISSUER_HOST` and `UI_PORT` set the same values. Running `install.sh` again is safe. It upgrades what is there and keeps the generated passwords.

## What gets installed

1. The Gateway API CRDs, standard channel, at the version the kgateway release is built on.
2. kgateway, from its Helm charts in `kgateway-system`, as the [kgateway docs](https://kgateway.dev/docs/envoy/latest/quickstart/) describe.
3. The use cases in [manifests/use-cases.yaml](manifests/use-cases.yaml): namespaces `infra`, `team-a`, `team-b` and `team-c`.
4. With `--secure`: Keycloak in `keycloak`, with realm `snellius` and users alice and bob, and the RBAC in [manifests/rbac.yaml](manifests/rbac.yaml).
5. Snellius, release `ui` in `snellius`, with [values/local.yaml](values/local.yaml) or [values/secure.yaml](values/secure.yaml).

If the cluster already has the Gateway API CRDs or a kgateway release in `kgateway-system`, the script leaves them as they are, and `uninstall.sh` leaves them too.

A default kgateway install watches every namespace. If yours sets `discoveryNamespaceSelectors`, label the four demo namespaces so that it selects them.

## The use cases

| Namespace | What is in it | bob can read it |
|---|---|---|
| `infra` | The platform Gateway `shared`, which admits routes from all namespaces, and route `platform-status` | No |
| `team-a` | Gateway `team-a`, which admits routes from all namespaces, Service `web`, routes `web`, `orders` and `broken` | Yes |
| `team-b` | Service `catalog`, kgateway Backend `partner-api`, routes `catalog` and `partner`, and route `shop`, which delegates to `shop-items` | Yes |
| `team-c` | Service `payments` with a ReferenceGrant for team-a's routes, routes `billing`, `internal-admin` (broken) and `ghost` (broken) | No |

## The two users

| User | Keycloak group | Kubernetes identity | Access |
|---|---|---|---|
| alice | `platform-admins` | `oidc:alice`, group `oidc:platform-admins` | Read everything Snellius reads, cluster-wide, plus Events and CRDs |
| bob | `app-devs` | `oidc:bob`, group `oidc:app-devs` | The same read, only in `team-a` and `team-b` |

`install.sh` generates their passwords and keeps them in the Secret `keycloak/keycloak-credentials`. `./show-credentials.sh` prints them, with Keycloak's admin password.

To switch user, open the user menu at the top right and select **Sign out**. That ends the Keycloak session too. A private window lets you show both users side by side.

## What each user sees

| Use case | Where to look | alice | bob |
|---|---|---|---|
| 1. A route on a Gateway bob can't read | Routes, `team-a/web` | Traffic path **Healthy**, through Gateway `infra/shared` | Traffic path **Unknown**: "You don't have permission to check the whole path." He still sees the route's own status. |
| 2. A route whose backend bob can't read | Routes, `team-a/orders` | Both rules healthy | Path **Unknown**. Rule 1's backend `team-c/payments` shows no health, and the Traffic page leaves out the `/pay` path. |
| 3. Objects bob can't read are absent | Routes, Findings, Traffic | 11 routes, including `team-c/internal-admin` and `team-c/ghost` with their findings | 7 routes. No counts, placeholders or "restricted" markers for the rest. Opening `team-c/internal-admin` directly shows "Not in this install's scope". |
| 4. A listener's route count | Gateways, `team-a/team-a` | Listener `http` has 5 routes, and the count check reads "Agrees" | 4 routes and no count check. The check needs `list` on routes in every namespace the listener admits. |
| 5. Install details | The header, top left | `kgateway-system/kgateway`, its version and controller readiness | Only the install ID, "Details not visible to you", and "You see what your Kubernetes permissions allow." |
| 6. A broken route bob can see | Findings, or Routes, `team-a/broken` | "Backend not found" for Service `team-a/web-v2` | The same finding. All its objects are in `team-a`. |
| 7. The namespace selector | Header, **All namespaces** | `infra`, `team-a`, `team-b`, `team-c` | `team-a`, `team-b` |
| 8. Delegation | Routes, `team-b/shop` | Delegation to `shop-items` computed by Snellius | "Reported by the controller". Delegation analysis reads every route, so it needs the full read. |

Every sign-in, detail read and denied request goes to Snellius's audit stream:

```sh
kubectl --context <your-context> -n snellius logs deploy/ui-snellius | grep '"snellius.audit"'
```

The [Snellius README](https://github.com/DuncanDoyle/snellius#what-each-user-sees) has the full rules for what a restricted user sees.

## Walkthrough scenarios

[scenarios/](scenarios/README.md) has 22 small scenarios to deploy next to the demo. Each one shows a healthy structure, such as ListenerSets or route delegation, or one problem and the exact finding it raises, such as a missing Service or a route the proxies reject.

```sh
./scenarios.sh --context <your-context> list
./scenarios.sh --context <your-context> up 11 16
./scenarios.sh --context <your-context> down all
```

## How secure mode works

- **One issuer URL.** The browser, the API server and the Snellius pod all use `https://<issuer-host>:30443/realms/snellius`. It must be the same string everywhere, because the API server compares it with the token's `iss` claim. Keycloak's Service port equals its NodePort, 30443, so the URL works through a node and through the Service alike. Inside the Snellius pod, a host alias points the issuer host at Keycloak's Service.
- **Audience.** Snellius signs users in as OIDC client `snellius` and passes each user's ID token to the API server. The API server accepts that token because `snellius` is an audience in its authentication config.
- **Claims.** The API server maps `preferred_username` to the username and `groups` to the groups, both with the prefix `oidc:`. A Keycloak client mapper adds the `groups` claim.
- **RBAC.** For every object, Snellius asks the API server whether the signed-in user may read it, with a SubjectAccessReview. The bindings in [manifests/rbac.yaml](manifests/rbac.yaml) decide the answer. Snellius reads the cluster with its own ServiceAccount and never shows more than that.
- **Port-forward.** Snellius stays behind `kubectl port-forward`, so its redirect URL is `http://localhost:8080/auth/callback`, or the port you set with `--ui-port`. Snellius allows plain http only on localhost, with `auth.session.cookieSecure: false`.
- **Local state.** The demo CA lives in `.demo/pki/` in your checkout, and the API server config in `.demo/`. Git ignores the folder.

## Troubleshooting

- **Certificate warning.** The demo CA issued Keycloak's certificate, so the browser warns on the first visit to Keycloak. Accept it, or trust `.demo/pki/ca.pem` in your browser or system.
- **Sign-in ends on "unauthenticated".** The API server does not accept Keycloak's tokens. Run `install.sh --secure` again: its last step checks this. Then see [docs/api-server-oidc.md](docs/api-server-oidc.md).
- **Sign-in ends on "invalid".** The code exchange failed. `kubectl -n keycloak logs deploy/keycloak` shows the reason. Keycloak rejects scopes it does not know, so the demo asks only for `openid`, `profile`, `email` and `offline_access`.
- **Port 8080 is in use.** Another port-forward on the same port answers instead, and its sign-in fails. Stop it, or install with `--ui-port 18080` and port-forward to that port.
- **`keycloak.localhost` does not open.** Some browsers and systems do not resolve `*.localhost`. Add `127.0.0.1 keycloak.localhost` to `/etc/hosts`.
- **Keycloak restarted.** Dev-mode Keycloak imports the realm again on each start, so its sign-in sessions end. The passwords stay the same.
- **Token not yet valid, or expired.** The node's clock is off. Tokens carry issue and expiry times, so a VM whose clock drifts rejects them. Set the VM's clock, for example with `minikube ssh -- sudo date -s @$(date +%s)`.
- **Images do not pull.** The cluster needs to reach `quay.io` (Keycloak), `ghcr.io` (Snellius), `cr.kgateway.dev` (kgateway) and Docker Hub (the demo backends). If your nodes cannot, pull the images on your machine and load them, with `kind load docker-image` or `minikube image load`.
- **The kind node restarted.** Run `./kind/create.sh` again. It sets the node's host entry for `keycloak.localhost` again.

## Uninstall

```sh
./uninstall.sh --context <your-context>              # add --keep-crds to keep the CRDs
kind delete cluster --name snellius-demo             # if you used kind/create.sh
```

Remove any scenarios first, with `./scenarios.sh --context <your-context> down all`. `uninstall.sh` removes Snellius, Keycloak, the RBAC and the use cases. It removes kgateway and the Gateway API CRDs only if `install.sh` installed them. It does not change the API server's authentication config back. [docs/api-server-oidc.md](docs/api-server-oidc.md) says how, or delete the cluster.

## Licence

Apache License 2.0. See [LICENSE](LICENSE).
