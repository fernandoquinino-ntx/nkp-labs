# Lab 08 — diagrams: install, configure, collect, send

One page to *see* how the Splunk OpenTelemetry Collector is put together. Everything here matches the
values in this lab (chart `splunk-otel-collector` 0.160.0).

> Mermaid renders automatically on GitHub (and in the VS Code Markdown preview). If you read this in a
> plain terminal you will just see the code blocks — open it on GitHub to see the diagrams.

---

## 1. Install and configure — from `local.env` to running pods

```mermaid
flowchart TB
  subgraph INPUT["1. Your input (gitignored)"]
    ENV["local.env<br/>OTEL_NAMESPACE / OTEL_RELEASE / CHART_VERSION<br/>SPLUNK_CLUSTER_NAME / SPLUNK_HEC_ENDPOINT<br/>SPLUNK_HEC_TOKEN / SPLUNK_INDEX / SPLUNK_METRICS_INDEX<br/>PROMETHEUS_ENABLED"]
  end

  subgraph RENDER["2. Render (scripts/render.sh) — fills the ${...} placeholders"]
    VB["rendered/.../values.example.yaml<br/>base: logs + metrics + cluster receiver"]
    VP["rendered/.../values-prometheus.example.yaml<br/>add-on: Prometheus federation"]
  end

  subgraph MERGE["3. Helm merges (maps merge, lists are REPLACED)"]
    DEF["chart defaults (0.160.0)"]
    EFF["effective values"]
    DEF --> EFF
    VB --> EFF
    VP --> EFF
  end

  subgraph DEPLOY["4. install.sh --apply"]
    REPO["helm repo add signalfx/splunk-otel-collector-chart"]
    UP["helm upgrade --install<br/>release splunk-otel-collector, namespace splunk-otel"]
    REPO --> UP
  end

  subgraph OBJ["5. Kubernetes objects created"]
    SEC["Secret<br/>HEC token (secret.create=true)"]
    CMA["ConfigMap<br/>...-otel-agent"]
    CMC["ConfigMap<br/>...-otel-k8s-cluster-receiver"]
    DS["DaemonSet<br/>...-agent (1 pod per node)"]
    DCR["Deployment<br/>...-k8s-cluster-receiver (1 pod per cluster)"]
  end

  ENV --> VB
  ENV --> VP
  EFF --> UP
  UP --> SEC
  UP --> CMA
  UP --> CMC
  UP --> DS
  UP --> DCR
```

`--prometheus` is the only switch that adds the second values file; without it the collector never
touches Prometheus.

---

## 2. Logs — where they are collected from and where they are sent

```mermaid
flowchart LR
  subgraph SRC["Collected from (node-local / API)"]
    LC["container stdout+stderr<br/>/var/log/pods/*/*/*.log"]
    LJ["host systemd journal<br/>/var/log/journal<br/>ALL units + kernel"]
    LA["kube-apiserver audit<br/>/var/log/kubernetes/audit/*.log"]
    KE["Kubernetes Events<br/>from the kube-apiserver"]
  end

  subgraph AG["Agent DaemonSet (per node)"]
    R1["file_log"]
    R2["journald/all"]
    R3["file_log/nkp-audit"]
    PL["pipeline: logs"]
    PH["pipeline: logs/host"]
  end

  subgraph CR["Cluster receiver Deployment (per cluster)"]
    RE["k8s_events"]
    PCL["pipeline: logs"]
  end

  EX["exporter<br/>splunk_hec/platform_logs<br/>index = k8s_logs"]
  HEC["Splunk Cloud HEC<br/>https://stack.splunkcloud.com:8088<br/>/services/collector/event"]
  IDX["Splunk index: k8s_logs<br/>sourcetypes:<br/>kube:container:NAME<br/>kube:journald:UNIT<br/>kube:kernel<br/>kube:apiserver-audit"]

  LC --> R1 --> PL --> EX
  LJ --> R2 --> PH --> EX
  LA --> R3 --> PH --> EX
  KE --> RE --> PCL --> EX
  EX --> HEC --> IDX
```

---

## 3. Metrics — where they are pulled from and where they are sent

