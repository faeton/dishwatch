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
