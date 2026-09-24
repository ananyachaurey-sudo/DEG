# DEG Network Policy — Demand Flex
#
# Network-level gate evaluated by the `checkPolicy` step on EVERY module
# (BAP + BPP, caller + receiver), so it runs on every action in both
# directions. Fires NACK when `violations` is non-empty.
#
# Design: this policy owns all STRUCTURAL / FORMATION checks and is the
# early-catch layer for the whole flow. Each rule self-skips when the data
# it inspects is not on the wire, so one rule set safely spans
# select → init → confirm → status without false positives. The
# settlement-math (net-zero, per-meter payout) lives in the contract rego,
# which only makes sense once telemetry has arrived.
#
# Stage legend (which rule is live when):
#   discover / catalog … 1b, 4, 5b, 6            (need series only)
#   select / on_select … 1b, 4, 5a, 5b, 6        (buyer need; no seller offer yet)
#   init / on_init …… 1b, 3, 3a, 4, 5a, 5b, 6     (seller must now commit CAPACITY_OFFERED)
#   confirm/on_confirm  1b, 3, 3a, 4, 5a, 5b, 6   (same commitment rules re-checked)
#   status / on_status  1, 1b, 2, 3, 3a, 4, 5*, 6 (+ per-meter telemetry + grid)
#
# The `violations` rule combines these checks:
#
#   1. BecknTimeSeries cross-field type-coverage. Every `payloadType`
#      used in `intervals[*].payloads[*].type` MUST be declared in
#      `payloadDescriptors[*].payloadType`. Catches typos like
#      "BASELIN" or undocumented signals on the wire. Applied to both
#      per-meter telemetry (1) and the DemandFlexNeed series in
#      resourceAttributes (1b) — the need is itself a BecknTimeSeries but
#      beckn-onix's extended validator resolves only one @type per object,
#      so the TimeSeries structural check is enforced here.
#
#   2. PER_EVENT / PER_INTERVAL cardinality against the seller's
#      committed `reportDescriptors[]` (from
#      `commitments[0].offer.offerAttributes.inputs[seller].inputs.reportDescriptors`):
#        PER_EVENT  — payloadType MUST appear in EXACTLY ONE interval
#                     of the meter's BecknTimeSeries (interval 0 by
#                     convention). Used for GPS_LAT, GPS_LON, etc.
#        PER_INTERVAL — payloadType MUST appear in EVERY interval.
#                     Used for BASELINE, USAGE, POWER, SOC_END.
#      Cardinality self-skips when no `reportDescriptors` are on the
#      wire (e.g. a status round-trip carrying only commitment ids,
#      or a grid-meter-only on_status whose meter doesn't declare the
#      vendor payload types in its own `payloadDescriptors`). So this
#      rule transparently passes traffic that lacks a seller
#      `reportDescriptors` declaration.
#
#   3. Commitment formation completeness (fail fast). Once the seller
#      has presented a CAPACITY_OFFERED column
#      (`commitments[*].commitmentAttributes` declaring CAPACITY_OFFERED —
#      first on the wire at init), every DemandFlexNeed interval MUST
#      carry a seller CAPACITY_OFFERED value, and the offered series'
#      `intervalPeriod` MUST match the need grid. This surfaces a
#      malformed commitment at init/confirm rather than at settlement.
#      The contract rego keeps the equivalent rules as a settlement-time
#      backstop. Self-skips on messages with no offered series (bare
#      select / on_select, status-id round-trips).
#
#   3a. CAPACITY_OFFERED column presence (stage-gated). Rule 3 above can
#      only check a column the seller actually declared — drop the whole
#      `commitmentAttributes` block and rule 3 silently self-skips. This
#      rule closes that gap: from `init` onward (init, on_init, confirm,
#      on_confirm, status, on_status, update, on_update — see
#      `_offer_required_actions`), any commitment carrying a DemandFlexNeed
#      MUST also declare a CAPACITY_OFFERED column. `select` / `on_select`
#      are excluded because the seller has not committed capacity yet.
#      This is the rule that catches a dropped CAPACITY_OFFERED at confirm.
#
#   4. BecknTimeSeries interval id sequence. Every series' `intervals[*].id`
#      MUST be 0,1,2,… — start at 0 and increase by 1, with no gaps,
#      duplicates, or out-of-order ids. Applied to the DemandFlexNeed
#      series, the CAPACITY_OFFERED series, and each meter's telemetry.
#      A series that declares no ids at all self-skips (partial/legacy
#      payloads).
#
#   5. Column locks, roles & grid alignment (consolidated from the contract
#      rego, which now carries only the settlement family). All gate-only:
#        5a. Participant roles — a contractAttributes-bearing message MUST
#            name both a buyer and a seller.
#   	 5b. DemandFlexNeed required columns. The need MUST declare
#     	 	 CAPACITY_REQUESTED. PRICE and SHORTFALL_PENALTY are optional at
#      		 this layer: a discovered-price event solicits bids rather than
#       	 posting a rate and carries neither. Posted-price settlement
#     		 requires them in its own contract policy, from confirm onward.
#     	 	 (FC-001; 5c removed.)
#        5d. Meter telemetry grid — each meter's telemetry `intervalPeriod`
#            MUST match the DemandFlexNeed grid.
#      	Each self-skips when the series it inspects is absent.
#
#   6. Parallel value arrays. Within one interval, every payload's
#      `values` array MUST be the same length, since columns are read
#      positionally. A bid curve carries several tranches; a flat offer
#      carries one. (FC-001, new.)
#
# This policy owns ALL universal structural well-formedness for demand-flex;
# the contract rego (demand-flex-contractpolicy.rego) owns only settlement
# (settlement-eligible perf, USAGE completeness, net-zero) plus revenue-flow
# injection.
#
# Canonical source: specification/policies/demand-flex-networkpolicy.rego

