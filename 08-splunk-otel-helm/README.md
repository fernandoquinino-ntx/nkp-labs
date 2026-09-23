# Lab 08 — Install the Splunk OpenTelemetry Collector with Helm (no catalog)

**Learn:** deploy Splunk's OpenTelemetry Collector chart with **plain `helm`** (no NKP catalog, no
`AppDeployment`), understand **what every setting does and why**, ship **logs *and* metrics** from a
cluster to Splunk over **HEC**, verify it, and **troubleshoot** it when it breaks.

> Validated against chart **`splunk-otel-collector` 0.160.0** on an NKP cluster (management +
> managed), sending to Splunk Cloud. The whole point of this lab is the **annotated**
> [`values.example.yaml`](values.example.yaml) — read it line by line.

---

## 0. What you will build

One Helm release installs **two** workloads:

```
                        your cluster
  ┌───────────────────────────────────────────────────────────────┐
  │ DaemonSet  <release>-agent            (one pod per node)       │
  │   reads NODE-LOCAL sources:                                    │
  │     • /var/log/pods/*            → container logs              │
  │     • the systemd journal        → host logs (+ kernel)        │──┐
  │     • /var/log/kubernetes/audit  → kube-apiserver audit        │  │
  │     • /proc,/sys (host)          → host metrics                │  │
  │     • kubelet :10250             → pod/container metrics       │  │
  ├───────────────────────────────────────────────────────────────┤  │  HEC
  │ Deployment <release>-k8s-cluster-receiver (one pod per cluster)│  ├──► Splunk
  │     • the Kubernetes API          → cluster metrics + events   │  │  index k8s_logs
  └───────────────────────────────────────────────────────────────┘  │  index k8s_metrics
                                                                      │
  Splunk Cloud  https://<stack>.splunkcloud.com:8088/services/collector/event
```

Nothing here touches Loki or NKP's Fluent Bits — the collector reads the **same node sources** in
parallel (“dual-ship”).

---

## 1. Concepts in 2 minutes (if you have never used Splunk)

| Term | What it is |
|---|---|
| **HEC** | *HTTP Event Collector* — Splunk's HTTPS ingest API, `https://<stack>.splunkcloud.com:8088/services/collector/event` |
| **HEC token** | a UUID credential sent in the header `Authorization: Splunk <token>` (not your login) |
| **Index** | the bucket data lands in. Two **types**: **events** (logs) and **metrics** (numbers). Metrics *cannot* go into an events index → that is why we use two indexes |
| **Selected Allowed Indexes** | a per-token allow-list. Sending to any other index returns `HTTP 400 {"text":"Incorrect index"}` and the collector **silently drops the data**. ⚠ the #1 failure in this lab |
| **SPL** | Splunk's search language, used in the web UI |
| **ACS** | Splunk Cloud's config REST API (`admin.splunk.com`) — optional; may be blocked by IP allow-list, then use the UI |

**TLS gotcha:** the Splunk Cloud HEC endpoint serves `CN=SplunkServerDefaultCert` (issuer
`SplunkCommonCA`), which is **not publicly trusted** → we must set `insecureSkipVerify: true` (or, in
production, install the Splunk CA).

**Splunk Cloud gotcha:** the management REST port `:8089` is **closed** → you verify with the **web
UI**, not with a script.

---

## 2. Files

| File | What |
|---|---|
| [`values.example.yaml`](values.example.yaml) | **the star** — annotated Helm values (every key has a `# WHY:`) |
| [`values-prometheus.example.yaml`](values-prometheus.example.yaml) | optional add-on values file: federate NKP's Prometheus (added by `install.sh --prometheus`) |
| [`namespace.yaml`](namespace.yaml) | the namespace (`${OTEL_NAMESPACE}`) so `scripts/apply.sh`/`cleanup.sh` work |
| [`install.sh`](install.sh) | render → `helm repo add` → `helm upgrade --install` (`--dry-run`, `--apply`, `--template`) |
| [`verify.sh`](verify.sh) | end-to-end check: pods, drops, **per-receiver counters**, HEC probe, SPL |
| [`uninstall.sh`](uninstall.sh) | remove the release (and optionally the namespace) |

