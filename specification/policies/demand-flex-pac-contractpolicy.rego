# DEG Contract Policy — Demand Flex PAC (Pay-As-Clear) Revenue Flows
#
# Computes the settlement for a bid-curve demand-flex event cleared
# pay-as-clear, and produces signed revenue flows per ROLE:
#
#   buyer  (utility/DISCOM) → pays     → negative value
#   seller (aggregator)     → receives → positive value
#   Sum of all revenue_flows values MUST equal zero (net-zero).
#
# Settlement rule, per market interval:
#
#   delivered_kwh = Σ_meters clamp0(BASELINE − USAGE) × interval_hours
#   cleared_kwh   = CAPACITY_CLEARED × interval_hours
#   payment       = CLEARING_PRICE × min(delivered_kwh, cleared_kwh)
#                   (pay-as-clear: over-delivery is unpaid, under-delivery
#                   pays only what arrived)
#   penalty       = penaltyRate × clamp0(cleared_kwh − delivered_kwh)
#                   (flat currency-per-kWh charge on the shortfall,
#                   from buyer inputs; defaults to 0 when absent)
#
#   seller net = Σ payments − Σ penalties
#
# The seller's bid curve (OFFER_PRICE/CAPACITY_OFFERED step pairs) is NOT re-run
# here — the buyer's published CAPACITY_CLEARED/CLEARING_PRICE are trusted
# for the money math. The curve is only audited: if the clearing price is
# below the cheapest ask that covers the cleared quantity, a `violations`
# entry is emitted (flag, not gate).
#
# Input: full beckn contract payload with:
#   - contractAttributes.roles[].role                  → buyer / seller
#   - commitments[0].offer.offerAttributes.inputs      → penaltyRate, currency (buyer)
#   - commitments[0].commitmentAttributes              → market BecknTimeSeries:
#       per interval OFFER_PRICE[], CAPACITY_OFFERED[], CAPACITY_CLEARED, CLEARING_PRICE
#   - performance[*].performanceAttributes.meters[*]   → per-meter BecknTimeSeries
#       with per-interval BASELINE / USAGE (utility M&V; RESOURCE_TELEMETRY
#       records are reconciliation-only and excluded, as in demand_flex)
#
# Exported rules:
#   revenue_flows          — [{role, value, currency, description}]
#   settlement_components  — per-interval line items (payment / penalty)
#   total_payment          — Σ interval payments
#   total_penalty          — Σ interval penalties
#   seller_net             — total_payment − total_penalty
#   interval_hours         — parsed from intervalPeriod.duration (ISO-8601)
#   net_zero_ok            — bool: sum of revenue_flows == 0
#   violations             — set of error/warning strings

package deg.contracts.demand_flex_pac

import rego.v1

# ---------------------------------------------------------------------------
# Input extraction
# ---------------------------------------------------------------------------

_commitment := input.message.contract.commitments[0]

_market := _commitment.commitmentAttributes

_offer_inputs := _commitment.offer.offerAttributes.inputs

_buyer_inputs := [i.inputs | some i in _offer_inputs; i.role == "buyer"][0]

_currency := _buyer_inputs.currency

# Flat currency-per-kWh charge on undelivered energy. Optional in the offer.
_penalty_rate := object.get(_buyer_inputs, "penaltyRate", 0)

_contract_attrs := input.message.contract.contractAttributes

_roles := {r.role | some r in _contract_attrs.roles}

# Settlement-eligible perf record: utility-authored M&V only (same
# exclusion rule as demand_flex — EnergyResource telemetry never settles).
_non_settlement_methodologies := {"RESOURCE_TELEMETRY"}

_settlement_perf := perf if {
	some perf in input.message.contract.performance
	not perf.performanceAttributes.methodology in _non_settlement_methodologies
}

_meters := _settlement_perf.performanceAttributes.meters

# ---------------------------------------------------------------------------
# Interval duration — ISO-8601 (PTnH / PTnM / PTnS combinations)
# ---------------------------------------------------------------------------

_dur_match := regex.find_all_string_submatch_n(
	`^PT(?:([0-9]+(?:\.[0-9]+)?)H)?(?:([0-9]+(?:\.[0-9]+)?)M)?(?:([0-9]+(?:\.[0-9]+)?)S)?$`,
	_market.intervalPeriod.duration, 1,
)[0]

