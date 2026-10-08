# Unit tests for demand-flex-pac-contractpolicy.rego pay-as-clear settlement
#
# Run:  cd specification/policies && opa test demand-flex-pac-contractpolicy.rego test/demand-flex-pac-contractpolicy_test.rego -v

package deg.contracts.demand_flex_pac

import rego.v1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_mkt(iid, cleared_kw, clearing_price) := {"id": iid, "payloads": [
	{"type": "OFFER_PRICE", "values": [1.5, 2.5, 3.5, 5.0]},
	{"type": "CAPACITY_OFFERED", "values": [90, 70, 50, 30]},
	{"type": "CAPACITY_CLEARED", "values": [cleared_kw]},
	{"type": "CLEARING_PRICE", "values": [clearing_price]},
]}

_meter(meter_id, readings) := {
	"meterId": meter_id,
	"telemetry": {
		"@type": "TimeSeries",
		"intervalPeriod": {"start": "2026-06-15T13:30:00Z", "duration": "PT1H"},
		"intervals": [iv |
			some iid, r in readings
			iv := {"id": iid, "payloads": [
				{"type": "BASELINE", "values": [r[0]]},
				{"type": "USAGE", "values": [r[1]]},
			]}
		],
	},
}

_payload(market_intervals, meters) := {"message": {"contract": {
	"contractAttributes": {
		"@type": "DEGContract",
		"roles": [{"role": "buyer"}, {"role": "seller"}],
		"policy": {"url": "test", "queryPath": "test"},
	},
	"commitments": [{
		"offer": {"offerAttributes": {"inputs": [
			{"role": "buyer", "inputs": {
				"clearingMethod": "PAY-AS-CLEAR",
				"currency": "INR",
				"penaltyRate": 0.5,
			}},
			{"role": "seller", "inputs": {}},
		]}},
		"commitmentAttributes": {
			"@type": "TimeSeries",
			"intervalPeriod": {"start": "2026-06-15T13:30:00Z", "duration": "PT1H"},
			"intervals": market_intervals,
		},
	}],
	"performance": [{"performanceAttributes": {
		"@type": "DemandFlexPerformance",
		"methodology": "5of10",
		"meters": meters,
	}}],
}}}

# Mirrors the uc2 settled fixture: 2 intervals cleared at 3.5, delivery
# exactly matches the cleared power (50 kW then 45 kW).
_fixture := _payload(
	[_mkt(0, 50, 3.5), _mkt(1, 45, 3.5)],
	[
		_meter("m1", {0: [55.0, 30.0], 1: [50.0, 27.5]}),
		_meter("m2", {0: [50.0, 25.0], 1: [45.0, 22.5]}),
	],
)

# ---------------------------------------------------------------------------
# Happy path — delivered == cleared, no penalty (fixture numbers: 332.5)
# ---------------------------------------------------------------------------

test_exact_delivery_pays_cleared_at_clearing_price if {
	seller_net == 332.5 with input as _fixture
	total_penalty == 0 with input as _fixture
	net_zero_ok with input as _fixture
}

test_revenue_flows_signs_and_roles if {
	flows := revenue_flows with input as _fixture
	some s in flows
	s.role == "seller"
	s.value == 332.5
	s.currency == "INR"
	some b in flows
	b.role == "buyer"
	b.value == -332.5
}

test_interval_hours_parsed_from_iso8601 if {
	interval_hours == 1 with input as _fixture
	interval_hours == 0.5 with input as json.patch(_fixture,
		[{"op": "replace", "path": "/message/contract/commitments/0/commitmentAttributes/intervalPeriod/duration", "value": "PT30M"}])
}

# ---------------------------------------------------------------------------
# Under-delivery — payment capped at delivered, flat penalty on shortfall
# ---------------------------------------------------------------------------

# One interval, cleared 50 kWh @ 3.5, delivered 40 kWh:
#   payment = 40 × 3.5 = 140; penalty = 10 × 0.5 = 5; net = 135
_under := _payload(
	[_mkt(0, 50, 3.5)],
	[_meter("m1", {0: [55.0, 15.0]})],
)

test_under_delivery_caps_payment_and_charges_penalty if {
	total_payment == 140 with input as _under
	total_penalty == 5 with input as _under
	seller_net == 135 with input as _under
}

test_under_delivery_flagged if {
	v := violations with input as _under
	some msg in v
	contains(msg, "under-delivery of 10 kWh")
}

# ---------------------------------------------------------------------------
# Over-delivery — pay-as-clear never pays beyond the cleared quantity
# ---------------------------------------------------------------------------

# Cleared 50 kWh @ 3.5, delivered 60 kWh: payment stays 50 × 3.5 = 175.
_over := _payload(
	[_mkt(0, 50, 3.5)],
	[_meter("m1", {0: [70.0, 10.0]})],
)

test_over_delivery_paid_at_cleared_only if {
	seller_net == 175 with input as _over
	total_penalty == 0 with input as _over
}

# ---------------------------------------------------------------------------
# Bid-curve audit — flag only, money math unchanged
# ---------------------------------------------------------------------------

# Clearing at 1.0 for 50 kW: cheapest ask covering 50 kW is 1.5 → violation,
# but the payment still uses the published clearing price.
_cheap_clearing := _payload(
	[_mkt(0, 50, 1.0)],
	[_meter("m1", {0: [60.0, 10.0]})],
)

test_clearing_below_ask_flagged_not_gated if {
	v := violations with input as _cheap_clearing
	some msg in v
	contains(msg, "below seller ask 1.5")
	seller_net == 50 with input as _cheap_clearing # 50 kWh × 1.0
}

