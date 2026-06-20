# PlatformCon 2026 - Workshop - When hub-and-spoke GitOps becomes a security risk at scale - Deep Dive and The Hard Way!

Welcome to the PlatformCon 2026 workshop on "When hub-and-spoke GitOps becomes a security risk at scale". In this workshop, we will explore the potential security risks associated with hub-and-spoke GitOps architectures and discuss strategies to mitigate these risks effectively.

After the workshop you should have a better understanding of:

- What is hub-and-spoke GitOps and how it works
- Why it can become a security risk at scale
- Why it matters for platform teams by thinking on retail, franchise, production - everything that runs on a edge location as spoke or stand-alone cluster
- You will also understand what real scale by getting a sneak peak into our scale test to predict the management of 15.000+ clusters
- Best practices for securing hub-and-spoke GitOps environments
- How agent based Pull Mode allows to mitigate some of the risks

*Important:* The focus of the webinar would be on the security risks of hub-and-spoke GitOps architectures, and the strategies to mitigate these risks effectively.

You should have a basic understanding of:

- GitOps with Argo CD or FluxCD or Sveltos Addoncontroller
- Kubernetes


## Setup Environment

This is the long version and a lot of steps are not sveltos related, but Kubernetes in Docker (KinD) related.
The steps are necessary to manage multiple clusters in a local environment.

If you want to skip the manual steps and just get the demo environment up and running, check out the [Quickstart](README.md) guide.

### Prerequisites

