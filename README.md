# o11yag

A minimal, runnable reference architecture for the way enterprises actually build
LLM agents today — instrumented with [OpenLLMetry](https://github.com/traceloop/openllmetry)
and exported to Dynatrace, with the telemetry aimed specifically at the questions
agent stacks cannot currently answer.

Built to run on [Kubernetes on Docker Desktop](https://www.docker.com/blog/how-to-set-up-a-kubernetes-cluster-on-docker-desktop/)
and [WSL](https://learn.microsoft.com/en-us/windows/wsl/install), but nothing in
it is local-only.

> **New to agentic architecture?** Start with
> [`docs/WALKTHROUGH.md`](docs/WALKTHROUGH.md) — a guided read of this codebase
> for someone who knows observability but not agents. Then
> [`docs/UPDATE-GAPS-1-2.md`](docs/UPDATE-GAPS-1-2.md) for the answer judge, the
> feedback loop and the security act.

## Why

The interesting half of agent observability is not "instrument the LLM call".
OpenLLMetry does that for you in one line: model, tokens, cost, prompts, vector
queries, all of it, for free. Start there and you are done with the easy part on
day one.

What nothing gives you is the part that makes agents different from every service
APM was designed for:

- **Failure is silent and semantic.** The agent returns `200 OK` with a wrong
  answer. No span has `error=true`. Every RED metric is green.
- **There is no baseline.** The same ticket legitimately takes 3 LLM calls today
  and 11 tomorrow. Classical APM assumes a stable call graph; there isn't one.
- **Nobody budgets per LLM call.** They budget per resolved ticket — and that
  roll-up doesn't exist until you emit it.
- **The tool side is a blind spot.** The model half is thoroughly instrumented.
  "What did the agent actually do to my systems of record" is not.

o11yag builds the standard architecture, then closes those four gaps and shows
what it costs to close them.

## Architecture

The shape is the one the 2026 vendor guides converge on: an orchestrator that
triages and delegates, specialised workers, RAG for private knowledge, MCP for
tools, a model gateway in front of every LLM call, and a human approval gate in
front of anything consequential.

```
                            ┌─────────┐
                            │ loadgen │  a ticket every 20s
                            └────┬────┘
                                 │ POST /chat       human ──┐
                                 ▼                          │ POST /feedback
                      ┌──────────────────────┐◀─────────────┘
             ┌────────│     orchestrator     │────────┐
             │        └──────────┬───────────┘        │
    delegate │                   │ chat               │ delegate
             ▼                   │                    ▼
 ┌──────────────────────┐        │     ┌──────────────────────┐
 │   knowledge-worker   │        │     │     action-worker    │
 │  retrieve → screen   │        │     │   screen catalogue   │
 │  → answer → judge    │        │     │   → agent loop       │
 └───┬──────────────┬───┘        │     └──┬─────────┬──────┬──┘
     │ retrieve     │ chat ×2    │   chat │   MCP   │      │ approve?
     ▼              │  + embed   │        │         ▼      │
┌───────────┐       │            │        │  ┌───────────┐ │
│   qdrant  │       └──────┐     │   ┌────┘  │  mcp-crm  │ │
│ (vectors) │              ▼     ▼   ▼       │  orders,  │ │
└───────────┘         ┌──────────────────┐   │  refunds, │ │
                      │     litellm      │   │  tickets  │ │
                      │    (gateway)     │   └───────────┘ │
                      └─────────┬────────┘                 ▼
                                │              ┌──────────────────┐
                                ▼              │    approvals     │──▶ human
                      ┌──────────────────┐     │      (gate)      │
                      │      ollama      │     └─────────┬────────┘
                      │  qwen:0.5b       │               │ pending
                      │  nomic-embed-text│               ▼
                      └──────────────────┘     ┌──────────────────┐
                                               │      redis       │
  OTLP from the five                           └──────────────────┘
  instrumented services
  (loadgen emits none)
          │
          ▼
 ┌──────────────────┐
 │  otel-collector  │──▶ Dynatrace · traces · metrics · logs
 └──────────────────┘
```

Eleven pods, every edge. Two of them are shared infrastructure that everything
leans on, and that is the point rather than an artefact of the drawing: **every
chat and embedding call goes through `litellm`**, so no service holds a provider
name or ever reaches Ollama directly, and **every instrumented service exports
through one Collector**, so swapping the backend is a Collector change.

The stages written inside the two worker boxes are **not pods**, and that is
worth reading twice, because it is where half of this project's signal now comes
from. `screen` and `judge` are code sitting between an input and a prompt, or
between a prompt and the reply — nothing to deploy, nothing on the network to
point at, and no box of their own to draw. The judge is a second call through the
same gateway under its own alias (`support-judge`), which is why a question
ticket now costs two model calls rather than one. `POST /feedback` is likewise
just another endpoint on the orchestrator; it earns an arrow because the *human*
on the end of it is the only input in this diagram the stack cannot generate
about itself.

MCP wraps the **systems of record only**. The knowledge worker talks to Qdrant
directly, because in practice you don't MCP-wrap your own vector store — you
MCP-wrap the CRM, the ticketing system, the vendor API you didn't write.

## Components

| Component | Port | Stack | Role |
|-----------|------|-------|------|
| **o11yag-orchestrator** | 8000 | Flask | Supervisor. Classifies intent, delegates to one worker, owns the per-ticket roll-up, the conversation audit record and the `/feedback` endpoint. |
| **o11yag-knowledge-worker** | 8001 | Flask + Qdrant | RAG over the support knowledge base. Refuses to answer off a weak retrieval, screens what it retrieved for injected instructions, and grades the answer it gave. |
| **o11yag-action-worker** | 8002 | Flask + MCP client | The agent loop. Picks tools, calls them over MCP, routes consequential ones through the gate. |
| **o11yag-mcp-crm** | 8003 | MCP Python SDK | MCP server over Streamable HTTP exposing the fake system of record. |
| **o11yag-approvals** | 8004 | Flask + Redis | Human-in-the-loop gate, with a reviewer page at `/`. |
| **LiteLLM** | 4000 | LiteLLM proxy | Model gateway. Every LLM and embedding call goes through it. |
| **Qdrant** | 6333 | Qdrant | Vector store, seeded by the knowledge worker on first boot. |
| **Ollama** | 11434 | Ollama | `qwen:0.5b` for chat, `nomic-embed-text` for embeddings. |
| **Redis** | 6379 | Redis | Approval state. |
| **OTel Collector** | 4317/4318 | contrib | OTLP in, Dynatrace out. Traces, metrics **and logs**. |
| **loadgen** | — | Python | Support tickets on a timer. Emits no telemetry of its own. |

> **LiteLLM is not LightLLM.** LiteLLM is a pure-Python proxy that forwards to a
> backend — no GPU, no model weights. LightLLM is a GPU inference engine and is
> not used here.

## Verified against

The SDK surface this code targets was checked against real installs, not from
memory: `traceloop-sdk` **0.62.3** (`Traceloop.init(app_name, api_endpoint,
disable_batch)`, `set_association_properties`, the `workflow`/`task`/`agent`/`tool`
decorators), `mcp` **2.2.0** (`MCPServer`, `streamable_http_client`,
`Tool.input_schema`, `CallToolResult.structured_content`) and `openai` **3.14.1**.

**Run, and working:**

- All five instrumented services boot from a clean virtualenv built only from
  their own `requirements.txt`, with telemetry on, and answer `/health`.
- The MCP leg end to end — server up, client calling it. Every one of the 17 HTTP
  requests in a `list_tools` + two `call_tool` exchange carried the client's
  `traceparent`, matching the calling span's trace id.
- The agent loop against that live MCP server: `lookup_order` → `issue_refund`
  → done, refunding the order's own total rather than an amount asserted in the
  customer's message.
- The gap 1 and gap 2 logic, as pure functions, against the real corpus and a
  real tool catalogue: zero false positives from the injection patterns across
  all eight benign documents, the poison document caught on `override`, the
  catalogue digest stable under reordering and moving on a changed description,
  and the judge's heuristic separating an invented figure from grounded
  paraphrase and from an honest refusal. Logic only — no model, no cluster.

**Found only by running it in a cluster:** the MCP server's Host-header check.
Every tool call returned 421 because the SDK auto-allows localhost and nothing
else, which the loopback test above could not have caught — it was loopback.

**Not run:** anything needing a cluster. The Kubernetes deployment itself, the
Dynatrace export, Ollama, LiteLLM and the Qdrant seed path are all unexercised —
the manifests parse and the images build, but nothing has been deployed. That
includes both halves of gap 1 and gap 2 end to end: the judge's *model* path has
never been asked for a verdict by a real model, the reseed that makes
`KB_POISON_DOC` take effect has never run against a live Qdrant, and no agent has
yet been observed complying with an injection it was fed. The detectors are
verified; the demonstrations they exist for are not.

The boot test is the one that matters most, and it is why `smoke.sh` exists: the
services passed every static check — manifests parsed, Python compiled, imports
read correctly — while the orchestrator still died on its first line of real work
because a transitive dependency had quietly gone away. For this stack the
dependency graph is the fragile part, not the code, because the ecosystem is
mid-migration from `httpx` to `httpx2` and the SDKs disagree about where they are
in it.

## Conventions

- **Config** is environment-driven through a per-service `config.py`.
- **Containers** are multi-stage and non-root, with a read-only root filesystem
  and a `/tmp` `emptyDir` for scratch.
- **Deployment** is one self-contained Kubernetes manifest per component.
- **Image naming** is `o11yag-<service>`, tagged with a build timestamp.
- **Instrumentation** is `o11y.py`, copied verbatim into every instrumented
  service (each Docker build context is its own directory).
- **Namespaces**: span attributes follow `gen_ai.*` where OpenLLMetry's semantic
  conventions cover them, with `mcp.*`, `agent.*` and `rag.*` only for what has
  no equivalent. Metric *keys* are product-scoped `o11yag.*`. Audit record fields
  are `audit.*`. The split is deliberate: renaming a metric key orphans its
  history, renaming a span attribute only affects queries from that point on.

## Getting started

> Prerequisites: a Kubernetes cluster, `kubectl`, and Docker.

1. **Start Kubernetes on Docker Desktop** with headroom for Ollama:
   memory ≥ 8192, cpus ≥ 4.

2. **Set the Dynatrace variables**:
   ```
   export DT_API_TOKEN='your_token'
   export DT_TENANT='abc12345'      # first part of your Dynatrace URL
   ```
   The token needs the **Ingest metrics**, **Ingest OpenTelemetry traces** and
   **Ingest logs** scopes. `Ingest logs` is what carries the audit records —
   without it the Collector accepts them and Dynatrace rejects them with a 403
   naming the missing scope, which is silent from Grail's side and obvious in the
   Collector's own log:
   ```
   kubectl logs -l app.kubernetes.io/name=o11yag-otel-collector -n o11yag-otel \
     | grep -i "missing required scope"
   ```

   **Rotating the token needs a Collector restart.** Env vars are injected from
   the Secret when the container starts, so rewriting the Secret leaves a running
   Collector on the old token and the identical 403 keeps arriving — which reads
   as the new token being wrong rather than as never having been loaded.
   `build_deploy.sh` restarts the Collector whenever it rewrites the Secret; if
   you change it by hand, do it yourself:
   ```
   kubectl rollout restart deployment/o11yag-otel-collector -n o11yag-otel
   ```

3. **Build and deploy**:
   ```
   bash build_deploy.sh
   ```
   First start is slow: Ollama downloads two models (~700MB) before it is ready,
   and the knowledge worker seeds Qdrant on its first boot.

4. **Allow-list span attributes on the tenant.** Dynatrace does **not** persist
   custom span attributes by default — it accepts them and silently drops them,
   listing what it discarded in `supportability.non_persisted_attribute_keys`.
   Until this is configured you lose `agent.loop.*`, `rag.*`, `mcp.*`, `step.*`
   **and** everything OpenLLMetry emits: `gen_ai.usage.*`, `gen_ai.request.model`,
   and the `traceloop.association.properties.*` that carry tenant / customer /
   ticket. Metrics are a separate pipeline and are unaffected, so the dashboard
   looks healthy while the traces are hollow.

   Check with:
   ```
   fetch spans, from: now() - 10m
   | filter matchesValue(dt.service.name, "o11yag_*")
   | summarize dropped = countIf(isNotNull(`supportability.non_persisted_attribute_keys`)),
               total = count()
   ```
   `dropped` must be 0. It applies to newly ingested spans only, so judge it on
   fresh data.

5. **Watch it work**:
   ```
   kubectl get pods -n o11yag-otel -w
   kubectl logs -l app.kubernetes.io/name=o11yag-loadgen -n o11yag-otel -f
   ```

Redeploy without rebuilding with `bash build_deploy.sh --no-build`. `stop.sh`
removes the workloads but keeps the namespace, the secret and the volumes.

**Before deploying, smoke-test the images**:
```
bash smoke.sh
```
It boots each built image with telemetry off and every backing service pointed at
a dead port, and checks it answers `/health`. That catches the class of bug where
everything static passes — manifests parse, Python compiles — and the container
still dies on boot because a dependency is missing from `requirements.txt`. It is
much faster than finding out from a CrashLoopBackOff.

## The four gaps, and what closing each one cost

### 1. Silent semantic failure — closed at the signal, open at the judge

Three guards now, at three different distances from the truth.

**The retrieval floor** is the cheapest and runs first: the knowledge worker
checks the best similarity score against `MIN_SCORE` and says "I don't have a
policy that covers that" rather than letting the model invent one, emitting an
`o11yag.retrieval.ungrounded` audit record when it does. It catches wrong answers
*caused by* bad retrieval — and nothing else. The larger half of the problem is
the answer that is grounded in exactly the right document and wrong anyway, and
for that ticket every signal this stack had was green: `rag.top_score` high, no
span in error, a confident paragraph quoting a policy that does not exist.

**The judge** (`knowledge-worker/judge.py`) grades the answer it actually gave
against the extracts it was given, on its own `judge_answer` span, and records
`o11yag.answer.quality` by verdict. Two graders, and the deterministic one is
not a fallback:

- *heuristic* — free, runs on every answer. An amount, deadline or duration in
  the answer that appears nowhere in the extracts (`unsupported_number:60`), or
  an answer whose content words are largely absent from them
  (`low_overlap:0.12`). Crude, and aimed squarely at what actually goes wrong in
  a policy KB: the model keeps the shape of the policy and invents the figure,
  which is the version a customer acts on.
- *model* — a second LLM call, asked for a yes/no. The one every vendor diagram
  draws, and the one to be most careful about here, because the judge is the
  same `qwen:0.5b` that could not reliably emit a tool call. `JUDGE_MODEL` is a
  separate gateway alias so a capable model can be put behind it from
  `litellm`'s ConfigMap alone.

`quality.decided_by` records which grader produced the verdict, for the same
reason `step.decided_by` exists in the action worker: so "the judge model never
once disagreed with the cheap check" stays a fact you can query rather than an
assumption you inherit. A judge that returns nothing usable is recorded as
`decided_by=heuristic, reason=model_unparseable` — not as a pass.

**The thumbs-down** (`POST /feedback` on the orchestrator) is the only input in
the whole stack that does not come from the stack. Everything else — the floor,
the judge, the loop signals — is the system's opinion of itself, and all of it
can be confidently and consistently wrong at once with nothing internal
disagreeing. `/chat` returns its `trace_id` for exactly this: the feedback
arrives minutes or days later on a trace of its own, and `audit.subject_trace_id`
is what makes a thumbs-down openable rather than merely countable.

**What it cost, measured.** One extra model call per answered question, on the
ticket's own latency, counted into `o11yag.task.tokens` and `.cost.usd` like any
other — a judge you do not pay for is a judge that did not run. On this stack
that call buys nothing at all, and the numbers are the point:

> Over the first 10 graded answers against a live `qwen:0.5b`, the judge model
> produced **0 usable verdicts** while spending **2,353 tokens** and adding
> **1,462 ms** (p50) to every answered ticket. Four replies were JSON-shaped with
> a non-boolean `supported`, two contained no JSON at all. Every verdict on the
> dashboard was the deterministic check's.

Small sample, and it will not improve: it is the same finding as "2 usable
`lookup_order` arguments out of 51", for grading instead of tool calling. The
reason it is visible at all is `quality.decided_by` — without that dimension the
verdicts look identical to a judge that agrees with everything, and a judge that
agrees with everything is indistinguishable from one that was never asked.

`JUDGE_MODE: heuristic` drops the model call and keeps the signal at zero
marginal cost and reduced coverage; it is the right setting for this stack, and
the default stays `model` for the same reason `PLANNER_MODE` does — so a run
shows the truth about the model behind the gateway rather than hiding it.

**What is still open, and it is the important part.** The judge is a detector,
and `JUDGE_ACTION` defaults to `observe` — the unsupported answer is recorded and
still sent. `withhold` replaces it with the refusal, and is the setting that
actually protects the customer; it is not the default because a weak judge
withholding good answers is a worse product than a wrong answer you can see in a
dashboard, and nobody should flip it before measuring their own false-positive
rate. There is also no offline evaluation set here, no regression suite, and
nothing that feeds a thumbs-down back into retrieval or the prompt. The signal
exists and is honest about its own quality. The loop that closes on it does not.

### 2. No baseline — closed, in the sense that the series now exists

`agent.loop.steps`, `o11yag.task.llm_calls` and `agent.loop.repeated` give you
the shape of the work per ticket, dimensioned by intent. Because there is no
fixed call graph, these series *are* the baseline: point Davis anomaly detection
at `o11yag.task.llm_calls` by intent and a task that suddenly needs three times
as many model calls becomes an alert instead of a bill.

`agent.loop.terminated = max_steps` deserves its own attention. It means the
agent ran out of budget and returned a partial answer. Nothing errors.

### 3. Per-ticket economics — closed

`o11yag.task.cost.usd`, `.tokens`, `.llm_calls` and `.latency` are recorded once
per resolved ticket, dimensioned by `intent` and `tenant`, from
`o11y.task_finished()`. Attribution rides Traceloop association properties
(`tenant`, `customer_id`, `ticket_id`) set once on the orchestrator and inherited
by every downstream span.

### 4. The tool blind spot — closed

Every MCP call produces a span (`gen_ai.tool.name`, `mcp.server`,
`mcp.transport`, arguments), a metric (`o11yag.tool.calls` by tool / outcome /
approval status) and an audit record. The MCP server is instrumented too, and
the SDK carries trace context in the JSON-RPC `_meta` field, so the call is one
trace end to end. The HTTP hop underneath it is the part that needs help — see
*Trace context* below for which half is free and which is not.

### Bonus: the approval gate is not invisible

`approval_wait` is its own span and `o11yag.approval.wait` its own metric. Left
inside the tool call, a reviewer who goes to lunch would swamp every latency
percentile in the stack. Subtract it from `o11yag.task.latency` to get machine
time.

## The security act

Three attacks, all specific to agents, all of which leave a normal trace looking
perfectly healthy. Everything here is **off by default** — the reference stack
ships a clean knowledge base and an honest tool catalogue — because an attack
that ships enabled inside a reference architecture is indistinguishable from a
backdoor. Each one is a ConfigMap flag away.

> **Running one?** [`docs/SECURITY-DEMOS.md`](docs/SECURITY-DEMOS.md) is the
> runbook: which flag, what has to restart, what you should see, the ordering
> that matters for the rug pull, and how to put it all back.
>
> Want the **Error rate** tile off zero? [`docs/ERROR-DEMOS.md`](docs/ERROR-DEMOS.md)
> covers which failures count as `outcome=error` and how to cause them.

### Indirect prompt injection through the RAG corpus

The direct kind — a customer typing "ignore your instructions" — is the one
everybody pictures and the least interesting, because that text arrives labelled
as untrusted. The one that works is indirect: the instruction is written into a
*document*, retrieved on its merits by a similarity search doing exactly its job,
and reaches the model inside the context block — the part of the prompt the model
was told to trust. Nobody typed it during the ticket that fires it. It can be
planted months earlier by anyone who can write to the corpus: a scraped vendor
page, a wiki, a support macro, an uploaded PDF.

The reason it belongs in an observability repo is that the stack cannot see it
happen. Retrieval is *healthy* — the poisoned document is a genuinely good match,
so `rag.top_score` is high. No span errors. And if the model complies, the tool
call it produces is well-formed and in-contract, so `planner.validate_args`
passes it and `step.decided_by` says `model`. The trace reads as a normal ticket
in which the agent decided, by itself, to issue a refund nobody asked for.

`knowledge-worker/security.py` screens between retrieval and the prompt, which is
the only point where the text is still identifiable as *retrieved* rather than
*said*. A flagged document is dropped before the context is built
(`INJECTION_ACTION: quarantine`) — a detector that logs the finding and prompts
with the document anyway has recorded an attack it also carried out.

`KB_POISON_DOC: "true"` seeds the demo document. Qdrant keeps its volume across a
redeploy, so the knowledge worker compares the stored point count against the
configured corpus and reseeds when they differ; a flag that silently does nothing
would be a poor joke in this particular repo.

**What this path cannot do here, stated before anyone demonstrates it and finds
out.** The planted document tells the agent to issue a refund. It will not get
one. Retrieval belongs to the knowledge worker, and the knowledge worker has no
tools — it retrieves and writes prose; the agent that holds the tools never
retrieves. An injection in this corpus can therefore corrupt an *answer* and
nothing beyond it. The general attack does end in a tool call, and in an
architecture where a single agent both retrieves and acts it would end in one
here — but that is not the architecture in this repo, and a demo implying
otherwise would be doing exactly what this project argues against. The injection
that changes what the agent *does* is the tool-catalogue one below.

### Tool poisoning

An MCP tool description is attacker-controlled text that goes into the planner's
system prompt as capability documentation, and the agent is built to act on it.
Same signature as above: the resulting call is well-formed, in-schema and
attributed to the model, because it was the *intent* that was supplied by an
attacker and no schema check can see intent.

`POISON_TOOL_DESCRIPTION: "true"` on the **mcp-crm** ConfigMap makes the server
advertise `issue_refund` with an injected description. The server does the lying,
not a stub in the client: a demo where the detector is fed a canned finding
proves the detector prints, not that it detects. The action worker screens the
catalogue at discovery and blanks a flagged description before the planner sees
it (`TOOL_POISON_ACTION: redact`) — the description is removed, not the tool,
because dropping it would let anyone who can edit a description disable any tool
they like.

### The rug pull

The same server, serving a benign description until it is trusted and a different
one afterwards. Tool names identical, schemas identical, tool list identical;
nothing in a normal trace moves at all. The only thing that catches it is a
fingerprint taken over descriptions and schemas and compared to one taken
earlier — `mcp.tools.digest` on the `action_worker` span.

`mcp.tools.baseline` says which comparison you are getting, and the difference
matters: `pinned` means `MCP_TOOLS_DIGEST` is set in config and a server that was
*already* poisoned at boot is caught on the first call; `first_seen` means the
first catalogue this pod saw became its own baseline, which catches a change
mid-life and is blind to a server that was compromised before the pod started. A
restart forgets. The digest is logged on first sight, so pinning it is copy and
paste.

Flip `POISON_TOOL_DESCRIPTION` on a running stack and you have performed the rug
pull: the digest stops matching, `mcp.tools.changed` goes true, and
`o11yag.security.tool_catalogue_changed` fires with both digests in the record.

**Nothing here blocks.** A worker that refuses to run because a description
changed cannot tell a deploy from an attack, and hands anyone who can edit a
description an outage. Detection produces a signal a human acts on; the control
that holds regardless is the approval gate, which does not care who asked.

## Signals reference

### Metrics (`o11yag.*`)

| Metric | Type | Dimensions | What it is |
|--------|------|------------|------------|
| `o11yag.tasks` | counter | intent, tenant, outcome | Tickets handled |
| `o11yag.task.latency` | histogram (ms) | intent, tenant | Wall clock per ticket, human wait included |
| `o11yag.task.llm_calls` | histogram | intent, tenant | Loop depth — the non-determinism signal |
| `o11yag.task.tokens` | counter | intent, tenant | Tokens per ticket |
| `o11yag.task.cost.usd` | counter | intent, tenant | Cost per ticket |
| `o11yag.approval.wait` | histogram (ms) | tool, decision | Human decision time |
| `o11yag.tool.calls` | counter | tool, outcome, approved | MCP tool calls |
| `o11yag.retrieval.top_score` | histogram | collection | Best similarity score |
| `o11yag.retrieval.hits` | histogram | collection | Chunks returned |
| `o11yag.answer.quality` | counter | verdict, decided_by | Groundedness verdict on an answer that *was* given |
| `o11yag.feedback` | counter | rating, intent, tenant | A human's verdict, arriving later on its own trace |
| `o11yag.security.events` | counter | kind, action, source | Injection, tool poisoning or a changed tool catalogue |

### Span attributes beyond what OpenLLMetry emits

| Attribute | Where | What it is |
|-----------|-------|------------|
| `agent.loop.steps` / `.max_steps` | action worker | Iterations taken, and the budget |
| `agent.loop.repeated` | action worker | Identical tool + identical args, called twice. No error, just waste |
| `agent.loop.terminated` | action worker | `done` or `max_steps` — the silent partial answer |
| `step.index` / `step.decided_by` | action worker | Which iteration, and whether the model or the fallback chose |
| `step.fallback_reason` | action worker | *Why* the model's answer was rejected — `unparseable`, `unknown_tool`, `missing:order_id`, `unknown:id`, `mode:rules` |
| `gen_ai.tool.name` / `.call.arguments` | action worker | The tool call |
| `mcp.server` / `mcp.transport` / `mcp.tools.available` | action worker | The MCP hop |
| `approval.required` / `.decision` / `.waited_ms` / `.decided_by` | action worker | The gate |
| `rag.hits` / `.top_score` / `.doc_ids` / `.scores` / `.grounded` | knowledge worker | Retrieval quality, not just latency |
| `quality.verdict` / `.decided_by` / `.reason` | knowledge worker | Was the answer supported by its extracts, who decided, and on what — `unsupported_number:60`, `low_overlap:0.12`, `declined`, `model_unparseable` |
| `quality.judge.mode` / `.model` / `.tokens` | knowledge worker | Which judge ran, against which gateway alias, and what it cost |
| `security.injection.detected` / `.kinds` / `.doc_ids` / `.action` | knowledge worker | A retrieved document carrying instructions, and whether it was quarantined |
| `security.tool_poisoning.detected` / `.tools` / `.kinds` / `.action` | action worker | An MCP tool description carrying instructions |
| `mcp.tools.digest` / `.baseline` / `.changed` | action worker | Fingerprint of the advertised catalogue, what it was compared against (`pinned` or `first_seen`), and whether it moved |

The MCP SDK contributes spans of its own on top of these, from its
`mcp-python-sdk` tracer and with no opt-in: `MCP send <method>` on the client
side (`mcp.method.name`, `jsonrpc.request.id`) and a matching server span
carrying `gen_ai.operation.name` and `gen_ai.tool.name`. They are the SDK's
rather than ours, which matters when you allow-list attribute keys on the tenant.

### Audit records (OTLP logs, `audit.*`)

| Event type | Written by | Carries |
|------------|-----------|---------|
| `o11yag.ticket.handled` | orchestrator | The conversation, intent, outcome, cost, tokens |
| `o11yag.answer.generated` | knowledge worker | Question, answer, the documents it was grounded on |
| `o11yag.retrieval.ungrounded` | knowledge worker | A question the KB could not answer |
| `o11yag.tool.called` | action worker | Tool, arguments, result, approval status |
| `o11yag.tool.blocked` | action worker | A tool call the gate refused |
| `o11yag.approval.requested` / `.decided` | approvals | Who decided, how long they took |
| `o11yag.answer.withheld` | knowledge worker | An answer the judge rejected, kept in the record after being replaced |
| `o11yag.feedback.received` | orchestrator | A human rating, and `subject_trace_id` — the trace being rated |
| `o11yag.security.injection_detected` | knowledge worker | The document, the phrase that matched, and what was done |
| `o11yag.security.tool_poisoned` | action worker | The tool, the phrase, and whether the description was redacted |
| `o11yag.security.tool_catalogue_changed` | action worker | Both digests and the baseline they were compared against |
| `o11yag.crm.refund_issued` | mcp-crm | The effect on the system of record |

Every record carries `audit.trace_id` and `audit.span_id`, so an auditor pivots
from a record to the trace and back.

```
fetch logs
| filter audit.event.type == "o11yag.tool.called"
| fields timestamp, audit.tool, audit.args, audit.approved,
         audit.ticket_id, audit.customer_id, audit.trace_id
| sort timestamp desc
```

## Dashboard

[`dashboards/o11yag.json`](dashboards/o11yag.json) — deploy with
`cd dashboards && ./deploy.sh`, which posts it to the Dynatrace Document API
using the same `$DT_ENVIRONMENT` / `$DT_PLATFORM_TOKEN` the Dynatrace MCP plugin
uses. (Manual **Dashboards → Upload** also works.) Seventeen tiles over the `o11yag.*`
metrics: per-ticket KPIs, volume and intent mix, loop depth, latency, token and
cost breakdown, MCP tool calls, retrieval quality, answer-quality verdicts, human
feedback, security detections and approval wait. Every query was validated
against a live tenant except the three gap 1 / gap 2 series, which have not been
ingested yet and are validated for syntax only. See
[`dashboards/README.md`](dashboards/README.md) for what each tile is for, why
three of them are empty when the system is healthy, and the DQL gotcha that made
the error-rate tile go blank exactly when there were no errors.

## Trace context

The stack is one trace from ticket to system of record. Three things make that
work, and it is worth being exact about which of them you get for free:

- **OpenLLMetry does not instrument HTTP.** `o11y.py` adds the Flask, requests
  and httpx instrumentations separately. Without them every service hop starts a
  new trace. Be precise about what each buys, because this stack is mostly *not*
  on httpx: `requests` covers the service-to-service hops, `httpx` covers
  `qdrant-client` and nothing else, and Flask covers the inbound span.
- **The MCP hop propagates itself, inside the JSON-RPC envelope.** This is free,
  and it is the part most write-ups (including an earlier version of this one)
  get wrong. The SDK's client dispatcher opens a CLIENT span per outbound
  request — the `MCP send <method>` spans in the waterfall, named after the
  method plus the tool where the params carry one, in
  `mcp/shared/jsonrpc_dispatcher.py` — and writes the W3C context into that
  request's `_meta` field on the way out (SEP-414). The server end reads it back
  in `OpenTelemetryMiddleware`, which `mcp.server.lowlevel.server` installs by
  default and which also sets `gen_ai.operation.name` and `gen_ai.tool.name` on
  `tools/call`. Nothing here configures any of it; it arrives with `mcp` 2.x.
  Because the carrier is `_meta` rather than a header, **it holds over stdio
  too** — trace continuity across MCP is no longer a property of the transport.
- **The HTTP layer underneath it does not propagate itself.** The obvious fix —
  add `opentelemetry-instrumentation-httpx` and let it propagate — silently does
  nothing here, because **MCP 2.x makes its HTTP calls through `httpx2`, a
  different package from `httpx`**. The same is true of the OpenAI SDK from 3.x
  on, so the httpx instrumentation does not cover the LLM calls either — those
  become spans because Traceloop wraps the OpenAI *client*, a level above the
  transport. So `action-worker/mcp_client.py` hands the transport its own
  `httpx2` client with an event hook that injects the W3C context on every
  request, and the MCP server adds ASGI middleware to read that header back.
  Be honest about what that second route buys: the tool call itself lands in the
  right trace either way, over `_meta`. The hand-injection is what keeps the
  transport spans — `POST /mcp`, and the session's `DELETE /mcp` — inside the
  ticket's trace instead of each rooting one of its own. The failure mode is not
  an error: every call still succeeds and nothing reports a problem.

## What this deliberately does not do

- **No evaluation loop, still.** There is now a quality *signal* — the judge and
  the feedback endpoint — and that is not the same thing. No offline evaluation
  set, no regression suite, no golden answers, and nothing that routes a
  thumbs-down back into retrieval, the prompt or a retraining queue. The
  reference architectures draw the closed loop; this draws the half of it that
  can be built honestly in a reference stack, and says which half that is.
- **The security act detects; it does not prevent.** See its own section above.
  The detectors are pattern matches over English imperatives and will miss an
  injection in another language, split across two documents, or simply phrased
  in a way the list does not cover. The durable controls are upstream (who can
  write to the corpus, what is re-verified on ingest) and downstream (the
  approval gate, which does not care who asked for the refund). Treat a hit as a
  finding about the pipeline, not as a regex to tune.
- **The approval gate auto-approves by default**, so loadgen can run unattended.
  With `AUTO_APPROVE=true` the gate proves nothing about governance — it is a
  timer wearing a reviewer's hat. Set it to `false`, port-forward the approvals
  page, and decide by hand for the honest version. Refunds over
  `AUTO_APPROVE_MAX_EUR` always wait for a person regardless, so there is always
  one path that genuinely stops.
- **Cost is priced, not measured.** A local model is free, which makes cost-per-
  ticket a column of zeroes and the attribution unprovable. `COST_PER_1K_TOKENS_USD`
  prices the tokens as if a hosted model were behind the gateway. It shows the
  attribution works; it is not a measurement. Replace it with the gateway's own
  reported cost the moment a real provider is behind LiteLLM.
- **`qwen:0.5b` is a poor tool-caller, and here is the measurement.** Over three
  hours of live traffic it produced usable arguments for `lookup_order` **2 times
  out of 51** — mostly passing a customer id as `{"id": "C-7"}` when the tool
  takes `order_id` — and it declared itself finished after a single step in **39
  of 45 runs**. In that window `issue_refund` was never once attempted, so the
  approval gate was never exercised. Six runs reached a second step and spent it
  re-calling the same tool with identical arguments (`agent.loop.repeated`).

  **Measured later, the gate does run in `model` mode — but never because of the
  model.** From 2026-09-20 to 2026-09-30 Dynatrace holds **862** `issue_refund`
  calls. Every one sits under a step with `step.decided_by = fallback`, and **0**
  were proposed by the model: at the second step the model named a tool the
  server doesn't advertise (`step.fallback_reason = unknown_tool`, 860) or
  returned something unparseable (2), and the rules took over and went on to the
  refund. 338 were auto-approved (ORD-1001, €89.90); 524 timed out waiting for a
  person (ORD-1002 and ORD-1004, both over `AUTO_APPROVE_MAX_EUR`).

  Two things in the code respond to that, and it matters which does what:

  - **Argument validation** (`planner.validate_args`) holds the model to the
    JSON schema the MCP server advertises. Wrong or missing parameters are
    rejected and the deterministic rules take over, with `step.fallback_reason`
    recording what was wrong. This fixes bad *arguments*.
  - **`PLANNER_MODE=rules`** skips the model for tool selection entirely. This is
    what makes the refund → approval → gate path reliably demonstrable.

  Validation does not make the *model* refund, and it does not make refunds
  reliable. Whenever the model is overruled at the right step, the rules reach
  `issue_refund` — that is the 862 above. But a model that answers
  `{"done": true}` is well-formed and in-contract, so it is accepted and the loop
  ends early with no refund. Well-formed is not the same as sensible, and only
  the second switch makes the path happen every time. Never present a `rules` run as model
  reasoning — `step.decided_by` is in the trace precisely so you don't have to
  take anyone's word for it.
- **LiteLLM is unauthenticated** inside the namespace. The real shape is a virtual
  key per agent with its own budget.
- **Audit records land in the default log bucket.** Until an OpenPipeline rule
  routes `audit.event.type` to a bucket with its own retention, the
  record-keeping claim is not fully true. That is tenant configuration, not code.
- **`traceloop-sdk` imports `httpx` without declaring it.** Every service that
  installs Traceloop therefore lists `httpx` in its `requirements.txt` even
  though none of them use it directly. Drop that line and the pod dies on boot
  with `ModuleNotFoundError: No module named 'httpx'`, because nothing else
  pulls it in any more — `openai` 3.x and `mcp` 2.x are both on `httpx2`.
- **The MCP server validates the `Host` header**, and only auto-allows
  localhost. Reached by any other name — a Kubernetes Service, an Ingress host —
  it answers `421 Misdirected Request` and logs `Invalid Host header`, which
  looks like a routing fault rather than a policy decision. `MCP_ALLOWED_HOSTS`
  on its ConfigMap lists the names it may be called by. Extend that list when
  you expose it a new way; resist `MCP_DNS_REBINDING_PROTECTION=false`, which
  removes a real control for everyone to fix one address.
- **The MCP session is rebuilt per tool call**, which adds an initialize round
  trip to every call and inflates the tool latency you see. A real agent holds
  one session per conversation.

## Debug / dev

**Send a ticket** to the orchestrator:
```
kubectl port-forward service/o11yag-orchestrator 8000:8000 -n o11yag-otel

curl -X POST http://localhost:8000/chat -H 'Content-Type: application/json' \
  -d '{"ticket_id":"TK-1","customer_id":"C-7","tenant":"acme",
       "text":"I want a refund for order ORD-1001, the headphones stopped working."}'
```

**Rate an answer** (the human half of gap 1). `/chat` hands back the `trace_id`
its own reply came from; feedback arrives later on a trace of its own and names
that one, so a thumbs-down is openable rather than merely countable:
```
curl -X POST http://localhost:8000/feedback -H 'Content-Type: application/json' \
  -d '{"ticket_id":"TK-1","rating":"down","intent":"question",
       "trace_id":"<the trace_id /chat returned>",
       "comment":"quoted a 60-day return window that does not exist"}'
```

**The approvals page**:
```
kubectl port-forward service/o11yag-approvals 8004:8004 -n o11yag-otel
# then open http://localhost:8004/
```

**Ask the knowledge worker directly**:
```
kubectl port-forward service/o11yag-knowledge-worker 8001:8001 -n o11yag-otel
curl -X POST http://localhost:8001/answer -H 'Content-Type: application/json' \
  -d '{"ticket_id":"TK-2","text":"How long do refunds take?"}'
```

**Check the model gateway**:
```
kubectl port-forward service/litellm 4000:4000 -n o11yag-otel
curl http://localhost:4000/v1/models
```

**If every MCP tool call fails with 421**, the action worker is reaching the
server by a name the allowlist doesn't cover. The server says so:
```
kubectl logs -l app.kubernetes.io/name=o11yag-mcp-crm -n o11yag-otel | grep -i "host"
#   WARNING mcp.server.transport_security Invalid Host header: <the name>
#   INFO    ... "POST /mcp HTTP/1.1" 421 Misdirected Request
```
Add that name to `MCP_ALLOWED_HOSTS` in `mcp-crm/k8s/o11yag-mcp-crm.yaml` and
roll the pod. The server logs its allowlist on boot, so you can check what it
believes it accepts.

**Watch what the Collector is forwarding**: `kubectl logs -l app.kubernetes.io/name=o11yag-otel-collector -n o11yag-otel -f`

### Turning the interesting cases on

| To see | Do |
|--------|-----|
| A real human approval | `AUTO_APPROVE=false` on the approvals ConfigMap, then use the page |
| A gate that stops regardless | Send a refund for `ORD-1004` (430 EUR, over the ceiling) |
| A refund actually reaching the gate | `PLANNER_MODE: "rules"` on the action worker ConfigMap — the local model rarely gets there on its own |
| A loop that runs out of budget | `MAX_STEPS: "1"` on the action worker ConfigMap |
| An ungrounded answer | Ask something the KB has no policy for |
| A blocked tool call | Deny an approval on the page |
| An answer graded unsupported | Ask a question the KB half-covers — or force the plumbing with `JUDGE_MIN_OVERLAP: "0.9"`, which flags ordinary paraphrase |
| That answer never reaching the customer | `JUDGE_ACTION: "withhold"` on the knowledge worker |
| The judge off the critical path | `JUDGE_MODE: "heuristic"` — deterministic checks only, no second model call |
| A prompt injection landing | `KB_POISON_DOC: "true"` **and** `INJECTION_ACTION: "observe"`, then ask about a faulty item |
| The same injection stopped | `KB_POISON_DOC: "true"` alone — quarantine is the default |
| A poisoned tool description | `POISON_TOOL_DESCRIPTION: "true"` on the **mcp-crm** ConfigMap |
| A rug pull | Flip that same flag while the action worker is running |
| A thumbs-down | `POST /feedback` — see below |
