# o11yag walkthrough

A guided read of this codebase for someone who knows observability but is new to
agentic architecture. Start here, then read the code in the order below.

> Once this makes sense, [`UPDATE-GAPS-1-2.md`](UPDATE-GAPS-1-2.md) walks the
> parts added later: the answer judge, the feedback endpoint, and the detectors
> for prompt injection, tool poisoning and rug-pulled tool definitions.
> [`SECURITY-DEMOS.md`](SECURITY-DEMOS.md) is the runbook for switching those
> attacks on and off.
> [`ERROR-DEMOS.md`](ERROR-DEMOS.md) does the same for failures that push the
> Error rate tile off zero.

> Function names are used as anchors rather than line numbers, because line
> numbers rot. `grep -n "def <name>" <file>` will find any of them.

---

## 1. Basic idea

APM sees a system quite deterministically:

```
request → service A → service B → database → response
```

**The call graph is fixed.** The same input takes the same path. That single
assumption is what lets you baseline it, alert on deviation, and say that a given span is slow.

An agent breaks exactly that assumption:

```
request → a model decides what to do
        → do it (call a tool, search a knowledge base)
        → the model looks at what came back
        → it decides again
        → ... until it decides it is finished
        → answer
```

**The path is chosen at runtime, by a model, and it differs every time.** The
same support ticket can legitimately take 3 steps today and 11 tomorrow, with
nothing broken.

That is the whole conceptual leap. Everything strange about agent observability —
no baseline to alert against, failures that are silent and semantic, costs you
cannot predict per request — falls out of that one difference.

**An agent is an LLM in a loop with tools.** 

### This is not theoretical here

Over three hours of live traffic, this stack reported `outcome=ok` on all 45
agent runs while the agent was calling one tool with wrong arguments and then
giving up. No span had `error=true`. Every RED metric was green. The behaviour
was only visible once custom span attributes were persisted and someone went
looking. That is the failure mode this project exists to make legible.

---

## 2. Read the code in this order

The architecture diagram lives in the main [README](../README.md); glance at it
first, then walk the code.

### Stop 1 — `loadgen/tickets.py`

What goes in. Plain customer sentences: *"How long do refunds take to show up on
my card?"*. No API schema, no intent field, no structure.

That is the problem statement. Everything downstream exists because the input is
natural language and the output has to be an action.

### Stop 2 — `orchestrator/app.py`

The **supervisor**: it owns the ticket and decides who should work on it.

- `CLASSIFY_PROMPT` — how you ask a model to pick one label from a list.
- `classify()` — the LLM call. Decorated `@task`, so it becomes a span.
- `handle()` — decorated `@workflow`. The whole ticket: classify, route to one
  worker, accumulate tokens and call counts, emit the per-ticket roll-up, write
  the audit record.
- `_heuristic_intent()` — the deterministic fallback, and worth your attention.

**Why the fallback ordering matters.** It originally keyword-matched, so *"How
long do refunds take?"* matched `refund` and went to the CRM — which knows
nothing about refund timing — instead of the knowledge base, which has exactly
that policy. Result: the knowledge worker received **zero** traffic, half the
architecture was dark, and every ticket still reported `ok`. It now tests
most-specific-first: escalation words, then an explicit `ORD-####`, then
interrogative phrasing, then bare action words.

A routing bug that produces no errors is a very good introduction to this domain.

### Stop 3 — `knowledge-worker/retrieval.py`, then `app.py`

**RAG** (retrieval-augmented generation), the most common enterprise pattern
there is. The model does not know your return policy, so:

1. turn the question into a vector (`llm.embed`)
2. find the nearest documents in Qdrant (`search`)
3. paste them into the prompt and instruct the model to answer *only* from those

`retrieval.py` is the whole idea in about 50 lines. In `app.py`, note `retrieve()`
putting `rag.top_score` on the span, and `answer()` refusing to answer at all when
the best match is below `MIN_SCORE`.

**That refusal is the cheapest real guardrail in this repo.** The alternative is
a model inventing a returns policy, fluently, with a 200 OK.

### Stop 4 — `action-worker/app.py`, the loop inside `act()`

```python
for step in range(Config.MAX_STEPS):
    decision, step_tokens, decided_by, why = planner.next_step(...)
    if decision.get("done"):
        break
    result = invoke(name, args, ticket_id, customer_id)
    history.append({"tool": name, "args": args, "result": result})
else:
    terminated = "max_steps"
```

**This loop is the agent.** Everything else in this repository is plumbing around
it. Three things to notice:

- **`history` is the loop closing.** The result of step *n* is fed back into the
  decision for step *n+1*. That is the entire difference between an agent and a
  script: a script has its sequence fixed in advance.
- **`MAX_STEPS` exists at all.** An agent that cannot work out it is finished
  runs forever. A budget is the only control that always works — everything else
  depends on noticing first. `terminated = "max_steps"` is a *silent* failure:
  the customer gets a partial answer and nothing errors.