_num("") := 0

_num(s) := to_number(s) if s != ""

interval_hours := h if {
	h := _num(_dur_match[1]) + (_num(_dur_match[2]) / 60) + (_num(_dur_match[3]) / 3600)
	h > 0
}

# ---------------------------------------------------------------------------
# BecknTimeSeries readers
# ---------------------------------------------------------------------------

# All values of `ptype` in one interval object.
_payload_values(interval, ptype) := [v |
	some payload in interval.payloads
	payload.type == ptype
	some v in payload.values
]

# Single scalar payload (CAPACITY_CLEARED, CLEARING_PRICE carry one value).
_payload_val(interval, ptype) := _payload_values(interval, ptype)[0]

# Mean of a meter's readings for `ptype` within market interval `iid`.
_meter_mean(meter, iid, ptype) := mean if {
	some interval in meter.telemetry.intervals
	interval.id == iid
	vals := _payload_values(interval, ptype)
	count(vals) > 0
	mean := sum(vals) / count(vals)
}

_clamp_zero(x) := x if x >= 0

_clamp_zero(x) := 0 if x < 0

# ---------------------------------------------------------------------------
# Per-interval settlement
#
# An interval settles when the buyer published its clearing result and
# every meter reported USAGE for it.
# ---------------------------------------------------------------------------

_market_interval(iid) := interval if {
	some interval in _market.intervals
	interval.id == iid
}

_cleared_ids := {interval.id |
	some interval in _market.intervals
	_payload_val(interval, "CAPACITY_CLEARED")
	_payload_val(interval, "CLEARING_PRICE")
}

_meter_delivered_kw(meter, iid) := _clamp_zero(_meter_mean(meter, iid, "BASELINE") - _meter_mean(meter, iid, "USAGE"))

_delivered_kw(iid) := sum([_meter_delivered_kw(meter, iid) | some meter in _meters])

_interval_settlement[iid] := result if {
	some iid in _cleared_ids
	every meter in _meters { _meter_mean(meter, iid, "USAGE") }

	interval := _market_interval(iid)
	clearing_price := _payload_val(interval, "CLEARING_PRICE")
	cleared_kwh := _payload_val(interval, "CAPACITY_CLEARED") * interval_hours
	delivered_kwh := _delivered_kw(iid) * interval_hours
	paid_kwh := min([delivered_kwh, cleared_kwh])
	shortfall_kwh := _clamp_zero(cleared_kwh - delivered_kwh)

	result := {
		"clearingPrice": clearing_price,
		"clearedKwh": cleared_kwh,
		"deliveredKwh": delivered_kwh,
		"paidKwh": paid_kwh,
		"payment": paid_kwh * clearing_price,
		"shortfallKwh": shortfall_kwh,
		"penalty": shortfall_kwh * _penalty_rate,
	}
}

# ---------------------------------------------------------------------------
# Settlement components (per-interval line items)
# ---------------------------------------------------------------------------

settlement_components := [comp |
	some iid, s in _interval_settlement
	comp := {
		"lineId": sprintf("pac-interval-%d", [iid]),
		"lineSummary": sprintf("interval %d: %v kWh paid @ %v %s/kWh (delivered %v / cleared %v kWh), penalty %v",
			[iid, s.paidKwh, s.clearingPrice, _currency, s.deliveredKwh, s.clearedKwh, s.penalty]),
		"value": s.payment - s.penalty,
		"currency": _currency,
	}
]

total_payment := sum([s.payment | some _, s in _interval_settlement])

total_penalty := sum([s.penalty | some _, s in _interval_settlement])

seller_net := total_payment - total_penalty

_total_paid_kwh := sum([s.paidKwh | some _, s in _interval_settlement])

_total_shortfall_kwh := sum([s.shortfallKwh | some _, s in _interval_settlement])

# ---------------------------------------------------------------------------
# Revenue flows by role (the core output)
# ---------------------------------------------------------------------------

_desc(label) := sprintf("PAC clearing %s: %v kWh paid as cleared minus %v %s penalty (%v kWh shortfall @ %v %s/kWh)",
	[label, _total_paid_kwh, total_penalty, _currency, _total_shortfall_kwh, _penalty_rate, _currency])