package deg.policy.demand_flex_network

import rego.v1

# ----- helpers --------------------------------------------------------

_seller_descriptors := descs if {
	some perf_input in input.message.contract.commitments[0].offer.offerAttributes.inputs
	perf_input.role == "seller"
	descs := perf_input.inputs.reportDescriptors
}

_seller_descriptors := [] if {
	# fallback when offer block isn't on the wire (e.g. the status round-trip
	# carries only commitment ids); cardinality check then has nothing to do.
	not _has_seller_inputs
}

_has_seller_inputs if {
	some perf_input in input.message.contract.commitments[0].offer.offerAttributes.inputs
	perf_input.role == "seller"
	perf_input.inputs.reportDescriptors
}

_per_event_types := {d.payloadType |
	some d in _seller_descriptors
	d.cardinality == "PER_EVENT"
}

_per_interval_types := {d.payloadType |
	some d in _seller_descriptors
	d.cardinality != "PER_EVENT" # default == PER_INTERVAL
}

_count_payloads(meter, ptype) := n if {
	rows := [1 |
		some interval in meter.telemetry.intervals
		some payload in interval.payloads
		payload.type == ptype
	]
	n := count(rows)
}

# ----- 1) cross-field type-coverage -----------------------------------
# Iterates only over USED types — declared-but-unused is allowed (e.g. a
# pre-event report that ships full descriptors before USAGE is recorded).

violations contains msg if {
	some perf in input.message.contract.performance
	some meter in perf.performanceAttributes.meters
	declared_types := {d.payloadType | some d in meter.telemetry.payloadDescriptors}
	some interval in meter.telemetry.intervals
	some payload in interval.payloads
	not payload.type in declared_types
	msg := sprintf("meter %s: payload type '%s' used in intervals but not declared in payloadDescriptors", [meter.meterId, payload.type])
}

