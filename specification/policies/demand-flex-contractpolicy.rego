# DEG Contract Policy — Demand Flex Revenue Flows (per-interval, per-meter)
#
# The utility (buyer) publishes a DemandFlexNeed time series — one interval per
# tranche, carrying per-slot PRICE and SHORTFALL_PENALTY (and CAPACITY_REQUESTED,
# which is a discovery signal only and NOT used here). The aggregator (seller)
# adds a CAPACITY_OFFERED column on Commitment.commitmentAttributes. Per-meter
# BASELINE / USAGE telemetry arrives on DemandFlexPerformance. All three series
# share one intervalPeriod grid and join on interval id.
#
# Settlement is UTILITY-ONLY and PER-METER, summed per interval:
#   delivered_i = Σ_meter clamp0(BASELINE_i − USAGE_i)          (aggregate kW)
#   eligible_i  = min(delivered_i, CAPACITY_OFFERED_i)
#   pay_i       = eligible_i × durationHours × PRICE_i
#   penalty_i   = clamp0(CAPACITY_OFFERED_i − delivered_i) × durationHours × SHORTFALL_PENALTY_i
#   net_i       = pay_i − penalty_i          →   total = Σ net_i
#
# buyer pays (negative), seller receives (positive), net zero.
# EnergyResource telemetry (methodology RESOURCE_TELEMETRY) is reconciliation-
# only and excluded from settlement.
#
# Exported: revenue_flows, settlement_components, total_settlement,
#           net_zero_ok, violations.

package deg.contracts.demand_flex

import rego.v1

# non-settlement methodologies — perf records authored by the seller's
# EnergyResource fleet (out-of-band vendor APIs), excluded from settlement.
_non_settlement_methodologies := {"RESOURCE_TELEMETRY"}

# --------------------------------------------------------------------------
# Input extraction
# --------------------------------------------------------------------------

_commitment := input.message.contract.commitments[0]

# DemandFlexNeed time series — buyer's CAPACITY_REQUESTED / PRICE / SHORTFALL_PENALTY
_need := _commitment.resources[0].resourceAttributes

# commitment series — seller's CAPACITY_OFFERED column
_offered := _commitment.commitmentAttributes

_buyer_inputs := [i.inputs | some i in _commitment.offer.offerAttributes.inputs; i.role == "buyer"][0]

_currency := object.get(_buyer_inputs, "currency", "INR")

# first settlement-eligible performance record (utility M&V, not RESOURCE_TELEMETRY)
_settlement_perf := perf if {
	some perf in input.message.contract.performance
	not perf.performanceAttributes.methodology in _non_settlement_methodologies
}

_meters := _settlement_perf.performanceAttributes.meters

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# scalar value of payload `ptype` at interval `ivid` in a series' intervals[]
_val(intervals, ivid, ptype) := v if {
	some iv in intervals
	iv.id == ivid
	some p in iv.payloads
	p.type == ptype
	v := p.values[0]
}

_clamp0(x) := x if x >= 0

_clamp0(x) := 0 if x < 0

_numz(s) := to_number(s) if s != ""

_numz("") := 0

# duration of one interval in hours, parsed from ISO 8601 (PT#H / PT#M / PT#H#M)
_dur_hours := h if {
	m := regex.find_all_string_submatch_n(`^PT(?:([0-9]+)H)?(?:([0-9]+)M)?$`, _need.intervalPeriod.duration, 1)[0]
	h := _numz(m[1]) + (_numz(m[2]) / 60)
}

# --- FORK EDIT FC-008 (demand-flex-contractpolicy.rego) ----------------
# Upstream  : _meter_reduction(meter, ivid) := _clamp0(base - use)
#             — reduction only, with no way to settle a load increase.
# Change    : renamed to _meter_delta, with two bodies branching on the
#             direction declared on the need.
# Rationale : The offer schema claimed a negative PRICE column paid for
#             increased consumption, and gave that as the reason no
#             direction field existed. No settlement policy ever
#             implemented it. It is also insufficient in principle: the
#             settlement RULE changes, not merely the sign of its result.
#             A reduction-only calculation multiplied by a negative price
#             yields a negative payment for a reduction, not a positive
#             payment for an increase — so an aggregator that correctly
#             raised consumption would measure as having delivered
#             nothing, earn nothing, and take the full shortfall penalty.
#             Direction is therefore declared on the need. Unlike
#             procurement mode, which needs no field because two contract
#             policies already exist and the policy URL declares which
#             applies, direction has no such carrier: a separate absorb
#             policy would duplicate settlement arithmetic differing in
#             one operator, which is the last thing that should be
#             allowed to drift.
#             Everything downstream — eligible, payment, shortfall,
#             penalty, revenue flows — is direction-agnostic and unchanged.
#             SHORTFALL_PENALTY keeps its meaning: committed minus
#             delivered, floored at zero. For ABSORB that is failing to
#             consume as much as committed.
#             Defaults to SHED when the attribute is absent, so every
#             existing need settles exactly as before.
# Register  : FORK-CHANGES.md FC-008
# -----------------------------------------------------------------------

