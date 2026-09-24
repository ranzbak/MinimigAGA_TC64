# findings/ap040-pipelined

The pipelined 68040 core (`nonarkitten/AP68040`, branch `pipelined`) on its way to replacing the `lib/AP68040` reference core in this Minimig. Separate from `findings/ap68040/`, which is the reference core's own history.

Read in this order:

1. `PLAN.md` — the implementation, test and verification plan an executing agent works through milestone by milestone. Its STATUS block at the top says where the work stands; section 7.1 holds the divergences table (manual vs cores vs UAE); section 9 the open questions for Paul.
2. `assessment.md` — the 2026-09-21 gap analysis the plan is built on: reference-core inventory, pipelined-branch inventory, gap table with file:line, effort, reuse analysis (section 8) and the six-stage decision (section 9).
3. `tests/` — the differential trace harness (pipelined vs reference), four red benches for known gaps, and `run_all.sh`; see `tests/README.md`.

Nothing here is committed by the agent; Paul reviews and commits.

- [SESSION-HANDOVER.md](SESSION-HANDOVER.md) — coordination state, rulings, and the live board failure; read after PLAN.md when resuming in a new session.