# ----- 1b) DemandFlexNeed cross-field type-coverage -------------------
# The unified DemandFlexNeed is itself a BecknTimeSeries (carried inline in
# resourceAttributes). The beckn-onix extended schema validator resolves only a
# single @type per object, so it cannot also validate the object against the
# TimeSeries schema — the same structural check (1) is therefore enforced here
# for the need series. Any resourceAttributes carrying `intervals` is treated as
# the need TimeSeries; applies to both the bound contract and catalog publish.
# A need with intervals but no payloadDescriptors flags every used type.

_demand_flex_needs contains ra if {
	some c in input.message.contract.commitments
	some r in c.resources
	ra := r.resourceAttributes
	ra.intervals
}

_demand_flex_needs contains ra if {
	some cat in input.message.catalogs
	some r in cat.resources
	ra := r.resourceAttributes
	ra.intervals
}

violations contains msg if {
	some ra in _demand_flex_needs
	declared_types := {d.payloadType | some d in ra.payloadDescriptors}
	some interval in ra.intervals
	some payload in interval.payloads
	not payload.type in declared_types
	msg := sprintf("DemandFlexNeed: payload type '%s' used in intervals but not declared in payloadDescriptors", [payload.type])
}

# ----- 2a) PER_EVENT — exactly one occurrence across intervals --------

violations contains msg if {
	some perf in input.message.contract.performance
	some meter in perf.performanceAttributes.meters
	some ptype in _per_event_types
	n := _count_payloads(meter, ptype)
	n != 1

	# Tolerate completely-absent telemetry types (e.g. a grid-meter-only
	# baselines push) by skipping when the meter doesn't declare ptype in
	# its own payloadDescriptors.
	declared := {d.payloadType | some d in meter.telemetry.payloadDescriptors}
	ptype in declared
	msg := sprintf(
		"device %s: PER_EVENT payload '%s' must appear in exactly 1 interval (found %d)",
		[meter.meterId, ptype, n],
	)
}

# ----- 2b) PER_INTERVAL — present in every interval -------------------

violations contains msg if {
	some perf in input.message.contract.performance
	some meter in perf.performanceAttributes.meters
	some ptype in _per_interval_types
	declared := {d.payloadType | some d in meter.telemetry.payloadDescriptors}
	ptype in declared
	total := count(meter.telemetry.intervals)
	hits := _count_payloads(meter, ptype)
	hits != total
	msg := sprintf(
		"device %s: PER_INTERVAL payload '%s' must appear in every interval (found %d of %d)",
		[meter.meterId, ptype, hits, total],
	)
}

# ----- 3) commitment formation completeness (fail fast) ---------------
# Pair each commitment's buyer DemandFlexNeed with the seller's
# CAPACITY_OFFERED series. A pair forms only once the seller has presented
# a CAPACITY_OFFERED column (commitmentAttributes declaring it); bare
# select / on_select and status-id round-trips carry no offered series and
# self-skip. The contract rego keeps equivalent rules as a settlement-time
# backstop.

_offered_pairs contains pair if {
	some c in input.message.contract.commitments
	need := c.resources[0].resourceAttributes
	need.intervals
	ca := c.commitmentAttributes
	"CAPACITY_OFFERED" in {d.payloadType | some d in ca.payloadDescriptors}
	pair := {"cid": object.get(c, "id", "?"), "need": need, "offered": ca}
}

_offered_val(intervals, ivid) := v if {
	some iv in intervals
	iv.id == ivid
	some pl in iv.payloads
	pl.type == "CAPACITY_OFFERED"
	v := pl.values[0]
}

# every requested slot must carry a seller CAPACITY_OFFERED value
violations contains msg if {
	some p in _offered_pairs
	some iv in p.need.intervals
	not _offered_val(p.offered.intervals, iv.id)
	msg := sprintf("commitment %s, interval %v: missing CAPACITY_OFFERED", [p.cid, iv.id])
}

# the CAPACITY_OFFERED grid must match the DemandFlexNeed grid
violations contains msg if {
	some p in _offered_pairs
	p.offered.intervalPeriod != p.need.intervalPeriod
	msg := sprintf("commitment %s: CAPACITY_OFFERED intervalPeriod does not match the DemandFlexNeed grid", [p.cid])
}

