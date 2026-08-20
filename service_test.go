package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/faeton/dishwatch/internal/dish"
)

// The service-class mapping is a table of string literals on both sides of a
// process boundary, which is the shape that fails silently: a typo in a wire
// constant (`BUSINESS-PLUS`), a swapped pair, or a default arm that guesses
// instead of abstaining all produce a Dashboard that decodes cleanly, passes
// scripts/check-contract.sh, and satisfies every Swift test — because those
// start *after* the tokens exist. The only place the dish's vocabulary meets
// ours is here.

func TestServiceClassMapsEveryKnownValue(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"CONSUMER", svcConsumer},
		{"BUSINESS", svcBusiness},
		{"BUSINESS_PLUS", svcBusinessPlus},
		{"COMMERCIAL_AVIATION", svcAviation},
	} {
		if got := serviceClass(tc.in); got != tc.want {
			t.Errorf("serviceClass(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestServiceMobilityMapsEveryKnownValue(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"STATIONARY", mobFixed},
		{"NOMADIC", mobNomadic},
		{"MOBILE", mobMobile},
	} {
		if got := serviceMobility(tc.in); got != tc.want {
			t.Errorf("serviceMobility(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// The default arms abstain rather than guess. A class this build has never
// heard of is a tier SpaceX added after it shipped, and naming it as an
// existing one is worse than saying nothing.
func TestUnknownServiceValuesClaimNothing(t *testing.T) {
	for _, in := range []string{
		"", "UNKNOWN_USER_CLASS_OF_SERVICE", "consumer", "ORBITAL_DATACENTER",
	} {
		if got := serviceClass(in); got != svcUnknown {
			t.Errorf("serviceClass(%q) = %q, want the empty token", in, got)
		}
	}
	for _, in := range []string{"", "UNKNOWN", "mobile", "SUBORBITAL"} {
		if got := serviceMobility(in); got != mobUnknown {
			t.Errorf("serviceMobility(%q) = %q, want the empty token", in, got)
		}
	}
}

// The load-bearing one, and the reason the empty case is not a mere default.
//
// STATIONARY is the zero value of the dish's `UserMobilityClass`, and
// internal/dish/client.go marshals with EmitUnpopulated:false — so a stationary
// dish omits the field entirely and reaches us as "". That is indistinguishable
// from firmware too old to have the field, so we abstain. Mapping "" to
// mobFixed would be right for most dishes and a false statement about the
// dish's own report for the rest, which is the trade this asserts is still
// being made in the direction we chose.
func TestAbsentMobilityIsNotReportedAsFixed(t *testing.T) {
	if got := serviceMobility(""); got == mobFixed {
		t.Fatal("an absent mobilityClass was reported as a fixed address; " +
			"STATIONARY and 'firmware does not say' are indistinguishable here")
	}
}

// Tokens are our vocabulary, not the dish's, so that a renamed gRPC constant
// cannot change the wire contract the Swift app decodes. If one of these ever
// equals its source enum, the indirection has quietly been abandoned.
func TestTokensAreNotTheDishesOwnEnumNames(t *testing.T) {
	for _, tok := range []string{svcConsumer, svcBusiness, svcBusinessPlus, svcAviation,
		mobFixed, mobNomadic, mobMobile} {
		if tok == "" {
			t.Error("a known value mapped to the empty token")
		}
		if tok == strings.ToUpper(tok) {
			t.Errorf("token %q looks like a wire enum name, not our vocabulary", tok)
		}
	}
}

// End to end through the DTO: a status carrying both enums must surface both
// keys under the names the Swift decoder looks for.
func TestDashboardCarriesTheServiceKeys(t *testing.T) {
	var s dish.Status
	s.ClassOfService = "CONSUMER"
	s.MobilityClass = "MOBILE"

	d := buildDashboard(&s, nil, "192.168.100.1:9200", 60)
	if d.ServiceClass != svcConsumer || d.ServiceMobility != mobMobile {
		t.Fatalf("buildDashboard lost the service fields: %+v / %+v",
			d.ServiceClass, d.ServiceMobility)
	}

	b, err := json.Marshal(d)
	if err != nil {
		t.Fatal(err)
	}
	var wire map[string]any
	if err := json.Unmarshal(b, &wire); err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{
		"serviceClass":    svcConsumer,
		"serviceMobility": mobMobile,
	} {
		if wire[k] != want {
			t.Errorf("wire key %q = %v, want %q", k, wire[k], want)
		}
	}
}

// A dish that reports neither must emit both keys as empty strings rather than
// omitting them or inventing a value — the app renders nothing for "", and it
// can only do that if "" actually arrives.
func TestDashboardStaysSilentWhenTheDishDoes(t *testing.T) {
	var s dish.Status
	d := buildDashboard(&s, nil, "192.168.100.1:9200", 60)
	if d.ServiceClass != "" || d.ServiceMobility != "" {
		t.Fatalf("invented service data from an empty status: %q / %q",
			d.ServiceClass, d.ServiceMobility)
	}
}

// The disablement mapping matters more than the class one and is tested the
// same way, because it is the table that was already wrong. Before this it
// carried SUSPENDED, OUT_OF_SERVICE_AREA, OUT_OF_REGION, DISABLED_BY_COMMAND,
// UNKNOWN_USER_TERMINAL and INVALID_HARDWARE_VERSION — six constants that are
// not in `UtDisablementCode` and so could never match. Nothing failed: the
// dashboard rendered, the contract check passed, and every real outage fell to
// the default arm. Only a test that names the enum catches that.
//
// The wire values below are the enum as the dish reports it, read off a live
// unit by gRPC reflection (`grpcurl -plaintext 192.168.100.1:9200 describe
// SpaceX.API.Satellites.Network.UtDisablementCode`).
func TestServiceDisableMapsEveryKnownValue(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"NO_ACTIVE_ACCOUNT", disNoAccount},
		{"ACCOUNT_DISABLED", disAccountOff},
		{"TOO_FAR_FROM_SERVICE_ADDRESS", disTooFarFromAddr},
		{"IN_OCEAN", disInOcean},
		{"BLOCKED_COUNTRY", disBlockedCountry},
		{"DATA_OVERAGE_SANDBOX_POLICY", disDataOverage},
		{"CELL_IS_DISABLED", disCellDisabled},
		{"ROAM_RESTRICTED", disRoamRestricted},
		{"UNKNOWN_LOCATION", disUnknownLoc},
		{"UNSUPPORTED_VERSION", disUnsupportedFW},
		{"MOVING_TOO_FAST_FOR_POLICY", disMovingTooFast},
		{"UNDER_AVIATION_FLYOVER_LIMITS", disAviationLimit},
		{"BLOCKED_AREA", disBlockedArea},
	} {
		if got := serviceDisable(tc.in); got != tc.want {
			t.Errorf("serviceDisable(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

// A working dish must not carry a cause. OKAY and "" arrive from opposite
// directions — the dish saying service is fine, and the dish saying nothing —
// and both have to produce no reason, or a healthy panel grows an outage line.
func TestServiceDisableIsSilentWhenServiceIsFine(t *testing.T) {
	for _, in := range []string{"OKAY", "", "UNKNOWN_STATE", "IN_SPACE"} {
		if got := serviceDisable(in); got != disNone {
			t.Errorf("serviceDisable(%q) = %q, want %q", in, got, disNone)
		}
	}
}

// Every token this build can emit must have a phrase in `serviceStatus`, or the
// CLI prints a bare SCREAMING_CASE code for an outage the DTO can already name.
// The two tables are maintained by hand and drift the moment one is extended
// without the other.
func TestEveryDisableCodeHasACliPhrase(t *testing.T) {
	for _, code := range []string{
		"OKAY", "NO_ACTIVE_ACCOUNT", "ACCOUNT_DISABLED",
		"TOO_FAR_FROM_SERVICE_ADDRESS", "IN_OCEAN", "BLOCKED_COUNTRY",
		"DATA_OVERAGE_SANDBOX_POLICY", "CELL_IS_DISABLED", "ROAM_RESTRICTED",
		"UNKNOWN_LOCATION", "UNSUPPORTED_VERSION", "MOVING_TOO_FAST_FOR_POLICY",
		"UNDER_AVIATION_FLYOVER_LIMITS", "BLOCKED_AREA",
	} {
		phrase, _ := serviceStatus(code)
		if phrase == code {
			t.Errorf("serviceStatus(%q) fell through to the raw code", code)
		}
		if phrase == "" || phrase == "?" {
			t.Errorf("serviceStatus(%q) = %q, want a phrase", code, phrase)
		}
	}
}

// `treatAsMetered` is a bare bool on a wire that omits false, so the decode has
// exactly one job: carry a present true through to the DTO, and leave an absent
// field false rather than defaulting it to anything else.
func TestMeteredSurvivesTheDecodeBothWays(t *testing.T) {
	for _, tc := range []struct {
		name string
		raw  string
		want bool
	}{
		{"present true", `{"treatAsMetered":true}`, true},
		{"present false", `{"treatAsMetered":false}`, false},
		{"absent", `{}`, false},
	} {
		var s dish.Status
		if err := json.Unmarshal([]byte(tc.raw), &s); err != nil {
			t.Fatalf("%s: unmarshal: %v", tc.name, err)
		}
		if s.TreatAsMetered != tc.want {
			t.Errorf("%s: TreatAsMetered = %v, want %v", tc.name, s.TreatAsMetered, tc.want)
		}
		d := buildDashboard(&s, nil, "", 0)
		if d.Metered != tc.want {
			t.Errorf("%s: Dashboard.Metered = %v, want %v", tc.name, d.Metered, tc.want)
		}
	}
}
