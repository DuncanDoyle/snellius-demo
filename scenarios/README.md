# Walkthrough scenarios

Small, self-contained kgateway setups to explore in Snellius. Each scenario shows one thing: a healthy structure to look at, or one problem and the finding it raises. Deploy one on its own to see it in isolation, or several together to see how they combine.

The expected findings are exact, so the scenarios also serve as test cases for Snellius and for `kgwctl check`.

## Use

Install the demo first (see the [top-level README](../README.md)). Then:

```sh
./scenarios.sh --context <your-context> list            # the scenarios
./scenarios.sh --context <your-context> up 11 16        # deploy some
./scenarios.sh --context <your-context> up all          # deploy every scenario except 22
./scenarios.sh --context <your-context> down 11         # remove one
./scenarios.sh --context <your-context> down all        # remove them all
```

`--context` defaults to the current context. The script passes it to every `kubectl` call and never changes your current context.

## Conventions

- Each scenario is one file, `scenarios/NN-name.yaml`, and owns one or more namespaces named `uc-NN-…`.
- Every namespace carries the label `scenario: "NN"`. `down` deletes the namespaces with that label.
- Each scenario brings its own Gateway, except 20, which builds on 19. `up 20` deploys 19 first.
- Scenarios 01 and 10 need a TLS Secret. `scenarios.sh` creates a self-signed one, so use the script rather than `kubectl apply -f` for those two.
- Scenarios 21 and 22 apply their faulty object once the Gateway's proxies are ready, as a bad change to a running Gateway. A proxy that starts with rejected config fails its startup probe instead.

## Healthy setups

These raise no finding.

| # | Name | What it shows | Expected finding | Verified |
|---|---|---|---|---|
| 01 | Basic storefront | One Gateway with HTTP and HTTPS listeners and three simple HTTPRoutes. | None | kgateway v2.5.1, 2026-11-20 |
| 02 | ListenerSets | One Gateway, plus a ListenerSet and a route in each of two team namespaces. | None | kgateway v2.5.1, 2026-11-20 |
| 03 | Rich HTTPRoute | Path and header matches, a 90/10 canary split across two Services, and a redirect. | None | kgateway v2.5.1, 2026-11-20 |
| 04 | Route delegation | A parent route delegates `/shop` to every route in another namespace. | None | kgateway v2.5.1, 2026-11-20 |
| 05 | Cross-namespace with ReferenceGrant | A route sends traffic to a Service in another namespace, allowed by a ReferenceGrant. | None | kgateway v2.5.1, 2026-11-20 |
| 06 | Policies | A TrafficPolicy on the Gateway and one on a route, and a BackendConfigPolicy on a Service. | None | kgateway v2.5.1, 2026-11-20 |
| 07 | Backends | Two kgateway Backends (static hosts) next to a plain Service. | None | kgateway v2.5.1, 2026-11-20 |
| 08 | Shared route | One HTTPRoute attached to two Gateways. | None | kgateway v2.5.1, 2026-11-20 |
| 09 | Big Gateway | 70 routes on one Gateway, so the map opens on problems only and lists page. | None | kgateway v2.5.1, 2026-11-20 |
| 10 | Non-HTTP routes | A TCPRoute and a TLSRoute (TLS passthrough), each on its own listener. | None | kgateway v2.5.1, 2026-11-20 |
| 19 | Platform and teams | `uc-19-infra` owns a Gateway that accepts routes only from namespaces labelled `platform-access: "true"`. `uc-19-team-a` and `uc-19-team-b` own their HTTPRoutes and a TrafficPolicy each. `uc-19-shared` holds common backends and the ReferenceGrants for both teams. | None | kgateway v2.5.1, 2026-11-20 |

## One problem each