# ----- 3a) CAPACITY_OFFERED column presence (stage-gated) -------------
# Actions at which the seller must ALREADY have committed a CAPACITY_OFFERED
# column against the buyer's DemandFlexNeed — everything from init onward.
# `select` / `on_select` are deliberately absent: the seller has not offered
# capacity yet, so a bare need with no commitment column is valid there.
_offer_required_actions := {
	"init", "on_init",
	"confirm", "on_confirm",
	"status", "on_status",
	"update", "on_update",
}

# Unlike rule 3 (which keys off the CAPACITY_OFFERED descriptor and therefore
# self-skips when the whole column is dropped), this reads the column presence
# directly from the commitment, so dropping `commitmentAttributes` entirely is
# caught. `object.get` keeps the reference defined even when the block is absent.
violations contains msg if {
	input.context.action in _offer_required_actions
	some c in input.message.contract.commitments
	c.resources[0].resourceAttributes.intervals # a DemandFlexNeed is present
	ca := object.get(c, "commitmentAttributes", {})
	declared := {d.payloadType | some d in object.get(ca, "payloadDescriptors", [])}
	not "CAPACITY_OFFERED" in declared
	msg := sprintf(
		"commitment %s: action %q requires a CAPACITY_OFFERED column on commitmentAttributes, but none is declared",
		[object.get(c, "id", "?"), input.context.action],
	)
}

# ----- 4) BecknTimeSeries interval id sequence ------------------------
# Every series' intervals[*].id MUST be 0,1,2,… (start at 0, +1 each, no
# gaps/dups/out-of-order). Applied to the need series, the CAPACITY_OFFERED
# series, and each meter's telemetry. A series declaring no ids self-skips.

_id_series contains s if {
	some ra in _demand_flex_needs
	s := {"label": "DemandFlexNeed", "intervals": ra.intervals}
}

_id_series contains s if {
	some c in input.message.contract.commitments
	ca := c.commitmentAttributes
	ca.intervals
	s := {"label": sprintf("commitment %s CAPACITY_OFFERED series", [object.get(c, "id", "?")]), "intervals": ca.intervals}
}

_id_series contains s if {
	some perf in input.message.contract.performance
	some m in perf.performanceAttributes.meters
	m.telemetry.intervals
	s := {"label": sprintf("meter %s telemetry", [m.meterId]), "intervals": m.telemetry.intervals}
}

_ids(intervals) := [iv.id | some iv in intervals]

# no ids declared anywhere → out of scope for this check
_ids_ok(intervals) if count(_ids(intervals)) == 0

# every interval carries an id and they are 0,1,2,… in order
_ids_ok(intervals) if {
	ids := _ids(intervals)
	count(ids) == count(intervals)
	every i, id in ids {
		id == i
	}
}

violations contains msg if {
	some s in _id_series
	not _ids_ok(s.intervals)
	msg := sprintf("%s: interval ids must start at 0 and increase by 1, got %v", [s.label, _ids(s.intervals)])
}

# ----- 5) column locks, roles & grid alignment ------------------------
# Universal structural invariants of a demand-flex message, consolidated
# here from the contract rego (which now carries only the settlement family:
# settlement-eligible-perf, USAGE completeness, net-zero). All gate-only, all
# self-skipping when the series they inspect is absent — so, like every rule
# above, they are safe to evaluate at every stage on every module.

# 5a) participant roles — a message carrying a contractAttributes block MUST
# name both a buyer and a seller. Self-skips on messages with no contract
# (discover, catalog publish) or a bare status-id round-trip.
_contract_roles := {r.role | some r in input.message.contract.contractAttributes.roles}

violations contains msg if {
	input.message.contract.contractAttributes
	not "buyer" in _contract_roles
	msg := "contract: no participant with role 'buyer' found"
}

violations contains msg if {
	input.message.contract.contractAttributes
	not "seller" in _contract_roles
	msg := "contract: no participant with role 'seller' found"
}