- [kubectl](https://kubernetes.io/docs/tasks/tools/) v1.35.0 or later
- [sveltosctl](https://projectsveltos.github.io/sveltos/getting_started/sveltosctl/sveltosctl/) v1.9.0 or later
- [Kubernetes in Docker (KinD)](https://kind.sigs.k8s.io/docs/user/quick-start/#installation) v0.31.0 or later
- [helm](https://helm.sh/docs/intro/install/) v4.1.0 or later
- [Docker](https://docs.docker.com/desktop/), [OrbStack](https://orbstack.dev/download) or another KinD-supported container runtime

Overview of the demo environment:

<img src="images/hub-and-spoke-overview.png" alt="hub-and-spoke" width="700" style="border-radius: 16px;" />

### 0. KinD demo clusters

The demo environment is defined in [config/demo-environment.yaml](config/demo-environment.yaml).
It creates three KinD clusters:

- `hub`
- `spoke-push`
- `spoke-pull`

The `hub` cluster is bootstrapped with Sveltos agent mode from the manifests
configured in [config/demo-environment.yaml](config/demo-environment.yaml).

The ClusterProfiles are deployed from
[config/sveltos/clusterprofiles.yaml](config/sveltos/clusterprofiles.yaml).

The Sveltos bootstrap currently applies:

- the Prometheus Operator `ServiceMonitor` CRD, required by the Sveltos
  monitoring resources in a plain KinD cluster
- Sveltos `v1.9.0` `manifest.yaml`
- Sveltos `v1.9.0` `default-instances.yaml`
- ClusterProfiles for `cert-manager`, `kro`, and `kyverno`

The demo supports two Sveltos registration patterns:

- Push mode: the Sveltos controllers in `hub` connect to a managed cluster.
- Pull mode: an applier runs in the managed cluster and connects back to `hub`.

Pull mode requires a Sveltos version whose `SveltosCluster` CRD supports
`spec.pullMode`. This demo pins Sveltos to `v1.9.0`, matching the tested
`sveltosctl v1.9.0` client.

For push mode, use an internal KinD kubeconfig for the managed cluster, so the
Sveltos controllers in `hub` connect to:

```text
https://spoke-push-control-plane:6443
```

This avoids the host-only `127.0.0.1:<port>` endpoint that KinD writes into the
default kubeconfig.

For pull mode, the generated applier kubeconfig must use the internal Hub API
endpoint:

```text
https://hub-control-plane:6443
```

The demo patches that endpoint automatically for `spoke-pull` (if enabled).

Create the clusters:

```bash
make kind-up
```

The setup also writes reusable kubeconfigs into the repo-local
`tmp/platformcon-sveltos/` directory and creates the Sveltos registration
namespaces in the Hub. The manual steps below assume you run them from the repo
root and use these generated files:

```text
tmp/platformcon-sveltos/hub.kubeconfig
tmp/platformcon-sveltos/spoke-push.internal.kubeconfig
tmp/platformcon-sveltos/spoke-pull.internal.kubeconfig
```

Recreate the clusters from scratch:

```bash
make kind-recreate
```

Delete the clusters:

```bash
make kind-down
```

Preview the KinD commands without creating anything:

```bash
make kind-plan
```

After creation, the kubectl contexts are:

- `kind-hub`
- `kind-spoke-push`
- `kind-spoke-pull`

Check Sveltos resources in the hub:

```bash
kubectl --context kind-hub get clusterprofiles
kubectl --context kind-hub get sveltoscluster -A --show-labels
```

### 1. Manual Sveltos cluster registration

The demo can register `spoke-push` in push mode when its registration is enabled
in [config/demo-environment.yaml](config/demo-environment.yaml). The same flow
can be executed manually to understand what happens.

Register `spoke-push` in the Sveltos hub:

```bash
KUBECONFIG=tmp/platformcon-sveltos/hub.kubeconfig \
  sveltosctl register cluster \
    --namespace=spoke-push \
    --cluster=kind-spoke-push \
    --kubeconfig=tmp/platformcon-sveltos/spoke-push.internal.kubeconfig \
    --labels=kro=enabled
```

The important part is `kind get kubeconfig --internal`. It writes the Kubernetes
API endpoint as:

```text
https://spoke-push-control-plane:6443
```

That address is reachable from the `hub` cluster through the Docker `kind`
network. Using `--fleet-cluster-context=kind-spoke-push` directly would copy the
host-facing KinD endpoint instead:

```text
https://127.0.0.1:<random-port>
```

That works from your laptop, but not from Sveltos controllers running inside the
`hub` cluster.

Verify the registration:

```bash
kubectl --context kind-hub get sveltoscluster -A --show-labels
kubectl --context kind-hub get sveltoscluster kind-spoke-push -n spoke-push -o yaml
```

Try different labels to match different ClusterProfiles:

```bash
--labels=kro=enabled
--labels=kyverno=enabled
--labels=cert-manager=enabled
--labels=kro=enabled,kyverno=enabled
```

### 2. Manual Sveltos pull-mode registration

Pull mode flips the network direction. The managed cluster runs
`sveltos-applier`, and that applier connects back to the Hub. In KinD, the same
`127.0.0.1` trap exists, just in the other direction.

Register `spoke-pull` in pull mode against the Hub:

```bash
KUBECONFIG=tmp/platformcon-sveltos/hub.kubeconfig \
  sveltosctl register cluster \
    --namespace=spoke-pull \
    --cluster=kind-spoke-pull \
    --pullmode \
    --labels=kro=enabled \
    > tmp/platformcon-sveltos/spoke-pull-pullmode.yaml
```

The generated YAML must be applied to the managed cluster:

```bash
kubectl --context kind-spoke-pull apply \
  -f tmp/platformcon-sveltos/spoke-pull-pullmode.yaml
```

In a local KinD setup, inspect the generated Secret:

```bash
kubectl --context kind-spoke-pull \
  -n projectsveltos \
  get secret kind-spoke-pull-sveltos-kubeconfig \
  -o go-template='{{index .data "kubeconfig" | base64decode}}'
```

If it contains a server like this, the applier will not be able to reach the Hub:

```text
server: https://127.0.0.1:<random-port>
```

Patch the kubeconfig to use the Hub control-plane container instead:

```bash
kubectl --context kind-spoke-pull \
  -n projectsveltos \
  get secret kind-spoke-pull-sveltos-kubeconfig \
  -o go-template='{{index .data "kubeconfig" | base64decode}}' \
  > tmp/platformcon-sveltos/spoke-pull-applier.kubeconfig

kubectl config set-cluster local \
  --kubeconfig tmp/platformcon-sveltos/spoke-pull-applier.kubeconfig \
  --server https://hub-control-plane:6443

kubectl --context kind-spoke-pull \
  -n projectsveltos \
  create secret generic kind-spoke-pull-sveltos-kubeconfig \
  --from-file=kubeconfig=tmp/platformcon-sveltos/spoke-pull-applier.kubeconfig \
  --dry-run=client \
  -o yaml \
  > tmp/platformcon-sveltos/spoke-pull-applier-secret.yaml

kubectl --context kind-spoke-pull apply \
  -f tmp/platformcon-sveltos/spoke-pull-applier-secret.yaml

kubectl --context kind-spoke-pull \
  -n projectsveltos \
  rollout restart deployment/sveltos-applier-manager

kubectl --context kind-spoke-pull \
  -n projectsveltos \
  rollout status deployment/sveltos-applier-manager \
  --timeout=180s
```

Verify from the Hub:

```bash
kubectl --context kind-hub get sveltoscluster kind-spoke-pull -n spoke-pull --show-labels
```

Verify the deployment in the managed cluster:

```bash
kubectl --context kind-hub get clustersummaries.config.projectsveltos.io -A -o wide

#or

KUBECONFIG=tmp/platformcon-sveltos/hub.kubeconfig sveltosctl show addons
```

Done! ✅

---

### Clean up

```bash
make kind-down
```