| # | Name | What goes wrong | Expected finding | Verified |
|---|---|---|---|---|
| 11 | Route to a missing Service | A backendRef names a Service that does not exist. | `KGWUI-013` `ref-unresolved`, error, on HTTPRoute `uc-11-missing-service/orders`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 12 | Cross-namespace without ReferenceGrant | A route sends traffic to a Service in another namespace, and no ReferenceGrant allows it. | `KGWUI-014` `ref-not-permitted`, error, on HTTPRoute `uc-12-frontend/payments`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 13 | Route to a missing listener | A parentRef names a listener (`sectionName: https`) the Gateway does not have. | `KGWUI-002` `condition-false`, error, reason `NoMatchingParent`, on HTTPRoute `uc-13-missing-listener/login`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 14 | Listener conflict | A ListenerSet adds a listener with the same port and hostname as the Gateway's. Its second listener is fine. | `KGWUI-017` `listener-conflicted`, error, reason `HostnameConflict`, on ListenerSet `uc-14-listener-conflict/team`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 15 | Policy target missing | A TrafficPolicy targets an HTTPRoute that does not exist (a typo). | `KGWUI-016` `policy-target-not-found`, error, reason `TargetNotFound`, on TrafficPolicy `uc-15-policy-target/checkout-timeout`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 16 | Backend scaled to 0 | A route's Service has no ready Pods. | `KGWUI-023` `backend-no-ready-endpoints`, warning after 30 s, on Service `uc-16-scaled-to-zero/search` | kgateway v2.5.1, 2026-11-20 |
| 17 | Namespace not watched | A route in a namespace kgateway does not watch targets a Gateway. Needs `discoveryNamespaceSelectors`: see below. | `KGWUI-004` `namespace-not-watched`, warning, on HTTPRoute `uc-17-unwatched/reports`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 18 | Proxy cannot start | The Gateway's GatewayParameters set a proxy image tag that does not exist. | `KGWUI-006` `proxy-not-ready`, error, on Gateway `uc-18-proxy-image/web`, within seconds | kgateway v2.5.1, 2026-11-20 |
| 20 | Team without access | Builds on 19: a team namespace without the access label attaches a route, and the listener refuses it. | `KGWUI-002` `condition-false`, error, reason `NotAllowedByListeners`, on HTTPRoute `uc-20-team-c/billing`, within seconds | kgateway v2.5.1, 2026-11-20 |

Scenario 18 pulls an image that does not exist, so its proxy Pod stays in `ImagePullBackOff`.

### Scenario 17 needs a selector

A default kgateway install watches every namespace, so no namespace is unwatched. `scenarios.sh` then skips 17 and says so. To deploy it, install kgateway with a `discoveryNamespaceSelectors` that leaves out `uc-17-unwatched`. This one leaves out only namespaces labelled `kgateway-watch: "false"`, which scenario 17 sets:

```sh
helm --kube-context <your-context> -n kgateway-system upgrade kgateway \
  oci://cr.kgateway.dev/kgateway-dev/charts/kgateway --version <your kgateway version> --reuse-values \
  --set-json 'discoveryNamespaceSelectors=[{"matchExpressions":[{"key":"kgateway-watch","operator":"NotIn","values":["false"]}]}]'
```

If your selector picks namespaces by another label, check that it selects the other scenario namespaces and leaves out `uc-17-unwatched`.

## Proxy rejections (NACK)

kgateway accepts these, and the Gateway still reports `Programmed=True`, but the proxies reject the config. `kubectl` shows nothing wrong.

| # | Name | What goes wrong | Expected finding | Verified |
|---|---|---|---|---|
| 21 | Route rejected by the proxy | A regex path passes kgateway's check but exceeds the proxy's regex size limit, so both proxies of this Gateway reject its route config. Only this Gateway is affected. | `KGWUI-001` `xds-rejected`, error, on Gateway `uc-21-route-nack/web` ("RouteConfiguration rejected on 2 streams"), within seconds | kgateway v2.5.1, 2026-11-20 |
| 22 | Cluster rejected everywhere | A BackendConfigPolicy sets a cipher suite that does not exist, so the proxies reject the cluster. | `KGWUI-001` `xds-rejected`, error, on every Gateway of the install ("Cluster rejected on 1 stream" each), within seconds | kgateway v2.5.1, 2026-11-20 |

**Deploy 22 on its own.** kgateway sends clusters to every proxy of the install, so every Gateway gets the rejection, including the demo's `infra/shared` and `team-a/team-a` and any other scenario's Gateway. `up all` leaves 22 out for that reason.

## Not covered

These findings come from the controller itself: `controller-not-ready` (005), `scope-mismatch` (007), `ambiguous-ownership` (009), `process-restarting` (019), `rollout-stuck` (021) and `version-skew` (022). Triggering them means breaking or restarting the kgateway controller, which affects every scenario at once, so no scenario stages them.

## Resources

Every scenario runs its own Gateway proxy, and most run a small backend. `up all` starts 22 proxies and 22 backend Pods, which need about 1 GB of memory more than the demo alone. On a cluster that is short of memory, the proxies fail their probes, and Snellius adds `proxy-not-ready` (006), `process-restarting` (019) and `probe-failing` (020) findings that no scenario intends.