---

## 3. Prerequisites

**Tools:** `kubectl`, `helm` (v3). `curl` for the HEC probe. Your machine must reach the cluster; the
**cluster nodes** must reach your Splunk HEC endpoint (outbound `:8088`).

**Before you start — three common traps:**

- **Point kubectl at the right cluster.** The lab uses your ambient kubeconfig:
  `kubectl config current-context`. If it is unset, `export KUBECONFIG=<your kubeconfig>` first —
  otherwise every check reports “nothing found”.
- **Do not run the lab with `sudo`.** It creates `rendered/` as your user; a `sudo` run leaves
  root-owned files and the next `render.sh` fails with `rm: cannot remove … Permission denied`
  (fix: `sudo rm -rf rendered`).
- **Name clash:** the lab installs the Helm release `splunk-otel-collector` in namespace
  `splunk-otel`. If the collector is **already installed** there (e.g. via the NKP catalog /
  AppDeployment), either remove that first or pick different values — `helm` refuses to reuse a
  release name (`cannot re-use a name that is still in use`), and two collectors on the same nodes
  would double-ship.

**Splunk side** (do this first — the collector is useless without it):

1. Create the indexes in the Splunk UI:
   **Settings → Indexes → New Index** → `k8s_logs` (*Events*) and `k8s_metrics` (*Metrics*).
2. Allow them on the HEC token:
   **Settings → Data inputs → HTTP Event Collector → (your token) → Edit →
   Selected Allowed Indexes → add `k8s_logs` and `k8s_metrics` → Save.**
3. Prove it from your machine:
   ```bash
   TOKEN=<your-hec-token>
   URL=https://<stack>.splunkcloud.com:8088/services/collector/event
   curl -sk -H "Authorization: Splunk $TOKEN" -d '{"event":"x","index":"k8s_logs"}'    "$URL"
   curl -sk -H "Authorization: Splunk $TOKEN" -d '{"event":"m","index":"k8s_metrics"}' "$URL"
   # both must print {"text":"Success","code":0}
   # {"text":"Incorrect index"} => step 2 is not done (or the index name is wrong)
   ```
   (`-k` is required here — see the TLS gotcha above.)

---

## 4. Step 1 — configure and render

```bash
cp local.env.example local.env      # gitignored
$EDITOR local.env                   # set the OTEL_* and SPLUNK_* values
./scripts/render.sh 08-splunk-otel-helm
ls rendered/08-splunk-otel-helm/    # namespace.yaml + values.example.yaml (with YOUR values substituted)
```

The variables this lab uses:

| Variable | Example | Notes |
|---|---|---|
| `OTEL_NAMESPACE` | `splunk-otel` | where the collector runs |
| `OTEL_RELEASE` | `splunk-otel-collector` | the Helm release name |
| `CHART_VERSION` | `0.160.0` | **pin** the chart version |
| `SPLUNK_CLUSTER_NAME` | `dc1-nkp-cl01` | becomes `k8s.cluster.name`; **must be unique per cluster** |
| `SPLUNK_HEC_ENDPOINT` | `https://prd-p-xxxxx.splunkcloud.com:8088/services/collector/event` | the HEC URL |
| `SPLUNK_HEC_TOKEN` | `<hec-token>` | **secret** — lives only in `local.env` (gitignored) |
| `SPLUNK_INDEX` | `k8s_logs` | events index — **must be token-allowed** |
| `SPLUNK_METRICS_INDEX` | `k8s_metrics` | metrics index — **must be token-allowed** |
| `PROMETHEUS_ENABLED` | `1` (or unset) | optional: also ship NKP's Prometheus metrics — same as passing `--prometheus` |

