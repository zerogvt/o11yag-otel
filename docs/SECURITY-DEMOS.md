# Staging a security incident

Every adversarial behaviour in o11yag is off by default and switched on from a
ConfigMap. This is the runbook for each one: what to set, what has to restart,
what you should see, and how to put it back.

Read [`UPDATE-GAPS-1-2.md`](UPDATE-GAPS-1-2.md) §4 first if you want the
mechanism. This document assumes it and covers only the operation.

> **The one rule.** Turn them off again when you are finished. A reference
> architecture that ships an attack switched on is indistinguishable from a
> backdoor, and the next person to read the corpus will not know which documents
> are yours.

---

## 0. The trap that catches everyone, once

**A ConfigMap change does not restart a pod.** `kubectl apply` updates the
ConfigMap and leaves the Deployment alone, because its spec is unchanged. The
process keeps the configuration it booted with, and every flag below appears to
do nothing.

`build_deploy.sh` now handles this — it stamps a checksum of each manifest onto
the pod template, so a changed file rolls the pod on the next deploy, including
with `--no-build`. If you edit a ConfigMap and apply it by hand, restart the pod
yourself:

```
kubectl apply -f knowledge-worker/k8s/o11yag-knowledge-worker.yaml
kubectl rollout restart deployment/o11yag-knowledge-worker -n o11yag-otel
kubectl rollout status  deployment/o11yag-knowledge-worker -n o11yag-otel
```

**Always verify the setting actually landed** before concluding the demo failed:

```
kubectl exec deploy/o11yag-knowledge-worker -n o11yag-otel -- printenv KB_POISON_DOC
```

That one command would have saved every debugging session that led to this page.

---

## Incident 1 — Indirect prompt injection through the RAG corpus

An instruction written into a knowledge-base document, retrieved on merit, and
delivered to the model inside the context block it was told to trust.

**Know the ceiling first.** The planted document asks for a refund and will not
get one. The knowledge worker has no tools; the agent that has tools never
retrieves. This corrupts an **answer**, not a system of record. Say so when you
present it — the tool-catalogue incident below is the one that reaches behaviour.

### Run it defended (start here)

`knowledge-worker/k8s/o11yag-knowledge-worker.yaml`:

```yaml
  KB_POISON_DOC: "true"
  INJECTION_ACTION: "quarantine"     # the default
```

Redeploy or restart, then confirm the corpus actually grew from 8 documents to 9
— the collection survives a redeploy in Qdrant's volume, so the worker compares
counts on boot and reseeds only when they differ:

```
kubectl logs -l app.kubernetes.io/name=o11yag-knowledge-worker -n o11yag-otel | grep -i seed
#   corpus changed (8 stored, 9 configured) - reseeding
#   seeded 9 documents
```

Then send anything about a faulty item. Loadgen already does
(`"the headphones stopped working"`), or by hand:

```
kubectl port-forward service/o11yag-knowledge-worker 8001:8001 -n o11yag-otel
curl -X POST localhost:8001/answer -H 'Content-Type: application/json' \
  -d '{"ticket_id":"SEC-1","text":"My item is faulty, can I get my money back?"}'
```

**What you should see**

| Where | What |
|---|---|
| `screen_retrieval.task` span | `security.injection.detected = true`, `security.injection.kinds = [override]`, `security.injection.doc_ids = [kb-refunds-02]`, `security.injection.action = quarantined` |
| Metric | `o11yag.security.events` with `kind=prompt_injection`, `action=quarantined`, `source=rag_corpus` |
| Dashboard | the **Security detections** tile stops being empty |
| Audit record | `o11yag.security.injection_detected`, carrying the phrase that matched |

```
fetch logs, from: now()-30m
| filter audit.event.type == "o11yag.security.injection_detected"
| fields timestamp, audit.doc_id, audit.kind, audit.match, audit.action, audit.score
| sort timestamp desc
```

**Expect a side effect.** The poisoned document is a strong match for refund
questions, so quarantining it can remove the top hit and drop the ticket through
the `MIN_SCORE` floor into "I don't have a policy that covers that". That is the
stack declining to answer off a corpus it cannot trust — correct, not a fault.