_direction := d if {
	d := _need.direction
}

_direction := "SHED" if not _need.direction

# per-meter clamped delta at an interval, in the declared direction;
# undefined if BASELINE or USAGE absent
_meter_delta(meter, ivid) := _clamp0(base - use) if {
	_direction == "SHED"
	base := _val(meter.telemetry.intervals, ivid, "BASELINE")
	use := _val(meter.telemetry.intervals, ivid, "USAGE")
}

_meter_delta(meter, ivid) := _clamp0(use - base) if {
	_direction == "ABSORB"
	base := _val(meter.telemetry.intervals, ivid, "BASELINE")
	use := _val(meter.telemetry.intervals, ivid, "USAGE")
}

_delivered(ivid) := sum([_meter_delta(m, ivid) | some m in _meters])

# S5 (FC-008) — an unrecognised direction must not settle silently as SHED.
violations contains msg if {
	_need.direction
	not _need.direction in {"SHED", "ABSORB"}
	msg := sprintf("unrecognised direction %v on DemandFlexNeed — expected SHED or ABSORB", [_need.direction])
}

# --- end FORK EDIT FC-008 ----------------------------------------------

# --------------------------------------------------------------------------
# Per-interval settlement
# --------------------------------------------------------------------------

_settle[ivid] := row if {
	some iv in _need.intervals
	ivid := iv.id
	price := _val(_need.intervals, ivid, "PRICE")
	penalty_rate := _val(_need.intervals, ivid, "SHORTFALL_PENALTY")
	offered := _val(_offered.intervals, ivid, "CAPACITY_OFFERED")
	delivered := _delivered(ivid)
	eligible := min([delivered, offered])
	pay := (eligible * _dur_hours) * price
	penalty := (_clamp0(offered - delivered) * _dur_hours) * penalty_rate
	net := pay - penalty
	row := {
		"id": ivid, "price": price, "offered": offered,
		"delivered": delivered, "eligible": eligible,
		"pay": pay, "penalty": penalty, "net": net,
	}
}

settlement_components := [comp |
	some ivid
	s := _settle[ivid]
	line_id := sprintf("slot-%d", [ivid])
	summary := sprintf("slot %d: min(%v delivered, %v offered) kW x %vh x %v %s/kWh - penalty %v", [ivid, s.delivered, s.offered, _dur_hours, s.price, _currency, s.penalty])
	comp := {"lineId": line_id, "lineSummary": summary, "value": s.net, "currency": _currency}
]

total_settlement := sum([s.net | some ivid; s := _settle[ivid]])

_slot_count := count(_settle)

_buyer_value := total_settlement * -1

_buyer_desc := sprintf("Net payable across %d flex slots", [_slot_count])

_seller_desc := sprintf("Net receivable across %d flex slots", [_slot_count])

# internal net flows — always defined (0 when nothing settles yet)
_revenue_flows := [
	{"role": "buyer", "value": _buyer_value, "currency": _currency, "description": _buyer_desc},
	{"role": "seller", "value": total_settlement, "currency": _currency, "description": _seller_desc},
]

# Exported for injection ONLY when a settlement-eligible performance record is
# present. Pre-settlement (select / init / confirm) this rule is UNDEFINED, so a
# contractpolicyenforcer step still evaluates `violations` (enforcement) but
# finds no `revenue_flows` and skips injection — no zero-value settlement
# artifact is written onto a pre-settlement contract. net-zero and _revenue_sum
# key off the always-defined _revenue_flows, so their semantics are unchanged.

# --- FORK EDIT FC-004 (demand-flex-contractpolicy.rego) ----------------
# Upstream  : revenue_flows := _revenue_flows if _settlement_perf
# Change    : also requires the performance collection to be complete.
# Rationale : Performance records may be paginated across messages for
#             cohorts in the thousands. Nothing read pageInfo, so a single
#             page settled as though it were the whole cohort.
#             Measured at upstream 54a5c7b: both paginated fixtures
#             declare isLast=false against a stated total of 12,000
#             meters, carry 2 meters, and produce a full settlement. One
#             is sequence 1 with a cursor pointing at page 3 — not even
#             the first page. A genuine page 0 of 3 would settle at
#             roughly a third of the true amount, signed and silently
#             wrong, surfacing as a reconciliation dispute months later.
#             Uses the mechanism already present for pre-settlement
#             contracts: leave revenue_flows undefined so the enforcer
#             injects nothing, rather than writing a wrong figure. The
#             internal _revenue_flows stays unconditional so net_zero_ok
#             is unaffected.
#             pageInfo is optional. A record without it is unpaginated
#             and complete by definition.
#             Known limit: this refuses a page that declares itself
#             incomplete. It cannot detect that earlier pages were lost —
#             a final page arriving after two were dropped looks complete.
#             Assembly is the receiver's responsibility.
# Register  : FORK-CHANGES.md FC-004
# -----------------------------------------------------------------------