- **Deciding and doing are separate.** `next_step()` only chooses; `invoke()`
  acts. The gap between them is where the approval gate fits.

### Stop 5 — `action-worker/planner.py`

How the agent decides, and — more useful — **what to do when the model decides
badly**.

- `next_step()` — asks the model first, falls back to deterministic rules.
- `validate_args()` — checks the model's proposed arguments against the JSON
  schema the MCP server advertises.

**Why `validate_args` exists.** Measured over three hours of real traffic,
qwen:0.5b produced usable arguments for `lookup_order` **2 times out of 51**. It
mostly proposed `{"id": "C-7"}` — a customer id, under a parameter name the tool
does not have. The tool signature is `lookup_order(order_id: str)`.

The general lesson is worth more than the code:

> **Well-formed is not the same as sensible.**

The original fallback only triggered when the model's output was *unusable*. But
`{"tool": "lookup_order", "args": {"id": "C-7"}}` is valid JSON naming a real
tool — so it was accepted, sent, and failed at the server. The fix is to hold the
model to the contract the server already publishes. Rejections are recorded as
`step.fallback_reason` (`missing:order_id`, `unknown_tool`, `unparseable`).

- `PLANNER_MODE` — `model` (default) or `rules`. In `rules` the model is not
  consulted for tool selection at all. It exists because a small local model
  rarely reaches a consequential tool, so the approval path is otherwise not
  demonstrable. Every step it decides is tagged `step.decided_by=fallback`, so a
  rules-driven run can never be passed off as model reasoning.

**Honest limit:** validation fixes bad *arguments*. It does not fix a model that
answers `{"done": true}` after one step — that is well-formed and in-contract, so
it is still accepted. Only `PLANNER_MODE=rules` addresses that.

### Stop 6 — `mcp-crm/server.py`

**Tools.** A tool is a function plus a description the model can read. The model
names one and supplies arguments; your code executes it.

`@mcp.tool()` turns a plain Python function into one. `CONSEQUENTIAL` lists the
tools that move real money — stated once, next to the tools themselves, rather
than in a prompt a model could argue its way around.

**MCP** (Model Context Protocol) is just a standard for exposing those functions
over a network instead of hardcoding them into the agent. Here it runs over
Streamable HTTP, which is why trace context can cross the hop at all.

### Stop 7 — `approvals/app.py`

Human-in-the-loop: the gate in front of anything consequential.

`_maybe_auto_decide()` is a simulated reviewer — it approves after
`AUTO_APPROVE_AFTER_S`, but **never** above `AUTO_APPROVE_MAX_EUR`, so one path
always genuinely waits for a person. With auto-approve on, the gate proves
nothing about governance; it is a timer wearing a reviewer's hat. That is stated
in the README rather than glossed.

The observability point: the wait gets its own span and its own metric. Both are
on the worker's side of the gate, not in this file:

- **span:** `approval_wait`, opened in `action-worker/approvals.py`
  `request_and_wait()`, carrying `approval.decision`, `.decided_by`, `.waited_ms`
- **metric:** `o11yag.approval.wait`, a histogram by `tool` and `decision`,
  recorded through `o11y.approval_waited()` in `action-worker/o11y.py`

Without them the wait is still measured, just inside the wrong numbers. The
orchestrator is blocked for as long as the reviewer thinks, so every second lands
in `o11yag.task.latency` (wall clock per ticket), and stretches the agent and
tool-call spans above it. Take 95 tickets the machine finishes in ~3 s and 5
refunds a person sits on for ~20 minutes (illustrative figures, not measured):

| | Wait mixed in | Machine time only |
|---|---|---|
| mean | ~63 s | ~3 s |
| p95 / p99 | ~20 min | ~3–4 s |

A latency alert then fires whenever someone takes their time, a model that slows
from 3 s to 8 s disappears under the outliers, and "why are tickets slow?" has no
answer. Kept apart, they are two questions for two owners: `o11yag.approval.wait`
is staffing, and task latency minus it is engineering.

---

## 3. One request, end to end

For a refund ticket, the path through the code:

```
loadgen                POST /chat
orchestrator           handle()            @workflow "support_ticket"
  ├─ classify()        @task               LLM: which intent?
  └─ delegate()        @task               HTTP → action worker
action-worker          act()               @agent
  ├─ planner.next_step()                   decide: lookup_order(ORD-1001)
  ├─ invoke()          @tool               → MCP → mcp-crm executes it
  ├─ planner.next_step()                   decide again, now knowing the total
  ├─ invoke()          @tool               issue_refund — consequential!
  │    └─ approvals.request_and_wait()     BLOCKS until a decision
  │         └─ mcp_client.call_tool()      only if approved
  └─ summarise                             LLM: tell the customer what happened
orchestrator           roll-up + audit record
```

The decorators are not decoration: that tree *is* the trace you see in Dynatrace.

---