# --- FORK EDIT FC-005 (demand-flex-pac-contractpolicy.rego) ------------
# Upstream  : revenue_flows was an unconditional comprehension. It emitted
#             flows whenever the body resolved — no gate on settlement
#             eligibility, and none on pagination. _revenue_sum and
#             net_zero_ok read it directly.
# Change    : introduces the internal/exported split used by
#             demand-flex-contractpolicy.rego. _revenue_flows is computed
#             unconditionally and feeds the net-zero check. The exported
#             revenue_flows is gated on a settlement-eligible performance
#             record AND a complete performance collection.
# Rationale : Two defects, one fix.
#             (1) Pagination. Performance records may be paginated for
#             cohorts in the thousands and nothing read pageInfo, so a
#             page settled as though it were the whole cohort. FC-004
#             closed this for posted-price settlement; the bid-curve
#             policy had the same blindness.
#             (2) No settlement-eligibility gate at all. The posted-price
#             policy declines to export flows without an eligible
#             performance record. This one exported regardless.
#             Why the split: the exported name is an instruction to the
#             enforcer — undefined means "write nothing". The internal
#             name is what was computed, and the net-zero consistency
#             check needs it whether or not the message is settleable.
#             Collapsing them would silently disable that check exactly
#             when something unusual is happening.
#             pageInfo is optional; a record without it is unpaginated and
#             complete by definition.
#             Known limit: refuses a page that declares itself incomplete,
#             but cannot detect that earlier pages were lost. Assembly is
#             the receiver's responsibility.
# Register  : FORK-CHANGES.md FC-005
# -----------------------------------------------------------------------

_flow_defs := [["seller", 1, "receivable"], ["buyer", -1, "payable"]]

# Internal: always computed, so the net-zero check holds in every case.
_revenue_flows := [flow |
	some def in _flow_defs
	flow := {"role": def[0], "value": def[1] * seller_net, "currency": _currency, "description": _desc(def[2])}
]

# True when this performance record is not a partial page.
_collection_complete if not _settlement_perf.performanceAttributes.pageInfo

_collection_complete if _settlement_perf.performanceAttributes.pageInfo.isLast == true

# Exported: an instruction to the enforcer. Undefined means write nothing.
revenue_flows := _revenue_flows if {
	_settlement_perf
	_collection_complete
}

_revenue_sum := sum([f.value | some f in _revenue_flows])

net_zero_ok if _revenue_sum == 0

# --- end FORK EDIT FC-005 ----------------------------------------------

# ---------------------------------------------------------------------------
# Bid-curve audit (flag only — never gates the money math)
#
# The cheapest ask covering the cleared quantity is the minimum OFFER_PRICE
# whose paired CAPACITY_OFFERED is at least CAPACITY_CLEARED. Pay-as-clear requires
# clearing price >= that ask.
# ---------------------------------------------------------------------------

_ask_at_cleared(iid) := ask if {
	interval := _market_interval(iid)
	prices := _payload_values(interval, "OFFER_PRICE")
	powers := _payload_values(interval, "CAPACITY_OFFERED")
	cleared_kw := _payload_val(interval, "CAPACITY_CLEARED")
	covering := [prices[j] | some j, p in powers; p >= cleared_kw]
	count(covering) > 0
	ask := min(covering)
}

# ---------------------------------------------------------------------------
# Violations
# ---------------------------------------------------------------------------

# --- FORK EDIT FC-003 (demand-flex-pac-contractpolicy.rego) ------------
# Change    : new violation — OFFER_PRICE and CAPACITY_OFFERED must carry
#             the same number of values in each market interval.
# Rationale : The bid curve is expressed as parallel arrays read by
#             position: OFFER_PRICE [1.5, 2.5] against CAPACITY_OFFERED
#             [90, 70] means 90 kW at 1.5 and a further 70 kW at 2.5.
#             Nothing checked they were the same length.
#             This is not only hygiene. _ask_at_cleared indexes prices by
#             a position found in powers, so a longer powers array yields
#             an undefined price that the comprehension drops silently.
#             The audit then takes a minimum over a partial set and may
#             accept a clearing price below the true cheapest covering
#             ask. The pay-as-clear invariant is unsound without this.
#             Deliberately NOT in the network policy. Not all columns in
#             an interval correlate — CAPACITY_CLEARED and CLEARING_PRICE
#             are scalars alongside a four-entry curve, so a blanket
#             equal-length rule would reject valid payloads. Which
#             columns pair is product knowledge, so it belongs here.
# Register  : FORK-CHANGES.md FC-003
# -----------------------------------------------------------------------
violations contains msg if {
	some interval in _market.intervals
	prices := _payload_values(interval, "OFFER_PRICE")
	powers := _payload_values(interval, "CAPACITY_OFFERED")
	count(prices) > 0
	count(powers) > 0
	count(prices) != count(powers)
	msg := sprintf(
		"interval %v: bid curve misaligned — %d OFFER_PRICE values against %d CAPACITY_OFFERED values",
		[interval.id, count(prices), count(powers)],
	)
}