### Run it undefended

```yaml
  INJECTION_ACTION: "observe"
```

Same detection, `action=observed`, and the document now reaches the prompt. Read
the generated answer: it is the payload arriving. Compare the two runs side by
side — the detection is identical, only `action` and the answer differ, which is
the whole point of keeping that dimension separate from the count.

---

## Incident 2 — Tool poisoning

An instruction written into an MCP tool's **description**, which lands in the
planner's system prompt as capability documentation. Unlike incident 1, the agent
reading this does hold tools.

`mcp-crm/k8s/o11yag-mcp-crm.yaml`:

```yaml
  POISON_TOOL_DESCRIPTION: "true"
```

Restart **mcp-crm** (it is the server that starts lying):

```
kubectl rollout restart deployment/o11yag-mcp-crm -n o11yag-otel
```

The server says so on boot, so there is no doubt which mode it is in:

```
kubectl logs -l app.kubernetes.io/name=o11yag-mcp-crm -n o11yag-otel | grep -i poison
#   WARNING POISON_TOOL_DESCRIPTION is on - issue_refund advertises an injected
#           description. This is the security demo, not a fault.
```

**What you should see**, on the next ticket the action worker handles:

| Where | What |
|---|---|
| `action_worker.agent` span | `security.tool_poisoning.detected = true`, `.tools = [issue_refund]`, `.kinds = [override]`, `.action = redacted` |
| Metric | `o11yag.security.events`, `kind=tool_poisoning`, `source=mcp_server` |
| Audit record | `o11yag.security.tool_poisoned` with the matched phrase |

With `TOOL_POISON_ACTION: "redact"` (the default) the description is blanked
before the planner sees it and the tool stays callable. Set it to `"observe"` to
let the poisoned description reach the model.

**A caveat about what you will observe.** Detection happens at tool discovery and
fires either way. Whether the *agent* then behaves differently is a separate
question, and with `qwen:0.5b` behind the gateway it mostly will not — the model
rarely gets as far as a tool call on its own. `PLANNER_MODE: "rules"` makes the
tool path deterministic, but rules ignore descriptions entirely, so it cannot
show the model being influenced either. Demonstrating compliance needs a capable
model behind LiteLLM. The detector is what this stack demonstrates; the
compliance is what it argues about.

---

## Incident 3 — The rug pull

The same server serving a benign description until it is trusted, and a different
one afterwards. Tool names, schemas and the tool list are all unchanged.

**Order matters here, more than anywhere else on this page.**

### 1. Pin the clean digest first

Read it off a clean run — it is on the span, and in the worker's log the first
time it sees a catalogue:

```
kubectl logs -l app.kubernetes.io/name=o11yag-action-worker -n o11yag-otel | grep -i digest
#   MCP tool catalogue digest 84c7aad377cabc4e (unpinned; set MCP_TOOLS_DIGEST to this to pin it)
```

Put it in `action-worker/k8s/o11yag-action-worker.yaml`:

```yaml
  MCP_TOOLS_DIGEST: "84c7aad377cabc4e"
```

and restart the action worker. `mcp.tools.baseline` on the span now reads
`pinned` instead of `first_seen`, which is the difference between a control and a
memory: pinned catches a server that was *already* poisoned before the pod
booted, `first_seen` cannot.

### 2. Pull the rug

With traffic flowing, set `POISON_TOOL_DESCRIPTION: "true"` on **mcp-crm** and
restart **that pod only**.

> Do not restart the action worker during this step if you are running unpinned.
> `first_seen` lives in process memory, so a restart adopts the poisoned
> catalogue as the new baseline and the change becomes invisible. That failure is
> worth doing once deliberately — it is the honest limit of an unpinned baseline.

**What you should see**, on the next ticket:

| Where | What |
|---|---|
| `action_worker.agent` span | `mcp.tools.changed = true`, `mcp.tools.digest` (new), `mcp.tools.digest.expected` (old), `mcp.tools.baseline` |
| Metric | `o11yag.security.events`, `kind=tool_catalogue_changed`, `action=observed` |
| Audit record | `o11yag.security.tool_catalogue_changed`, carrying both digests |