```mermaid
flowchart LR
  subgraph MSRC["Pulled (scraped) from"]
    S1["node kernel<br/>/proc + /sys via the /hostfs mount"]
    S2["kubelet https://nodeIP:10250<br/>stats/summary + cAdvisor"]
    S3["Kubernetes API<br/>cluster objects and state"]
    S4["the collector itself<br/>localhost:8889"]
    S5["NKP Prometheus /federate<br/>only with --prometheus"]
  end

  subgraph AG["Agent DaemonSet (per node)"]
    A1["host_metrics"]
    A2["kubelet_stats"]
    A3["prometheus/agent"]
    PMA["pipeline: metrics"]
  end

  subgraph CR["Cluster receiver Deployment (per cluster)"]
    C1["k8s_cluster"]
    C2["prometheus/nkp (optional)"]
    PMC["pipeline: metrics"]
  end

  EX2["exporter<br/>splunk_hec/platform_metrics<br/>index = k8s_metrics"]
  HEC2["Splunk Cloud HEC<br/>:8088/services/collector/event"]
  IDX2["Splunk index: k8s_metrics<br/>metrics-type index"]

  S1 --> A1 --> PMA
  S2 --> A2 --> PMA
  S4 --> A3 --> PMA
  S3 --> C1 --> PMC
  S5 --> C2 --> PMC
  PMA --> EX2
  PMC --> EX2
  EX2 --> HEC2 --> IDX2
```

---

## 4. Which value wins — configuration precedence

Later wins. Helm merges maps deeply but **replaces lists**, which is why the Prometheus fragment must
repeat `k8s_cluster` in the `metrics` pipeline, and why the `logs/host` pipeline must list both receivers.

```mermaid
flowchart LR
  D["1. chart defaults<br/>chart 0.160.0"] --> B["2. values.example.yaml<br/>base lab"]
  B --> P["3. values-prometheus.example.yaml<br/>only with --prometheus"]
  P --> E["4. effective config<br/>written into the ConfigMaps the pods mount"]
```

`local.env` is not a layer of its own — `render.sh` substitutes its values **into** file 2 (and 3)
before Helm ever sees them.

---

## 5. Troubleshooting flow — "nothing is showing up in Splunk"

```mermaid
flowchart TB
  Q0["No data in Splunk?"] --> Q1{"collector pods Ready?"}
  Q1 -->|"no"| F1["kubectl -n splunk-otel get pods + logs<br/>startup/CrashLoop: config schema errors<br/>(e.g. config.config.scrape_configs)"]
  Q1 -->|"yes"| Q2{"'Dropping data' in the logs?"}
  Q2 -->|"yes"| E1["400 Incorrect index<br/>add the index to the HEC token's allowed list"]
  Q2 -->|"yes"| E2["403 Forbidden<br/>wrong or stale token, restart the DaemonSet"]
  Q2 -->|"yes"| E3["x509 certificate error<br/>set splunkPlatform.insecureSkipVerify true"]
  Q2 -->|"no"| Q3{"per-receiver counters growing?<br/>port-forward :8889 / :8899"}
  Q3 -->|"kubelet_stats stays 0"| K1["kubelet cert has no IP SAN<br/>kubelet_stats.insecure_skip_verify true"]
  Q3 -->|"prometheus/nkp stays 0"| P1["wait over one scrape interval<br/>check match[] and the target"]
  Q3 -->|"all growing"| OK["data IS being sent<br/>search index=k8s_logs / k8s_metrics in the Splunk UI"]
```

The two questions that catch almost everything: **are the pods Ready?**, and **do the per-receiver
counters grow?** ("no drops" alone does not mean healthy — a receiver that fails to *scrape* emits
nothing and drops nothing).

---

## See also

- [`README.md`](README.md) — the step-by-step lab, the values with WHY, and the troubleshooting matrix.
- [`values.example.yaml`](values.example.yaml) — every value documented (WHAT/DEFAULT/OURS/WHY/BREAKS).
- [`values-prometheus.example.yaml`](values-prometheus.example.yaml) — the Prometheus federation add-on.