---

## 5. Step 2 — the settings **and why** (the point of this lab)

Open [`values.example.yaml`](values.example.yaml). Every block has a `# WHY:`. Summary:

| Setting | Value you set | **Why it exists / what breaks without it** |
|---|---|---|
| `clusterName` | your cluster name | Attached as `k8s.cluster.name` to every record → filter per cluster. Also **required non-empty** by the chart schema. Two clusters with the same name look like one stream. |
| `splunkPlatform.endpoint` | the HEC URL | Where data is sent (`:8088/services/collector/event`). |
| `splunkPlatform.token` | the HEC token | Authenticates to HEC. The chart **creates a Secret** from it and injects it as an env var. Keep it out of git. |
| `splunkPlatform.index` | `k8s_logs` | The events index for logs. **Must be token-allowed and non-empty** — else `400 Incorrect index` and a **silent drop**. |
| `splunkPlatform.metricsEnabled` + `metricsIndex` | `true` + `k8s_metrics` | Metrics need a **metrics-type** index; `metricsIndex` is required when metrics are on. |
| `splunkPlatform.insecureSkipVerify` | `true` | The Cloud HEC cert (`SplunkCommonCA`) is not publicly trusted → strict TLS fails everywhere. |
| `logsCollection.containers.enabled` | `true` | Container stdout/stderr (`/var/log/pods/*`). |
| `logsCollection.journald.units` | `[]` (empty) | The chart builds **one journald receiver per listed unit** — there is **no “all units”** option, so a short list silently misses host services. Empty + the custom `journald/all` receiver = full host parity. |
| — `agent.config.receivers.journald/all` | no `units` | One receiver, **no filter** = the **whole** journal (all units **and** kernel entries). |
| `logsCollection.extraFileLogs.file_log/nkp-audit` | audit path | kube-apiserver audit files. The map **key is the receiver name** and the chart renamed `filelog`→`file_log`, so it must be `file_log/...`. |
| `agent.extraVolumes/Mounts` | `/var/log/kubernetes/audit` | Workers have no audit dir — `DirectoryOrCreate` avoids crashes. |
| `agent.config.receivers.kubelet_stats.insecure_skip_verify` | `true` | The kubelet cert (`:10250`) has **no IP SAN** → kubelet metrics return **0 points with no drops**. This is the sneakiest failure. |
| `agent.config.service.pipelines.logs/host.receivers` | `[file_log/nkp-audit, journald/all]` | Lists are **replaced**, not merged — wiring the catch-all receiver means re-listing the audit one. |
| `clusterReceiver.enabled` | `true` | One **Deployment** per cluster reading the Kubernetes API (cluster metrics + Events). Needed for cluster-wide metrics/events. |
| `agent.resources`, `clusterReceiver.resources` | small | Right-size the per-node agent and the single cluster receiver. |

Why **DaemonSet + Deployment**? The agent reads **node-local** data (needs one pod per node); the
cluster receiver reads the **Kubernetes API** (needs exactly one pod per cluster). If you lose one,
you lose exactly that data subset.

### How metrics are actually collected — and is Prometheus involved?

The collector **pulls (scrapes)** on a fixed interval (`collection_interval: 10s`); nothing is pushed
unless an app sends OTLP to the agent. Three metric sources feed **one** pipeline → **one** exporter.

**Agent — DaemonSet, one pod per node (node-local sources):**

| Receiver | Pulls from | Reaches it via | Metric families |
|---|---|---|---|
| `host_metrics` | the **node kernel** | scrapes `/proc` + `/sys` via the `/hostfs` mount (`root_path`) | CPU, memory, disk I/O, filesystem, load, network, paging, processes (`system.*`) |
| `kubelet_stats` | **kubelet** `https://${K8S_NODE_IP}:10250` | service-account auth; reads `/stats/summary` + cAdvisor | `k8s.pod.*`, `k8s.container.*`, `k8s.node.*` usage |
| `prometheus/agent` | **the collector itself** | scrapes its own `localhost:8889/metrics` | `otelcol_*` health/throughput |