# --- end FORK EDIT FC-003 ----------------------------------------------

violations contains msg if {
	not "buyer" in _roles
	msg := "no participant with role 'buyer' found"
}

violations contains msg if {
	not "seller" in _roles
	msg := "no participant with role 'seller' found"
}

violations contains msg if {
	count(input.message.contract.performance) > 0
	not _settlement_perf
	msg := "no settlement-eligible performance record found — settlement requires utility M&V meter telemetry; EnergyResource telemetry is reconciliation-only"
}

violations contains msg if {
	some iid in _cleared_ids
	some meter in _meters
	not _meter_mean(meter, iid, "USAGE")
	msg := sprintf("meter %s: missing USAGE for interval %d — interval excluded from settlement", [meter.meterId, iid])
}

violations contains msg if {
	some iid, s in _interval_settlement
	s.shortfallKwh > 0
	msg := sprintf("interval %d: under-delivery of %v kWh (delivered %v / cleared %v) — penalty %v %s applied",
		[iid, s.shortfallKwh, s.deliveredKwh, s.clearedKwh, s.penalty, _currency])
}

violations contains msg if {
	some iid in _cleared_ids
	interval := _market_interval(iid)
	clearing_price := _payload_val(interval, "CLEARING_PRICE")
	ask := _ask_at_cleared(iid)
	clearing_price < ask
	msg := sprintf("interval %d: clearing price %v below seller ask %v at cleared quantity — pay-as-clear invariant broken",
		[iid, clearing_price, ask])
}

violations contains msg if {
	some iid in _cleared_ids
	not _ask_at_cleared(iid)
	msg := sprintf("interval %d: no bid-curve step covers the cleared power — cannot audit clearing price", [iid])
}

violations contains msg if {
	not net_zero_ok
	msg := sprintf("net-zero failed: revenue sum = %v (expected 0)", [_revenue_sum])
}

# ---------------------------------------------------------------------------
# Column const (uc2 demand_flex_pac profile)
#
# DemandFlexNeed (shared, unified schema) leaves columns open; this rego is the
# hard lock for the pay-as-clear market. Self-skips when a series' descriptors
# are absent (e.g. a status round-trip carrying only ids).
# ---------------------------------------------------------------------------

_need := _commitment.resources[0].resourceAttributes

violations contains msg if {
	descs := _need.payloadDescriptors
	cols := {d.payloadType | some d in descs}
	cols != {"CAPACITY_REQUESTED"}
	msg := sprintf("DemandFlexNeed columns must be exactly {CAPACITY_REQUESTED} for the demand_flex_pac profile, got %v", [cols])
}

violations contains msg if {
	descs := _market.payloadDescriptors
	cols := {d.payloadType | some d in descs}
	cols != {"OFFER_PRICE", "CAPACITY_OFFERED", "CAPACITY_CLEARED", "CLEARING_PRICE"}
	msg := sprintf("market columns must be exactly {OFFER_PRICE, CAPACITY_OFFERED, CAPACITY_CLEARED, CLEARING_PRICE}, got %v", [cols])
}

# FC-005 — settlement must not run on a partial page. Without this the
# refusal above would be silent.
# Register: FORK-CHANGES.md FC-005
violations contains msg if {
	pi := _settlement_perf.performanceAttributes.pageInfo
	pi.isLast != true
	n := count(_settlement_perf.performanceAttributes.meters)
	msg := sprintf(
		"performance collection %v is incomplete (isLast=%v, %d of %v meters in this page) — cannot settle",
		[object.get(pi, "collectionId", "?"), pi.isLast, n, object.get(pi, "total", "?")],
	)
}
