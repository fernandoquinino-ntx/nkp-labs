# Lab 03 — expose Apache with a LoadBalancer (MetalLB)

**Learn:** a `Service` with `type: LoadBalancer` gets an **external IP** from your cluster's LB
implementation (MetalLB on bare metal), so the app is reachable from outside the cluster.

## What it creates
| File | Object |
|---|---|
| `deployment.yaml` | ConfigMap `apache-html` + Deployment `apache` (2 × `httpd:2.4`) |
| `service-lb.yaml` | Service `apache-lb` — **type: LoadBalancer** |

## Run
```bash
NS="$(grep ^NAMESPACE= local.env | cut -d= -f2)"; NS=${NS:-labs}

./scripts/apply.sh 03-apache-metallb
kubectl -n "$NS" get svc apache-lb -w        # wait for EXTERNAL-IP
```

## Use it
```bash
IP="$(kubectl -n "$NS" get svc apache-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"
curl "http://$IP/"
```
On MetalLB **L2 mode**, the IP lives on **one node**; traffic is answered there. The IP must come from an
`IPAddressPool` in your MetalLB config (`kubectl get ipaddresspools -A`).

## Pick a specific IP (optional)
Add the annotation shown in `service-lb.yaml`:
```yaml
annotations:
  metallb.io/loadBalancerIPs: <a-free-ip-from-your-pool>
```

## Troubleshooting
- `EXTERNAL-IP: <pending>` forever → no MetalLB / no free IP in the pool.
- IP assigned but `curl` hangs → check the node network / ARP (L2 advertisement) and that the pool is
  advertised (`kubectl get l2advertisements -A`).

## Cleanup
```bash
./scripts/cleanup.sh 03-apache-metallb
```
