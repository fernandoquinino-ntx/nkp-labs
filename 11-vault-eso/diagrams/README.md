# Lab 11 — diagrams

Mermaid diagrams for "Vault → Kubernetes via the External Secrets Operator, configured by an NKP
AppDeployment override". Each diagram also exists as a standalone `.mmd` you can render/copy into a
deck:

| File | Shows |
|---|---|
| [`01-overview.mmd`](01-overview.mmd) | the whole picture: override → ESO → Vault → Secret → app |
| [`02-override-wiring.mmd`](02-override-wiring.mmd) | how a ConfigMap override becomes real objects (`extraObjects`) |
| [`03-pull-sequence.mmd`](03-pull-sequence.mmd) | the runtime secret pull (login + read) |
| [`04-auth-per-cluster.mmd`](04-auth-per-cluster.mmd) | why Vault kubernetes auth needs a mount *per cluster* |

## 01 — Overview

> The override carries **only the credential store** (`ClusterSecretStore`). The `ExternalSecret`,
> `Secret` and demo app are the **consumer/test** side — applied separately.

```mermaid
flowchart LR
  subgraph CFG["Configuration (NKP)"]
    OVR["ConfigMap<br/>external-secrets-overrides<br/>extraObjects → ClusterSecretStore"]
    AD["AppDeployment external-secrets<br/>configOverrides → OVR"]
    AD -- "Helm values" --> OVR
  end

  subgraph TGT["Target cluster — ESO"]
    HR["HelmRelease external-secrets"]
    CSS["ClusterSecretStore vault-backend"]
    ES["ExternalSecret lab-app-credentials"]
    SEC[("Secret lab-app-credentials")]
    APP["Deployment lab-eso-demo"]
    ES --> SEC --> APP
  end

  subgraph VT["Vault (management cluster)"]
    KV[("secret/app-credentials (KV v2)")]
    AU["auth/kubernetes-&lt;cluster&gt; · role eso"]
  end

  AD --> HR
  HR -- "renders extraObjects (the store ONLY)" --> CSS
  CSS -- "login (SA token)" --> AU
  CSS -- "read" --> KV
  CONS["consumer / test side — applied separately"] -.-> ES
```

## 02 — How the override is wired

```mermaid
flowchart TD
  UI["NKP UI: Applications → Edit configuration"] --> CM
  CLI["kubectl edit configmap"] --> CM
  CM["ConfigMap &lt;app&gt;-overrides<br/>data.values.yaml"] --> ADI["AppDeploymentInstance"]
  AD["AppDeployment.spec<br/>configOverrides.name<br/>clusterConfigOverrides[].configMapName"] --> ADI
  ADI --> HR["HelmRelease.spec.valuesFrom"]
  HR --> CHART["external-secrets chart"]
  CHART -- "tpl-renders each extraObjects entry" --> OBJ["ClusterSecretStore + ExternalSecret + Deployment"]
```

## 03 — Runtime: the secret pull

```mermaid
sequenceDiagram
  participant ESO as ESO (target cluster)
  participant VA as Vault (mgmt)
  participant K8S as Kubernetes API
  ESO->>VA: POST auth/kubernetes-<cluster>/login  (ServiceAccount token)
  VA->>K8S: TokenReview (reviewer SA)
  K8S-->>VA: valid — SA name + namespace
  VA-->>ESO: Vault client_token
  ESO->>VA: GET secret/data/app-credentials
  VA-->>ESO: username / password
  ESO->>K8S: create/update Secret lab-app-credentials
  Note over ESO,K8S: reconciled every refreshInterval (1h)
```

## 04 — Why auth is per cluster

```mermaid
flowchart LR
  subgraph W["Workload cluster (ds-cluster01)"]
    SA["SA eso-vault<br/>ns external-secrets"]
    REV["SA vault-auth<br/>+ system:auth-delegator"]
  end
  subgraph M["Vault (management cluster)"]
    MNT["auth/kubernetes-ds-cluster01<br/>kubernetes_host = workload API"]
    ROLE["role eso → policy eso-ds-cluster01"]
    MNT --- ROLE
  end
  SA -- "login (token)" --> MNT
  MNT -- "TokenReview" --> REV
  X["auth/kubernetes (mgmt-bound)<br/>rejects workload tokens"] -.-> MNT
```
