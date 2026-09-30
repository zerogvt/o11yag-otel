# Making the Error rate tile move

On a healthy stack the **Error rate** tile sits at 0%. This is how to push it
off zero: which failure to cause, what it costs, and how to put it back.

**What counts.** The tile is the share of `o11yag.tasks` with `outcome=error`,
and only the orchestrator emits that metric. A ticket ends in `error` in exactly
two ways:

1. the orchestrator's call to a worker raises (connection refused, timeout,
   HTTP 5xx) — `handle()` in `orchestrator/app.py`;
2. the action worker cannot reach the MCP server and returns `outcome=error` —
   `act()` in `action-worker/app.py`.

`blocked` (the approval gate stopping ORD-1004), `escalated` and `incomplete` are
**not** errors and never show up in this tile. Losing LiteLLM does not reliably
produce errors either — classification falls back to keywords instead of failing.

**Set the dashboard timeframe to _Last 30 minutes_.** The tile divides over the
whole timeframe, and loadgen sends one ticket every 20 s, so five minutes of
errors inside a 24 h window rounds to nothing.

> Recipe 1 was run once on 2026-09-23 (see its section). Recipes 2 and 3 have
> not been run yet, and their percentages come from the loadgen weights in
> `loadgen/tickets.py`, not from a measurement.

---

## Recipe 1 — Take the CRM away (recommended)

The cleanest demo: only order actions fail, so the tile lands at a believable
partial rate instead of jumping to most of the traffic.

```
kubectl scale deployment/o11yag-mcp-crm -n o11yag-otel --replicas=0
```

Leave loadgen running for 5–10 minutes.

**What you should see**

| Where | What |
|---|---|
| Error rate tile | roughly **25%** — 6 of the 23 weighted tickets are order actions |
| Ticket volume by outcome | an `error` series appears; `blocked` disappears, because ORD-1004 never reaches the gate |
| `action_worker.agent` span | `error.kind = mcp_unavailable` |
| Orchestrator audit record | `o11yag.ticket.handled` with `outcome = error`, `intent = order_action` |

```
fetch logs, from: now()-30m
| filter audit.event.type == "o11yag.ticket.handled" and audit.outcome == "error"
| summarize tickets = count(), by: {audit.intent}
```

**Measured (2026-09-23, 7 minutes down).** 15 tickets arrived while mcp-crm
was down: 2 `error`, 1 `blocked` (most likely a ticket already in flight at the moment of
the scale-down), 5 `escalated`, 7 `ok`. That is 13% inside the
outage, not the ~25% the weights suggest, because a sample that small follows
whatever loadgen happened to pick. The tile read **4.8%** (2 of 42) over
_Last 30 minutes_, because the healthy 23 minutes before the outage dilute it.
Leave it down longer if you want a bigger number.

Put it back:

```
kubectl scale deployment/o11yag-mcp-crm -n o11yag-otel --replicas=1
```

---

## Recipe 2 — Take the knowledge worker away

Every policy question fails at the orchestrator's hop. Loud and immediate —
connection refused, no waiting on a timeout.

```
kubectl scale deployment/o11yag-knowledge-worker -n o11yag-otel --replicas=0
```

**What you should see:** the tile at roughly **65%** (15 of 23 weighted tickets
are questions), `delegate_to_worker` spans marked failed with a connection error,
and the orchestrator log printing `worker call failed` with a traceback.

Put it back:

```
kubectl scale deployment/o11yag-knowledge-worker -n o11yag-otel --replicas=1
```

The Qdrant collection is on a volume, so the worker comes back without
reseeding.

---

## Recipe 3 — Make the orchestrator impatient

Nothing is down; the orchestrator just stops waiting. This is what a real
latency regression looks like from the caller's side, which makes it the most
realistic of the three and the least predictable.

`orchestrator/k8s/o11yag-orchestrator.yaml`:

```yaml
  WORKER_TIMEOUT_S: "2"      # default 300
```

Redeploy, or apply and restart by hand — a ConfigMap change does not roll the
pod on its own (see [`SECURITY-DEMOS.md`](SECURITY-DEMOS.md) §0):

```
kubectl apply -f orchestrator/k8s/o11yag-orchestrator.yaml
kubectl rollout restart deployment/o11yag-orchestrator -n o11yag-otel
kubectl exec deploy/o11yag-orchestrator -n o11yag-otel -- printenv WORKER_TIMEOUT_S
```

**What you should see:** `ReadTimeout` on `delegate_to_worker` spans, and an
error rate that depends entirely on how slow the model is. With `qwen:0.5b` on
CPU most knowledge-worker answers should overrun 2 s; if the tile stays low,
drop the value to `"1"`. Latency tiles stay flat, since the timeout caps them.

Set it back to `"300"` and redeploy.

---

## Resetting

```
kubectl scale deployment/o11yag-mcp-crm deployment/o11yag-knowledge-worker \
  -n o11yag-otel --replicas=1
```

and make sure `WORKER_TIMEOUT_S` is `"300"` again. Re-running `build_deploy.sh`
also restores all three, because it re-applies the manifests with
`replicas: 1`.

The tile will not fall back to 0% until the error window leaves the dashboard
timeframe. That is the arithmetic, not a stuck tile.
