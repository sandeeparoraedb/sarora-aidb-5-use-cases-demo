# Demo 3 -- App Intelligence: catch billing errors before they cost money

**EDB capability:** AIDB (in-database inference)
**AI Factory framing:** "Classify, mask, enrich, and score data inline in SQL, with governance, alerting, observability, and auditing built in. Inference happens inside the DB -- lower latency, lower cost, no data leaving the environment."

## The business problem this solves

Persona: **billing / finance analyst** (per the seed use-cases deck's actor
map: "Revenue per move, demurrage & penalty exposure, invoice queries" up to
the Regional CFO).

Every billing error today is found the same way: a customer notices and
disputes it. Nobody at NorthStar Terminals proactively checks whether an
invoice was actually billed at the contracted rate, so both overcharges (the
terminal owes a credit) and undercharges (the terminal is owed revenue it
never collected) sit quietly until reconciliation catches them -- or until
the customer's own finance team catches them first, which is worse. That's
the gap this demo closes: find the error before it costs money, not after.

## What it demonstrates

This is the same shape as demo 2's Ops Copilot -- proactive scan, AI
diagnosis, human approve/reject, then prove the real benefit -- pointed at
revenue instead of query latency:

1. **Proactive scan, no manual input** (`app_intel_scan()`) -- checks every
   billing line item against `tariff_rates` (the contracted standard rate
   per terminal + tariff code) and against recent charge history for the
   same container/move/tariff combination, and flags two kinds of anomaly:
   a **rate deviation** (billed materially above or below the contracted
   rate) or a **duplicate charge** (the same move billed twice within two
   weeks). Ranked worst-first by dollar variance.
2. **AI diagnosis** (`app_intel_diagnose()`) -- one `aidb.decode_text()`
   call per flagged invoice explains, in plain business language, why it's
   worth correcting and what the fix should be -- credit the customer,
   recover a shortfall, or void a duplicate.
3. **Human approve / reject** (`app_intel_approve()` / `app_intel_reject()`)
   -- nothing changes in `billing_events` until a named reviewer approves.
   Approving records the correction in `corrected_usd` /
   `correction_status` (the original `amount_usd` is never overwritten, so
   the original bill stays auditable) and captures the real dollar benefit
   in `app_intel_recommendations.applied_credit_usd`. Rejecting leaves the
   invoice completely untouched.
4. **Governance, folded in as a supporting proof, not a separate demo** --
   classification/risk-scoring of customer-*reported* disputes
   (`classify_and_score_dispute()` / `run_dispute_triage()`), deterministic
   masking of structured PII, AI-powered redaction of PII buried in
   free text (`redact_free_text()`), and `ai_audit_log` logging every model
   call. All still here, all still real -- just no longer competing with
   the main story for attention.

## Running it

Install (idempotent -- safe to re-run any time; `demos/` is bind-mounted
read-write from the host, so edits take effect on the next re-run with no
image rebuild or volume reset needed):

```bash
docker compose exec epas psql -U postgres -d mydb -f /opt/demos/03-app-intelligence/app_intelligence.sql
```

1. **Scan for anomalies nobody has flagged yet:**

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c "SELECT * FROM app_intel_scan();"
   ```

   Five planted anomalies should come back, ranked by `variance_usd` --
   a duplicate charge, an overbilled demurrage line, an overbilled
   weighbridge adjustment, an underbilled import move, and an overbilled
   rehandle -- against a background of ~55 correctly-billed invoices they
   have to stand out from.

2. **Diagnose one and see the AI's recommendation:**

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT app_intel_diagnose('INV-89100');"
   ```

3. **Approve it and see the real benefit captured** (replace `1` with the
   `recommendation_id` from step 2, and `'Your Name'` with a reviewer):

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT app_intel_approve(1, 'Your Name');"
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT invoice_id, amount_usd, corrected_usd, correction_status FROM billing_events WHERE invoice_id = 'INV-89100';"
   ```

4. **Or reject it** and confirm nothing changed:

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT app_intel_reject(1, 'Your Name');"
   ```

5. **Governance callout** -- known, customer-reported disputes; masking;
   redaction; audit log:

   ```bash
   docker compose exec epas psql -U postgres -d mydb -c "CALL run_dispute_triage();"
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT invoice_id, customer_contact_masked, dispute_category FROM billing_events_masked WHERE dispute_flag;"
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT redact_free_text('Please call our contact Daniel Osei directly on +971 50 123 4567 to discuss -- we were quoted a 15% rebate on this lane last quarter and expect the same here.');"
   docker compose exec epas psql -U postgres -d mydb -c \
     "SELECT called_at, function_name, subject_id, output_summary FROM ai_audit_log ORDER BY called_at DESC LIMIT 10;"
   ```

## Talking points for the room

- Open with the dollar number, not the mechanism: "this scan just found
  $X in billing errors nobody had noticed yet." That's the concrete tie
  back to the value-driver slide's "catch billing errors before they cost
  money" -- said in dollars, not in feature names.
- Name-check the Ops Copilot parallel explicitly: same scan -> diagnose ->
  approve/reject shape, same human-in-the-loop guarantee, different target
  (revenue instead of latency). One governed pattern, reused -- not two
  unrelated capabilities.
- The masking split (deterministic vs. AI) is still a good moment to show
  judgment rather than "AI for everything," and `ai_audit_log` is still the
  direct answer to the deck's governance question ("how are agents
  audited?") -- just don't lead with it. It's the "how this stays safe"
  footnote to the revenue story, not the headline.
- (Note: by default the text-generation step itself calls out to
  OpenRouter -- see the top-level README -- so "never left Postgres" is
  true of the orchestration and data, not the network path for that one
  call. Switch `my_summarizer` to the local model in
  `sql/02-aidb-models.sql` if you want that claim to be literally true
  end-to-end for this demo.)
