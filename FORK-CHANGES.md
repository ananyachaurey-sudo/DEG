# Fork changes

This is a fork of [beckn/DEG](https://github.com/beckn/DEG), taken at
upstream commit `54a5c7b`. It exists to prototype and verify fixes for
defects found in the demand flexibility devkit.

**Nothing here has been accepted upstream.** Treat this fork as a
proposal with working evidence, not as a release.

## How to see exactly what changed

From a clone of this fork:

    git remote add upstream https://github.com/beckn/DEG.git
    git fetch upstream main
    git diff upstream/main

The CI workflow runs the equivalent on every push and prints the result,
so the Actions log always carries an up-to-date summary of how this fork
differs from upstream.

## Conventions

Every edit to an upstream file carries an ID of the form `FC-nnn`, which
appears in three places: a row in the table below, a marked block in the
file itself, and the commit message that introduced it. CI fails if an
ID appears in the code but not in this file.

A marked block in a `.rego` file looks like this:

    # --- FORK EDIT FC-001 ----------------------------------------
    # Upstream  : what the code said before
    # Change    : what it says now
    # Rationale : why
    # Register  : FORK-CHANGES.md FC-001
    # -------------------------------------------------------------

Files that are new in this fork carry no markers, since the whole file
is an addition. They are listed separately below.

Each change is developed on its own branch, named after its ID, so that
it stays independently reviewable and can be offered upstream on its own
if it is ever accepted.

## Changes to upstream files

| ID | File | Change | Rationale | Status |
|----|------|--------|-----------|--------|
| FC-001 | `specification/policies/demand-flex-networkpolicy.rego`<br>`specification/policies/demand-flex-contractpolicy.rego` | Network policy: rule 5b requires `CAPACITY_REQUESTED` by presence instead of pinning the need column set exactly; rule 5c removed; new rule 6 requires parallel `values` arrays within an interval to be equal length. Contract policy: new violation requiring `PRICE` and `SHORTFALL_PENALTY` on the need from `confirm` onward. | An exact-set check asserts a column set is complete, which defines a product rather than testing coherence. The two locks reject 11 of 12 bid-curve fixtures shipped in the same devkit, before they reach their own contract policy. Posted-price terms move to the product that depends on them. Follows the P2P network policy, which uses presence checks throughout. | Applied, verified in CI |

## Files added by this fork

| Path | Purpose |
|------|---------|
| `.github/workflows/policy-checks.yml` | Runs both demand flexibility policies against every shipped fixture. Two jobs: `conformance` asserts what should be true, and must stay green; `known-defects` asserts that the documented defects are still present, so it turns red when one is fixed. |
| `FORK-CHANGES.md` | This file. |

## Known limits of these changes

**Terms can still be changed, only not added late.** FC-001 requires
posted-price terms to be complete by `confirm`. It cannot detect a term
that is altered afterwards — a shortfall penalty of 2.00 at `confirm`
becoming 5.00 at `on_status` produces two individually well-formed
messages. Policy evaluation is stateless and has no memory of what was
agreed.

Closing this needs either the application comparing against its stored
contract, or a digest of the agreed commercial terms carried in the
contract and re-verified on each message. The devkit already uses a
content digest for meter cohorts, so the pattern exists.

This gap is pre-existing. The removed column lock prevented late
*addition* as a side effect of pinning the set, but never prevented
*alteration*. Relaxing it makes the gap more visible without widening it.

## Verified findings

These were confirmed by running the policies with OPA, not by reading
the source. The `known-defects` job reproduces each of them on every
push.

**Settlement.** The shipped curtailment fixtures settle to 436.25 INR,
with violations empty. The demand flexibility implementation guide
states 525, a figure that is not reachable from the terms the same
guide gives.

**Column rules.** 11 of 12 bid-curve fixtures are rejected by the
shared network policy, while 15 of 15 curtailment fixtures pass
cleanly. Three rule families fire: two that compare column sets with
exact equality, and one that requires the committed-capacity column at
a fixed stage of the conversation. The rejected messages never reach
the bid-curve contract policy, which implements the correct column
rules for that product.

**Pagination.** Both paginated fixtures declare `isLast: false` with a
stated total of 12,000 meters, carry 2 meters, and still produce a full
settlement of 436.25. One of them is not even the first page.

## Related documents

Analysis supporting these changes is held outside this repository:
a register of deficiencies in the current devkit, and a draft
specification for an expanded one.