# True when this performance record is not a partial page: either it
# carries no pageInfo at all, or pageInfo marks it as the last page.
_collection_complete if not _settlement_perf.performanceAttributes.pageInfo

_collection_complete if _settlement_perf.performanceAttributes.pageInfo.isLast == true

revenue_flows := _revenue_flows if {
	_settlement_perf
	_collection_complete
}

# --- end FORK EDIT FC-004 ----------------------------------------------

_revenue_sum := sum([f.value | some f in _revenue_flows])

net_zero_ok if _revenue_sum == 0

# --------------------------------------------------------------------------
# Violations — SETTLEMENT ONLY
# --------------------------------------------------------------------------
#
# This rego owns SETTLEMENT correctness only. All universal structural
# well-formedness — participant roles, column locks, CAPACITY_OFFERED
# presence / completeness / grid alignment, meter-grid alignment, interval-id
# sequence, type-coverage and cardinality — lives in the network policy
# (demand-flex-networkpolicy.rego), which runs on every module at every stage
# and is the single source of truth for structure. It is not duplicated here
# (that only invited drift).
#
# The settlement family, each self-skipping when its data is absent:
#     S1  a settlement-eligible performance record exists
#     S2  every meter carries USAGE on every settled slot
#     S3  revenue flows net to zero
#
# S1/S2/S3 legitimately fire on an intermediate on_status (baseline-only or
# resource-telemetry push), which is why the contract policy is enforced only
# where settlement is not yet claimed (select/init/confirm — where these
# self-skip and the fail-closed gate still guarantees a valid, checksummed
# policy reference) and injected/validated on the final settled status —
# never NACK-enforced on on_status.

# S1 — a settlement-eligible performance record exists
violations contains msg if {
	count(input.message.contract.performance) > 0
	not _settlement_perf
	ms := [p.performanceAttributes.methodology | some p in input.message.contract.performance]
	msg := sprintf("no settlement-eligible performance record found — all records are non-settlement (methodologies: %v)", [ms])
}

# S2 — every meter needs USAGE on every settled slot
violations contains msg if {
	some iv in _need.intervals
	some m in _meters
	not _val(m.telemetry.intervals, iv.id, "USAGE")
	msg := sprintf("meter %s: missing USAGE at interval %d — cannot settle", [m.meterId, iv.id])
}

# S3 — buyer/seller revenue flows must net to zero
violations contains msg if {
	not net_zero_ok
	msg := sprintf("net-zero failed: revenue sum = %g (expected 0)", [_revenue_sum])
}

# S4 (FC-004) — settlement must not run on a partial page. Without this the
# refusal above would be silent: revenue_flows simply undefined, with no
# explanation on the wire.
# Register: FORK-CHANGES.md FC-004
violations contains msg if {
	pi := _settlement_perf.performanceAttributes.pageInfo
	pi.isLast != true
	n := count(_settlement_perf.performanceAttributes.meters)
	msg := sprintf(
		"performance collection %v is incomplete (isLast=%v, %d of %v meters in this page) — cannot settle",
		[object.get(pi, "collectionId", "?"), pi.isLast, n, object.get(pi, "total", "?")],
	)
}

# --- FORK EDIT FC-007 (demand-flex-contractpolicy.rego) ----------------
# Change    : new violation — the need must declare a PRICE column.
# Rationale : This policy reads PRICE per interval (_val(_need.intervals,
#             ivid, "PRICE")) but never checked it was declared. That was
#             safe only because the network policy's column lock
#             guaranteed it. FC-001 removed that lock, deliberately: a
#             discovered-price event carries no PRICE at all, and its
#             absence is how such an event declares itself. So the
#             requirement cannot live at the network layer — it belongs
#             to the product that settles against a posted rate, which is
#             this one.
#             Without this, a posted-price need lacking PRICE would reach
#             settlement and simply fail to compute, with no explanation
#             on the wire.
#             Timing: the contract policy is invoked from select/on_select
#             onward — violationActions in the devkit config lists
#             select, init, confirm and their callbacks, never
#             catalog/publish. So a price omitted at publication is caught
#             one round trip later, at the first selection, before
#             anything is committed. Publishing the price at catalogue is
#             an implementation obligation on the utility, not something
#             this layer can enforce.
# Register  : FORK-CHANGES.md FC-007
# -----------------------------------------------------------------------
violations contains msg if {
	_need
	cols := {d.payloadType | some d in _need.payloadDescriptors}
	not "PRICE" in cols
	msg := sprintf("posted-price settlement requires a PRICE column on DemandFlexNeed, got %v", [cols])
}

# --- end FORK EDIT FC-007 ----------------------------------------------