**Cluster receiver — Deployment, one pod per cluster (cluster-wide source):**

| Receiver | Pulls from | Result |
|---|---|---|
| `k8s_cluster` | the **Kubernetes API** (watch) | `k8s.node.*`, `k8s.pod.phase`, `k8s.deployment.*`, `k8s.daemonset.*`, `k8s.statefulset.*`, `k8s.namespace.*`, `k8s.cluster.*` … |
| `k8s_events` / `k8s_objects` | Kubernetes API | Events / objects — sent as **logs** to `k8s_logs`, not metrics |

```
receivers ─► memory_limiter ─► batch ─► resource_detection ─► resource ─► k8s_attributes/metrics
   host_metrics + kubelet_stats + otlp   ─────────────► splunk_hec/platform_metrics ─► index k8s_metrics
   k8s_cluster (cluster receiver)        ─────────────► (same exporter)
```

> **Is it from Prometheus?** **No — not by default.** The only receivers with “prometheus” in the name
> (`prometheus/agent`, `prometheus/k8s_cluster_receiver`) scrape **the collector itself**, not your
> workloads. With the default values the collector does **not** scrape **kube-state-metrics**,
> **node-exporter**, application `/metrics`, or pods/services carrying `prometheus.io/scrape`
> annotations (`autodetect.prometheus: false`, `agent.discovery.enabled: false`, and
> `receiver_creator.receivers: null`). To actually ship NKP's Prometheus metrics, see
> **“Sending Prometheus metrics (NKP's kube-prometheus-stack)”** just below.

If you *do* want Prometheus endpoints, enable it explicitly — three options:

```yaml
# 1) easiest: scrape any pod/service that carries prometheus.io/scrape: "true"
autodetect:
  prometheus: true

# 2) the chart's discovery mode (receiver_creator + k8s_observer auto-create receivers)
agent:
  discovery:
    enabled: true

# 3) fully manual: add a receiver and attach it to the metrics pipeline
agent:
  config:
    receivers:
      prometheus/myapp:
        config:
          scrape_configs:
            - job_name: myapp
              static_configs: [{ targets: ["myapp.monitoring.svc:9090"] }]
    service:
      pipelines:
        metrics:
          # lists are REPLACED, not merged -> re-list the defaults!
          receivers: [host_metrics, kubelet_stats, otlp, prometheus/myapp]
```

⚠ If you run **kube-prometheus-stack** (Prometheus Operator + `ServiceMonitor`s), those metrics live
in *that* Prometheus — the OTel collector does **not** read `ServiceMonitor`s, so it will not see
them unless you scrape the endpoints explicitly (option 3) or use a Prometheus remote-write path.

You can always discover the exact metric names that actually landed:

```
| mcatalog values(metric_name) WHERE index=k8s_metrics
```

### Sending Prometheus metrics (NKP's kube-prometheus-stack)

NKP ships **kube-prometheus-stack** in namespace `kommander`: Prometheus (`v3.11.0`), `kube-state-metrics`,
`node-exporter` (7 pods), `alertmanager`, `grafana`, `prometheus-operator`, plus **28 ServiceMonitors**.
Those `ServiceMonitor`s are consumed by *that* Prometheus — the OTel collector does **not** read them.

**Recommended: federate.** Point one OTel receiver at Prometheus's `/federate` endpoint, which returns
the *current series* Prometheus already holds — including targets the collector could never scrape
itself (etcd/apiserver mTLS, auth'd endpoints, node-exporter, KSM). No ServiceMonitor replication, no
credentials to copy.

**Run it in the cluster receiver, never the agent.** The agent is a DaemonSet (one pod per node) — it
would scrape the same Prometheus on every node and duplicate every series N times. The cluster
receiver is one pod per cluster. That is why the block lives under `clusterReceiver.config`.

**Scope matters — NKP's Prometheus is big.** Measured on the lab (`/federate`, one scrape):

| `match[]` selector | series | payload |
|---|---|---|
| *default* `{job=~"kommander.*\|nkp-.*\|opencost\|centralized-.*\|…",__name__!~".*_bucket"}` | ~18,000 | 9.5 MB |
| `{__name__=~"kube_.*\|node_.*",__name__!~".*_bucket"}` | ~44,000 | 24 MB |
| `{__name__!~".*_bucket"}` (all, no histograms) | ~192,000 | 99 MB |
| `{__name__=~".+"}` (**everything**) | **~457,000** | **218 MB** |

Splunk metrics are billed per datapoint, and "everything" is 218 MB **per scrape** — so the lab
defaults to the NKP-platform scope (metrics you don't already get from `kubelet_stats` /
`k8s_cluster`), ~18k series at one scrape/minute. The whole thing lives in
[`values-prometheus.example.yaml`](values-prometheus.example.yaml) and is added only when you run
`./08-splunk-otel-helm/install.sh --prometheus` (or set `PROMETHEUS_ENABLED=1`). Edit the `match[]`
line there to widen or narrow it (it lives in the file, not `local.env`, because `|`/quotes don't
survive the placeholder renderer).

```yaml
clusterReceiver:
  enabled: true
  config:
    receivers:
      prometheus/nkp:
        config:                      # <- schema: config.scrape_configs
          scrape_configs:
            - job_name: nkp-prometheus-federate
              scrape_interval: 60s
              scrape_timeout: 50s
              metrics_path: /federate
              params:
                'match[]':
                  - '{job=~"kommander.*|nkp-.*|opencost|centralized-.*|kubefed-.*|kubetunnel-.*|loggingstack-.*|dex-.*|kube-prometheus-stack-.*|karma|grafana-logging",__name__!~".*_bucket"}'
              static_configs:
                - targets: [kube-prometheus-stack-prometheus.kommander.svc:9090]
    service:
      pipelines:
        metrics:
          receivers: [k8s_cluster, prometheus/nkp]   # lists are REPLACED — keep k8s_cluster!
  resources:                          # parsing tens of thousands of series needs headroom
    requests: {cpu: 200m, memory: 512Mi}
    limits:   {cpu: 1000m, memory: 1Gi}
```

> ⚠️ **Schema gotcha:** it is `config.scrape_configs`, **not** `config.config.scrape_configs`. The
> doubled form only applies **inside `receiver_creator`** (where `config:` nests one more level); as a
> standalone receiver it fails at startup with
> `'config' prometheus receiver: … field config not found in type config.plain` (CrashLoopBackOff).

**Verify:**

```bash
# the federation receiver must be accepting points (wait >1 scrape interval!)
R=$(kubectl -n splunk-otel get pod -o name | grep cluster-receiver | cut -d/ -f2)
kubectl -n splunk-otel port-forward pod/$R 18899:8899 &
curl -s localhost:18899/metrics | grep 'prometheus/nkp' | grep -v '^#'
#   otelcol_receiver_accepted_metric_points{receiver="prometheus/nkp"}  <growing>
#   otelcol_exporter_send_failed_metric_points  -> absent/0

# and in Splunk:
| mcatalog values(metric_name) WHERE index=k8s_metrics | grep -v "k8s\." | head -40
| mstats count WHERE index=k8s_metrics metric_name="kommander_*" span=1m
```

Observed on the lab: `prometheus/nkp` ≈ **73k points** in ~4 min, cluster receiver memory ≈ **477 MiB**
(limit 1 GiB), **0** export failures.

> Reached via the NKP platform playbook: `nkp-deployer/configure/splunk/GUIDE.md` §3.2.



---

## 6. Step 3 — install

```bash
# preview (renders the chart, changes nothing)
./08-splunk-otel-helm/install.sh

# install / upgrade
./08-splunk-otel-helm/install.sh --apply

# ...and ALSO ship NKP's Prometheus metrics (adds the federation values file)
./08-splunk-otel-helm/install.sh --apply --prometheus
```

Prometheus is **off unless you ask for it**: `--prometheus` (or `PROMETHEUS_ENABLED=1` in
`local.env`) merges the second values file [`values-prometheus.example.yaml`](values-prometheus.example.yaml);
`--no-prometheus` forces it off. See “Sending Prometheus metrics” below for the cost of each scope.

Under the hood `install.sh` runs the equivalent of:

```bash
helm repo add splunk-otel-collector-chart https://signalfx.github.io/splunk-otel-collector-chart
helm repo update
helm -n "$OTEL_NAMESPACE" upgrade --install "$OTEL_RELEASE" \
  splunk-otel-collector-chart/splunk-otel-collector \
  --version "$CHART_VERSION" --create-namespace \
  -f rendered/08-splunk-otel-helm/values.example.yaml \
  -f rendered/08-splunk-otel-helm/values-prometheus.example.yaml   # only with --prometheus
```

**No Helm release state?** use the GitOps-style path (renders with Helm, applies with kubectl):

```bash
./08-splunk-otel-helm/install.sh --template      # helm template | kubectl apply -f -
```

> `helm template` also lets you **inspect** exactly what the chart generates — e.g.
> `helm template ... --show-only templates/configmap-agent.yaml`.

---

## 7. Step 4 — verify

```bash
./08-splunk-otel-helm/verify.sh
```

It checks the release/pods, greps for **`Dropping data`**, prints the collector's **per-receiver
counters**, probes HEC for both indexes with your token, and prints the SPL to run.

Manual equivalent:

```bash
kubectl -n splunk-otel get ds,deploy,pods
kubectl -n splunk-otel logs -l app=splunk-otel-collector --tail=2000 | grep -c 'Dropping data'   # 0

# THE counter check (the app must accept records/points and fail to send nothing)
P=$(kubectl -n splunk-otel get pod -l app=splunk-otel-collector -o jsonpath='{.items[0].metadata.name}')
kubectl -n splunk-otel port-forward pod/$P 18889:8889 &
curl -s localhost:18889/metrics | grep -E 'accepted_log_records|accepted_metric_points|send_failed' | grep -v '^#'
```

Then in the **Splunk UI**:

```
index=k8s_logs earliest=-15m | stats count by k8s.cluster.name
index=k8s_logs sourcetype=kube:journald:* earliest=-15m | head 20
index=k8s_logs sourcetype=kube:kernel   earliest=-15m | head 20
| mcatalog values(metric_name) WHERE index=k8s_metrics
| mstats avg(_value) WHERE index=k8s_metrics metric_name="k8s.node.condition_ready" span=1m
```

---

## 8. Step 5 — troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pods `Ready`, but nothing in Splunk | index not on the token's allowed list | add it (Step 3.2); the collector **silently drops** |
| `HTTP 400 "Incorrect index"` in the logs | same as above (or wrong index name) | fix the token / `splunkPlatform.index` |
| `HTTP 403 "Forbidden"` | wrong/rotated token in the running pod | fix the token, then `kubectl -n splunk-otel rollout restart ds/<release>-agent` |
| `x509: certificate signed by unknown authority` | Splunk HEC cert is `SplunkCommonCA` | `splunkPlatform.insecureSkipVerify: true` |
| `kubelet_stats` accepted **0**, but logs and other metrics are fine, **no** `Dropping data` | kubelet cert has **no IP SAN** | `agent.config.receivers.kubelet_stats.insecure_skip_verify: true` |
| Metrics from an app / kube-state-metrics never appear | the collector does not scrape Prometheus targets by default | enable `autodetect.prometheus`, `agent.discovery`, or federation (see “Sending Prometheus metrics”) |
| Cluster receiver **CrashLoopBackOff** with `field config not found in type config.plain` | `prometheus/*` receiver nested as `config.config.scrape_configs` | use `config.scrape_configs` (the doubled form is only for `receiver_creator`) |
| `prometheus/nkp` accepted **0** points | scraped too early, or the `match[]`/target is wrong | wait >1 scrape interval; check `kubectl -n splunk-otel logs -l app=splunk-otel-collector \| grep -i scrape` |
| `warn … failed to fetch container metrics … empty containerID` | a container (e.g. `kube-bench`/`pause`) exposes no containerID, so `container.id` enrichment is skipped | **benign** — ignore; the receiver keeps working |
| `helm upgrade` error `minLength: got 0, want 1` | empty `splunkPlatform.index` | always set a real index (the schema has no “omit index” mode) |
| `no matches for kind` / chart not found | repo not added/updated | `helm repo add … && helm repo update`; check `--version` |
| `cannot re-use a name that is still in use` | a release with the same name already exists | uninstall it first, or change `OTEL_NAMESPACE`/`OTEL_RELEASE` (see “Before you start”) |
| `render.sh: Permission denied` / `rm: cannot remove rendered/…` | the lab was run once with `sudo` | `sudo rm -rf rendered` and re-run **without** `sudo` |
| `kubectl` finds nothing / `current-context is not set` | kubectl not pointed at the cluster | `kubectl config use-context …` or `export KUBECONFIG=…` |
| `helm` says release exists but nothing runs | wrong namespace / release name | `helm -n <ns> list -a`; use the same `-n`/release as install |
| Managed cluster never updates (if you later wrap this in an AppDeployment) | Kommander snapshots the override ConfigMap | bump the AppDeployment spec — see the nkp-deployer guide |

**The golden rule:** **“no drops” does not mean “working”.** A receiver that fails to *scrape*
(kubelet, a missing log path, a bad index name on one pipeline) produces **nothing** and drops
**nothing**. Always pair the drop check with the **per-receiver counters** in Step 4.

Detailed diagnostics:

```bash
# what is the collector actually complaining about?
kubectl -n splunk-otel logs -l app=splunk-otel-collector --tail=300 | grep -iE 'error|drop|x509|index'
# the kubelet trap, specifically:
kubectl -n splunk-otel logs -l app=splunk-otel-collector | grep -i 'IP SAN'
# what did we send to the cluster?
helm -n splunk-otel get values "$OTEL_RELEASE" | grep -vE 'token'      # effective values (token hidden)
kubectl -n splunk-otel get cm <release>-otel-agent -o jsonpath='{.data.relay}' | head -60
```

---

## 9. Step 6 — day-2

```bash
# change the index/endpoint/values: edit local.env, re-render, re-apply
./08-splunk-otel-helm/install.sh --apply

# change the token (the chart re-creates its Secret; pods must restart to pick up the env var)
kubectl -n splunk-otel rollout restart ds/"$OTEL_RELEASE"-agent

# enable/disable metrics: set splunkPlatform.metricsEnabled + clusterReceiver.enabled, re-apply
# upgrade the chart: set a new CHART_VERSION, re-run install.sh --apply
```

## 10. Cleanup

```bash
./08-splunk-otel-helm/uninstall.sh            # remove the Helm release
./08-splunk-otel-helm/uninstall.sh --purge    # ... and delete the namespace
./scripts/cleanup.sh 08-splunk-otel-helm      # remove the namespace manifest (if applied)
```

---

## 11. Reference

- The chart: <https://github.com/signalfx/splunk-otel-collector-chart> ·
  <https://signalfx.github.io/splunk-otel-collector-chart>
- Full playbook + deep troubleshooting (same config, plus the NKP catalog path):
  `nkp-deployer/configure/splunk/GUIDE.md`, `runbooks/splunk-otel.md`, `runbooks/metrics.md`.
- Splunk HEC docs: *Getting data in → HTTP Event Collector*.
