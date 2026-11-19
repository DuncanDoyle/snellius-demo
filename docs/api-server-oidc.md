# Make the API server trust Keycloak

Secure mode needs an API server that accepts Keycloak's ID tokens. Snellius sends each signed-in user's ID token to the API server, and the API server's answer decides what that user sees. Without this step, sign-in ends on "unauthenticated", and `install.sh --secure` warns that the API server does not accept Keycloak's tokens.

Local mode needs none of this and works on every cluster.

## What the API server needs

`install.sh --secure` writes `.demo/authentication-config.yaml`, a [structured authentication configuration](https://kubernetes.io/docs/reference/access-authn-authz/authentication/#using-authentication-configuration) for the demo's issuer:

| Setting | Value | Why |
|---|---|---|
| Issuer URL | `https://<issuer-host>:30443/realms/snellius` | It must match the `iss` claim byte for byte. The browser, the API server and the Snellius pod all use this same URL. |
| Audience | `snellius` | Snellius's client ID. The ID token Snellius passes on carries it as `aud`. |
| CA | The demo CA, inline | Keycloak's certificate comes from a CA that `install.sh` creates. |
| Username | `preferred_username`, prefix `oidc:` | Dev-mode Keycloak gives users a new `sub` each time it imports the realm. |
| Groups | `groups`, prefix `oidc:` | `manifests/rbac.yaml` binds `oidc:platform-admins` and `oidc:app-devs`. |

The API server must also reach the issuer URL itself, to fetch Keycloak's signing keys. Keycloak runs in the cluster as a NodePort on 30443, so the issuer host must resolve, on the control plane node, to an address where that NodePort answers. Inside the Snellius pod, `install.sh` maps the issuer host to Keycloak's Service.

Version notes:

- The file uses `apiserver.config.k8s.io/v1` on Kubernetes 1.34 and later. Kubernetes 1.30 to 1.33 take `v1beta1`, which `install.sh` picks from the server version.
- `--authentication-config` cannot be combined with any `--oidc-*` flag. The API server exits if both are set.
- The API server reloads the file when it changes, so an edit needs no restart. Adding the flag itself does.

## kind

`kind/create.sh` does all of this. It creates the demo CA, writes the config to `.demo/kind/`, and creates a cluster from [`kind/cluster-secure.yaml`](../kind/cluster-secure.yaml):

- An `extraMounts` entry mounts `.demo/kind/` into the node.
- A kubeadm patch adds `--authentication-config` and a volume for that folder to the API server.
- An `extraPortMappings` entry publishes Keycloak's NodePort 30443 on your machine.

The default issuer host is `keycloak.localhost`. Browsers, curl and macOS resolve every `*.localhost` name to your own machine, where the port mapping sends it to Keycloak. Inside the node, `kind/create.sh` maps `keycloak.localhost` to the node's IP, in the node's `/etc/hosts` and in the API server pod's own copy of it.

```sh
./kind/create.sh                      # cluster "snellius-demo", context kind-snellius-demo
./install.sh --context kind-snellius-demo --secure
```

Docker rewrites the node's `/etc/hosts` when the node container restarts. Run `./kind/create.sh` again after a restart: on an existing cluster it only sets the host entry again.

Safari and some Linux setups do not resolve `*.localhost`. Then add `127.0.0.1 keycloak.localhost` to your machine's `/etc/hosts`.

## minikube

Use a VM driver whose IP your machine can reach, such as `vfkit`, `qemu`, `hyperkit` or `kvm2`, and use that IP as the issuer host.

1. Install with the minikube IP as the issuer host. The last step warns that the API server does not trust Keycloak yet, and writes `.demo/authentication-config.yaml`.

   ```sh
   ./install.sh --context minikube --secure --issuer-host "$(minikube ip)"
   ```

2. Copy the file onto the node. `/var/lib/minikube/certs` is already mounted into the API server pod.

   ```sh
   minikube ssh -- sudo mkdir -p /var/lib/minikube/certs/snellius-oidc
   minikube cp .demo/authentication-config.yaml minikube:/var/lib/minikube/certs/snellius-oidc/auth.yaml
   ```

3. Restart the control plane with the flag. minikube keeps `--extra-config` in its profile, so later starts keep it too.

   ```sh
   minikube start --extra-config=apiserver.authentication-config=/var/lib/minikube/certs/snellius-oidc/auth.yaml
   ```

4. Run step 1 again. It now reports that the API server accepts Keycloak's tokens.

Pass `-p <profile>` to every `minikube` command if you use a profile.

To undo it, remove the `authentication-config` entry from `KubernetesConfig.ExtraOptions` in `~/.minikube/profiles/<profile>/config.json`, run `minikube start` again, and remove the folder from the node. Or delete the cluster.

With the docker driver on macOS or Windows, your machine cannot reach the node's IP. Use kind instead, or a VM driver.

## Self-managed clusters (kubeadm)

Do this on every control plane node.

1. Run `install.sh --secure --issuer-host <host>`. Pick a host name or IP that your browser reaches on port 30443 and that each control plane node resolves to a node where the NodePort answers.
2. Copy `.demo/authentication-config.yaml` to `/etc/kubernetes/snellius-oidc/auth.yaml` on the node.
3. Edit `/etc/kubernetes/manifests/kube-apiserver.yaml`. Add the flag and mount the folder:

   ```yaml
   spec:
     containers:
       - command:
           - kube-apiserver
           - --authentication-config=/etc/kubernetes/snellius-oidc/auth.yaml
           # ...the existing flags; remove any --oidc-* flags
         volumeMounts:
           - {name: snellius-oidc, mountPath: /etc/kubernetes/snellius-oidc, readOnly: true}
     volumes:
       - {name: snellius-oidc, hostPath: {path: /etc/kubernetes/snellius-oidc, type: Directory}}
   ```

   The kubelet restarts the API server when the manifest changes. For a new cluster, set the same flag and volume in `ClusterConfiguration.apiServer.extraArgs` and `extraVolumes` before `kubeadm init`.
4. Run `install.sh` again to check the result.

If the cluster already trusts another issuer, add the demo's entry to the `jwt` list of your existing file instead of replacing it.

## Managed clusters

On managed clusters you cannot set API server flags. What works depends on the provider.

- **Amazon EKS.** EKS can [associate an OIDC identity provider](https://docs.aws.amazon.com/eks/latest/userguide/authenticate-oidc-identity-provider.html) with a cluster: issuer URL, client ID `snellius`, username claim `preferred_username`, groups claim `groups`, and prefix `oidc:` for both. EKS requires an issuer that is reachable from the internet and has a publicly trusted certificate. It does not support self-signed certificates. The demo's Keycloak, with its own CA, does not meet that. Secure mode on EKS needs a Keycloak, or another IdP, with a public URL and a public certificate. `install.sh` does not set that up.
- **Google Kubernetes Engine.** Secure mode is not available on GKE in Snellius 0.8.x. The GKE API server does not accept a third-party IdP's ID token directly. [Identity Service for GKE is deprecated](https://cloud.google.com/kubernetes-engine/docs/deprecations/identity-service), and its replacement, Workforce Identity Federation, signs users in with Google tokens. Use local mode.
- **Azure Kubernetes Service.** Secure mode is not available on AKS in Snellius 0.8.x. AKS with Microsoft Entra ID accepts only Entra tokens. AKS has a [preview of external identity providers through structured authentication](https://learn.microsoft.com/en-us/azure/aks/external-identity-provider-authentication-overview), but it requires a publicly reachable IdP and an `aks:jwt:` prefix on every username and group. This demo has not been tested with it. Use local mode.

Snellius tracks GKE support in [snellius#51](https://github.com/DuncanDoyle/snellius/issues/51).