# ---------------------------------------------------------------------------
# Missing USAGE — interval excluded and flagged
# ---------------------------------------------------------------------------

_no_usage := json.patch(
	_payload([_mkt(0, 50, 3.5)], [_meter("m1", {0: [55.0, 30.0]})]),
	[{"op": "replace", "path": "/message/contract/performance/0/performanceAttributes/meters/0/telemetry/intervals/0/payloads", "value": [{"type": "BASELINE", "values": [55.0]}]}],
)

test_missing_usage_excludes_interval if {
	count(object.keys(_interval_settlement)) == 0 with input as _no_usage
	v := violations with input as _no_usage
	some msg in v
	contains(msg, "missing USAGE for interval 0")
}

# ---------------------------------------------------------------------------
# penaltyRate optional — absent means no penalty term
# ---------------------------------------------------------------------------

test_penalty_rate_defaults_to_zero if {
	no_rate := json.patch(_under, [{"op": "remove", "path": "/message/contract/commitments/0/offer/offerAttributes/inputs/0/inputs/penaltyRate"}])
	total_penalty == 0 with input as no_rate
	seller_net == 140 with input as no_rate
}

# column const (uc2 profile) — enforced in-rego, not schema
_need_ok := {"payloadDescriptors": [{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "CAPACITY_REQUESTED", "units": "KW", "insertedBy": "buyer"}]}

_market_ok := {"payloadDescriptors": [
	{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "OFFER_PRICE"},
	{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "CAPACITY_OFFERED"},
	{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "CAPACITY_CLEARED"},
	{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "CLEARING_PRICE"},
]}

_col_input(need, market) := {"message": {"contract": {"commitments": [{
	"resources": [{"resourceAttributes": need}],
	"commitmentAttributes": market,
	"offer": {"offerAttributes": {"inputs": []}},
}]}}}

test_need_column_const_ok if {
	vs := violations with input as _col_input(_need_ok, _market_ok)
	every v in vs { not contains(v, "columns must be") }
}

test_need_column_const_violation if {
	bad := {"payloadDescriptors": [{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "MAX_CAPACITY"}]}
	vs := violations with input as _col_input(bad, _market_ok)
	some v in vs
	contains(v, "CAPACITY_REQUESTED")
}

test_market_column_const_violation if {
	bad := {"payloadDescriptors": [{"objectType": "EVENT_PAYLOAD_DESCRIPTOR", "payloadType": "OFFER_PRICE"}]}
	vs := violations with input as _col_input(_need_ok, bad)
	some v in vs
	contains(v, "OFFER_PRICE")
}

# --- FORK EDIT FC-003 (demand-flex-pac-contractpolicy_test.rego) -------
# New rule: OFFER_PRICE and CAPACITY_OFFERED must carry the same number
# of values in each market interval. The curve is read positionally, and
# _ask_at_cleared indexes prices by a position found in powers — so a
# mismatch silently drops entries and the pay-as-clear audit compares
# against an incomplete set of asks.
# Register : FORK-CHANGES.md FC-003
# -----------------------------------------------------------------------

# Like _mkt, but with three OFFER_PRICE values against four CAPACITY_OFFERED.
_mkt_misaligned(iid, cleared_kw, clearing_price) := {"id": iid, "payloads": [
	{"type": "OFFER_PRICE", "values": [1.5, 2.5, 3.5]},
	{"type": "CAPACITY_OFFERED", "values": [90, 70, 50, 30]},
	{"type": "CAPACITY_CLEARED", "values": [cleared_kw]},
	{"type": "CLEARING_PRICE", "values": [clearing_price]},
]}

_misaligned := _payload(
	[_mkt_misaligned(0, 50, 3.5)],
	[_meter("m1", {0: [55.0, 30.0]})],
)

test_bid_curve_misaligned if {
	v := violations with input as _misaligned
	some msg in v
	contains(msg, "bid curve misaligned")
}

# A correctly aligned curve must NOT trigger it.
test_bid_curve_aligned_ok if {
	v := violations with input as _fixture
	every msg in v {
		not contains(msg, "bid curve misaligned")
	}
}

# --- end FORK EDIT FC-003 ----------------------------------------------

# --- FORK EDIT FC-005 (demand-flex-pac-contractpolicy_test.rego) -------
# Settlement must refuse a partial page, and the net-zero check must
# survive the gate. Register: FORK-CHANGES.md FC-005
# -----------------------------------------------------------------------

_pac_page_info(seq, is_last) := {
	"@type": "PageInfo",
	"sequence": seq,
	"pageSize": 4000,
	"total": 12000,
	"isLast": is_last,
	"collectionId": "perf-pac-test-001",
}

_pac_paged(seq, is_last) := json.patch(_fixture, [{
	"op": "add",
	"path": "/message/contract/performance/0/performanceAttributes/pageInfo",
	"value": _pac_page_info(seq, is_last),
}])

test_pac_partial_page_does_not_settle if {
	not revenue_flows with input as _pac_paged(0, false)
}

test_pac_partial_page_flagged if {
	v := violations with input as _pac_paged(0, false)
	some msg in v
	contains(msg, "is incomplete")
}

test_pac_last_page_settles if {
	revenue_flows with input as _pac_paged(2, true)
}

# The internal/exported split: the net-zero check must still hold on a
# partial page, even though nothing is exported.
test_pac_net_zero_survives_the_gate if {
	not revenue_flows with input as _pac_paged(0, false)
	net_zero_ok with input as _pac_paged(0, false)
}

# --- end FORK EDIT FC-005 ----------------------------------------------