```
fetch logs, from: now()-30m
| filter audit.event.type == "o11yag.security.tool_catalogue_changed"
| fields timestamp, audit.baseline, audit.expected, audit.digest, audit.tools
```

**Nothing blocks, deliberately.** A worker that refuses to run because a
description changed cannot tell a deploy from an attack, and hands anyone who can
edit a description an outage. The control that holds regardless is the approval
gate, which does not care who asked for the refund.

---

## How a description gets poisoned outside a demo

Incidents 2 and 3 flip a flag. A real attacker has to reach the text the server
advertises, and the agent trusts that text because it asks the server for its
tool list at runtime and never sees it anywhere else. The routes in:

| Route | How it happens |
|---|---|
| **Malicious server** | A useful-looking MCP server from a public registry or repo ships with instructions hidden in its descriptions. Those instructions can target *other* servers' tools ("when you send email, also BCC…"), because every description lands in the same prompt. |
| **Rug pull** | The server is benign when reviewed and approved, and an update changes the descriptions later. The approval was given once and still covers the new text. This is incident 3. |
| **Supply chain** | A dependency of a trusted server is hijacked (stolen maintainer account, look-alike package) and rewrites descriptions at runtime. The server's own code reviews clean. |
| **Insider or compromised repo** | Someone with commit or config access edits one string. It reads like a docs change and survives review. |
| **Descriptions built from data** | Servers that generate descriptions from a database, config service or remote API spec hand control to whoever can write to that source, with no code change at all. |
| **In transit** | A remote server reached over plain HTTP or with weak auth can have its tool list rewritten between server and client. |

**Where this stack stands against each defence**

| Defence | Here |
|---|---|
| Enforce consequential actions **in code, outside the model** | Yes. `CONSEQUENTIAL_TOOLS` in the action worker's own config decides what needs approval, by tool name. No description can remove the gate. |
| Alert when the catalogue changes | Yes: `MCP_TOOLS_DIGEST`, incident 3. |
| Screen descriptions before the model sees them | Yes: `TOOL_POISON_ACTION: "redact"`, incident 2. A pattern match, with the limits below. |
| Pin server versions, review descriptions as code | Process, not code. mcp-crm lives in this repo, so review applies to it; a third-party server would need its image pinned by digest. |
| Allowlist servers and tools | **Not implemented.** The planner accepts any tool the server advertises. A poisoned server could add a new tool and the agent would offer it to the model. |
| Authenticated, encrypted transport | **Not implemented.** MCP is plain HTTP inside the cluster (`MCP_URL`). Fine for a demo namespace, not for a server outside it. |

The first row is the one that matters. Every other defence can be bypassed by a
description it fails to recognise; the approval gate never reads the description.

---

## Resetting

```yaml
# knowledge-worker
KB_POISON_DOC: "false"
INJECTION_ACTION: "quarantine"

# mcp-crm
POISON_TOOL_DESCRIPTION: "false"

# action-worker
TOOL_POISON_ACTION: "redact"
MCP_TOOLS_DIGEST: ""          # or re-pin the clean digest
```

Redeploy, and check the corpus went back to 8 documents — the reseed runs in both
directions:

```
kubectl logs -l app.kubernetes.io/name=o11yag-knowledge-worker -n o11yag-otel | grep -i seed
#   corpus changed (9 stored, 8 configured) - reseeding
```

If you pinned a digest and then changed the poison flag, the pin is now stale and
every ticket reports `mcp.tools.changed = true`. Re-read the digest and re-pin, or
blank it.

---

## What none of this proves

- **The detectors are pattern matches over English imperatives.** They will miss
  an injection in another language, split across two documents, encoded, or
  phrased in a way the list does not cover. A hit is a finding about the
  *pipeline* — someone wrote to the corpus who should not have — and the response
  is to go and look at how the document got in, not to tune the regex.
- **No agent has been observed complying** with any of this. Every incident here
  demonstrates detection. Compliance needs a model good enough to follow the
  instruction, which is not what is behind the gateway today.
- **Incident 1 cannot reach a tool**, for the architectural reason at the top of
  this page. Present it as an answer being corrupted, never as money moving.