## 4. Vocabulary

| Term | What it actually is |
|---|---|
| **Agent** | An LLM in a loop with tools |
| **Tool / function calling** | The model names a function and its arguments; your code runs it |
| **Tool schema** | The contract a tool publishes — validate the model against it |
| **RAG** | Retrieve relevant documents, paste into the prompt, answer only from those |
| **Grounding** | Answering from supplied facts rather than training data |
| **Context window** | Working memory limit, in tokens. Everything competes for it |
| **Token** | Roughly ¾ of a word. The billing unit and the limit unit |
| **Embedding** | Text → vector, so "similar meaning" becomes "close together" |
| **Orchestrator / supervisor** | An agent whose job is routing to other agents |
| **MCP** | A protocol for exposing tools to agents over a network |
| **Hallucination** | Confident, fluent, wrong — your 200 OK with a bad answer |

---

## 5. Try it

```
kubectl port-forward service/o11yag-orchestrator 8000:8000 -n o11yag-otel

curl -X POST http://localhost:8000/chat -H 'Content-Type: application/json' \
  -d '{"ticket_id":"LEARN-1","customer_id":"C-7","tenant":"acme",
       "text":"I want a refund for order ORD-1001, the headphones stopped working."}'
```

Then open the trace in Dynatrace and read it top to bottom. Reading one trace
teaches more in five minutes than the code does in an hour, because you watch the
loop iterate.

Things to look for:

| Attribute | What it tells you |
|---|---|
| `agent.loop.steps` | How many iterations this ticket actually took |
| `agent.loop.terminated` | `done`, or `max_steps` — the silent partial answer |
| `agent.loop.repeated` | Same tool, same arguments, twice. No error, just waste |
| `step.decided_by` | Model or deterministic rules |
| `step.fallback_reason` | *Why* the model was overruled |
| `gen_ai.tool.call.arguments` | What the model actually proposed |
| `rag.top_score` | Whether retrieval gave the answer anything to stand on |
| `quality.verdict` / `.decided_by` | Whether the answer was supported by its extracts, and who decided |
| `security.injection.detected` | A retrieved document that carried instructions |
| `mcp.tools.digest` / `.changed` | The tool catalogue's fingerprint, and whether it moved |

The governance path — a refund reaching the gate, waiting, getting approved, and
changing the system of record — already runs in `model` mode, but only by
accident: when the model's step is rejected, the rules take over and go on to
`issue_refund`. The model itself has never proposed a refund (0 of 862 measured,
see the README's limits section); when it answers `done` early, no refund
happens. To see the path on every ticket, set `PLANNER_MODE: "rules"` on the
action-worker ConfigMap and restart it.
Set it back to `model` afterwards; `rules` is a demo aid, not an honest default.

---

## 6. What this codebase learned the hard way

Each of these cost real debugging time and is documented where it bites:

- **Dynatrace does not persist custom span attributes by default.** It accepts
  them and drops them, naming the casualties in
  `supportability.non_persisted_attribute_keys` — including everything
  OpenLLMetry emits. Metrics are a separate pipeline, so the dashboard looks
  healthy while the traces are hollow.
- **`traceloop-sdk` imports `httpx` without declaring it**, and nothing else in a
  modern LLM stack still pulls httpx in (`openai` 3.x and `mcp` 2.x both moved to
  `httpx2`). Every service lists it explicitly.
- **Trace context crosses the MCP hop in the JSON-RPC envelope, not the HTTP
  headers.** The SDK injects it into `_meta` (SEP-414) and the server's own
  middleware reads it back, so the tool call is parented for free — over stdio
  too. What is *not* free is the HTTP layer underneath: the MCP SDK speaks
  `httpx2` and the OTel httpx instrumentation does not see it, so without the
  hand-injection in `mcp_client.py` the `POST /mcp` and `DELETE /mcp` spans root
  traces of their own.
- **The MCP server validates the `Host` header** and auto-allows only localhost,
  so in Kubernetes everything returns 421 until the Service name is allow-listed.
- **`startupProbe.timeoutSeconds` defaults to one second**, which is not enough
  for Traceloop's imports — healthy pods were being killed at 60s.

The pattern across all of them: everything static passed — manifests parsed,
Python compiled, queries validated — and the system still misbehaved at runtime.
For this kind of stack the fragile parts are the dependency graph and the
backend's ingest rules, not the code.

---

## 7. Where to go next

The main [README](../README.md) covers the four observability gaps, the full
signals reference, and what the project deliberately does not do.

Gap 1 — silent semantic failure — now has a signal rather than a hole:
[`UPDATE-GAPS-1-2.md`](UPDATE-GAPS-1-2.md) walks the judge that grades an answer
against the extracts it was given, the feedback endpoint that is the only input
the stack cannot generate about itself, and the security act — indirect prompt
injection through the corpus, tool poisoning, and the rug pull. It also says
which parts of all that have been verified and which have only been written.
