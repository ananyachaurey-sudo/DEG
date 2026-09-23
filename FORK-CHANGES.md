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
| _none yet_ | | | | |

## Files added by this fork

| Path | Purpose |
|------|---------|
| `.github/workflows/policy-checks.yml` | Runs both demand flexibility policies against every shipped fixture. Two jobs: `conformance` asserts what should be true, and must stay green; `known-defects` asserts that the documented defects are still present, so it turns red when one is fixed. |
| `FORK-CHANGES.md` | This file. |

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
