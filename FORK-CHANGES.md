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

The CI workflow runs the equivalent on every push, so the Actions log
always carries an up-to-date summary of how this fork differs.

## Conventions

Every edit to an upstream file carries an ID of the form `FC-nnn`, which
appears in three places: a row in the table below, a marked block in the
file itself, and the commit message. CI fails if an ID appears in the
code but not in this file.

A marked block in a `.rego` file looks like this:

    # --- FORK EDIT FC-001 (demand-flex-networkpolicy.rego) --------
    # Upstream  : what the code said before
    # Change    : what it says now
    # Rationale : why
    # Register  : FORK-CHANGES.md FC-001
    # -------------------------------------------------------------

The marker names its own file, because the same ID may touch several and
a block pasted into the wrong module will not compile.

Each change is developed on a branch named after its ID. Files added by
this fork carry no markers and are listed separately.

## The test applied to every network-layer rule

> Would this rule still be true for a product nobody has invented yet?

A network rule states a floor every message must clear. A rule that
states a ceiling — that a column set is complete, or that all arrays
correlate — defines a product, and belongs in that product's contract
policy. This test identified FC-001, and it caught a rule being wrongly
reintroduced while FC-001 was being written (see Known limits).

## Changes to upstream files

| ID | File | Change | Rationale | Status |
|----|------|--------|-----------|--------|
| FC-001 | `specification/policies/demand-flex-networkpolicy.rego`<br>`specification/policies/test/demand-flex-networkpolicy_test.rego` | Rule 5b requires `CAPACITY_REQUESTED` by presence instead of pinning the need column set exactly. Rule 5c removed. Stage legend and rule index updated. Two tests asserting the removed locks replaced with three covering presence and permitted extra columns. | An exact-set check asserts a column set is complete, which defines a product rather than testing coherence. The two locks rejected 11 of 12 bid-curve fixtures shipped in the same devkit, before they reached the bid-curve contract policy that implements the correct rules for that product. Price and penalty are product terms and move to the product that depends on them. Follows the P2P network policy, which uses presence checks throughout. | Applied on `fc-001-column-presence`. Verified: bid-curve rejections 11 → 3, all three now rule 3a; 15 of 15 curtailment fixtures unchanged; settlement unchanged at 436.25; unit tests 113 → 114. |

### Carried over from FC-001

Three bid-curve fixtures remain rejected after FC-001, all by rule 3a,
all for the same reason — no `CAPACITY_OFFERED` column is declared at
all:

- `uc2-bid-curve-pac/examples/init-request.json`
- `uc2-bid-curve-pac/examples/on-init-response.json`
- `uc2-bid-curve-pac/examples/on-status-response-resource-telemetry.json`

Rule 3a is correct and unchanged: an aggregator that reaches `init`
without stating what it is offering has offered nothing, and the utility
cannot assemble a draft contract at `on_init` from it. The fixtures are
the defect. Addressed as FC-002, which also moves bidding in a
discovered-price event from `confirm` to `init`.

## Files added by this fork

| Path | Purpose |
|------|---------|
| `.github/workflows/policy-checks.yml` | Runs both demand flexibility policies against every shipped fixture. `conformance` asserts what should be true; `known-defects` asserts the current state of documented defects, so it goes red when one is fixed. |
| `FORK-CHANGES.md` | This file. |

## Verified findings

Confirmed by running the policies with OPA, not by reading them.

**Settlement.** The shipped curtailment fixtures settle to 436.25 INR,
violations empty. The implementation guide states 525, a figure not
reachable from the terms the same guide gives.

**Column rules.** 11 of 12 bid-curve fixtures are rejected by the shared
network policy; 15 of 15 curtailment fixtures pass. Three rule families
fire: two comparing column sets with exact equality, and one requiring
the committed-capacity column at a fixed stage. Rejected messages never
reach the bid-curve contract policy, which implements the correct column
rules for that product.

**Pagination.** Both paginated fixtures declare `isLast: false` with a
stated total of 12,000 meters, carry 2 meters, and still settle to the
full 436.25. One is not even the first page.

## Known limits

**A rule withdrawn before it shipped.** A network rule requiring all
parallel `values` arrays within an interval to be equal length was
drafted and removed. A bid curve carries several tranches
(`OFFER_PRICE` and `CAPACITY_OFFERED`, four entries each) while its
clearing result is a scalar (`CLEARING_PRICE`, one entry), so differing
lengths in one interval are legitimate. Positional correspondence holds
between specific declared columns, which is product knowledge. Deferred
to the bid-curve contract policy.

**Commercial terms can be revised, not just added late.** Terms are
restated at `on_select`, `on_init` and `on_confirm`, each in a signed
message the counterparty retains, so a revision is non-repudiable and
visible before signing. Policy evaluation is stateless and cannot refuse
the revised message, so detection rests on the counterparty comparing
terms across messages. A digest of published terms carried in the
contract would make refusal automatic, as the bid-curve clearing audit
already does for clearing price. Not proposed for this version.

## Related documents

Analysis supporting these changes is held outside this repository: a
register of deficiencies in the current devkit, and a draft
specification for an expanded one.