# --- FORK EDIT FC-001 --------------------------------------------------
# Upstream  : 5b pinned DemandFlexNeed columns to exactly
#             {CAPACITY_REQUESTED, PRICE, SHORTFALL_PENALTY};
#             5c pinned commitment columns to exactly {CAPACITY_OFFERED}.
# Change    : 5b now requires CAPACITY_REQUESTED by presence only.
#             5c is removed. Rule 6 is added.
# Rationale : An exact-set check asserts a column set is COMPLETE, which
#             defines a product rather than testing coherence. Run against
#             the bid-curve fixtures shipped in this same devkit, the two
#             locks reject 11 of 12 messages before they reach their own
#             contract policy — which implements the correct column rules
#             for that product. All 15 curtailment fixtures pass.
#             A discovered-price event solicits bids instead of posting a
#             rate, so it carries no PRICE or SHORTFALL_PENALTY column at
#             all; those are terms of posted-price settlement and now live
#             in that product's contract policy.
#             The P2P trading network policy uses presence checks
#             throughout and contains no exact-set comparison on columns.
#             DemandFlexNeed's schema states the column set is
#             intentionally not fixed and names each profile's contract
#             policy as the governing authority.
# Register  : FORK-CHANGES.md FC-001
# -----------------------------------------------------------------------

# 5b) DemandFlexNeed required columns — a need MUST say what capacity is
# being asked for. PRICE and SHORTFALL_PENALTY are deliberately NOT required:
# a discovered-price event carries neither. Products that settle against a
# posted price require them in their own contract policy. Rule 1b separately
# checks that every USED type is declared.
violations contains msg if {
	some ra in _demand_flex_needs
	cols := {d.payloadType | some d in ra.payloadDescriptors}
	not "CAPACITY_REQUESTED" in cols
	msg := sprintf("DemandFlexNeed must declare a CAPACITY_REQUESTED column, got %v", [cols])
}

# 5c) REMOVED by FC-001. It pinned the commitment column set to exactly
# {CAPACITY_OFFERED}, which blocked an offer from carrying its own
# OFFER_PRICE. Presence of CAPACITY_OFFERED from init onward is rule 3a and
# is unchanged; the contents of the column set are a product concern.

# 6) Parallel value arrays — within one interval, every payload's `values`
# array MUST be the same length. Columns are read positionally: a bid curve
# expresses tranches as OFFER_PRICE [1.5, 2.5] against CAPACITY_OFFERED
# [90, 70], and a mismatch silently misaligns price from quantity. A flat
# single-price offer is the one-entry case. This is a universal invariant —
# positional correspondence is meaningless if the arrays differ in length.
_interval_series contains s if {
	some ra in _demand_flex_needs
	s := ra
}

_interval_series contains s if {
	some c in input.message.contract.commitments
	s := c.commitmentAttributes
}

_interval_series contains s if {
	some perf in input.message.contract.performance
	some m in perf.performanceAttributes.meters
	s := m.telemetry
}

violations contains msg if {
	some s in _interval_series
	some iv in s.intervals
	lens := {count(p.values) | some p in iv.payloads}
	count(lens) > 1
	msg := sprintf("interval %v: parallel value arrays differ in length (%v)", [object.get(iv, "id", "?"), lens])
}

# --- end FORK EDIT FC-001 ----------------------------------------------

# 5d) meter telemetry grid — each meter's telemetry intervalPeriod MUST match
# the DemandFlexNeed grid (the two series join on interval id). Self-skips when
# no need grid or no meter telemetry is on the wire.
_need_grid := grid if {
	some c in input.message.contract.commitments
	grid := c.resources[0].resourceAttributes.intervalPeriod
}

violations contains msg if {
	some perf in input.message.contract.performance
	some m in perf.performanceAttributes.meters
	m.telemetry.intervalPeriod != _need_grid
	msg := sprintf("meter %s: telemetry intervalPeriod does not match the DemandFlexNeed grid", [m.meterId])
}
