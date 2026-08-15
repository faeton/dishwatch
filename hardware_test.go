package main

import "testing"

// The model string is the *only* thing that answers "do I have to go turn this
// dish around myself" — the call that carries the actuator flag directly
// (`dish_get_context`) is PermissionDenied to an unauthenticated caller. So the
// table is load-bearing, and a wrong row is not a cosmetic label defect: it
// tells someone their fixed panel will aim itself, or sends someone with a
// motorized one out to a mast for no reason.
func TestClassifyHardware(t *testing.T) {
	cases := []struct {
		hw   string
		name string
		aim  string
	}{
		// The two that used to collapse into one label. rev3 is the
		// rectangular Gen2 on its motorized kickstand; rev4 is the Gen3
		// Standard, which is aimed by hand and never moves again.
		{"rev3_proto2", "Standard Gen2", aimMotorized},
		{"rev4_prod1", "Standard Gen3", aimManual},
		{"rev2_proto3", "Standard Gen2", aimMotorized},
		{"rev1_pre_production", "Round Gen1", aimMotorized},
		{"mini1_panda_prod1", "Mini", aimManual},
		{"hp1_proto1", "High Performance", aimManual},

		// Case-insensitive, because the field is a vendor string and nothing
		// promises its case.
		{"REV3_PROTO2", "Standard Gen2", aimMotorized},

		// Unplaceable models keep their raw string and make no claim. An
		// invented aim here is the one failure mode with a real-world cost.
		{"", "?", aimUnknown},
		{"standard", "Standard", aimUnknown},
		{"rev9_martian", "rev9_martian", aimUnknown},

		// "hp" matches as a prefix only: two letters loose inside a model name
		// would otherwise turn some future dish into a High Performance.
		{"revX_hp_lookalike", "revX_hp_lookalike", aimUnknown},
	}
	for _, c := range cases {
		got := classifyHardware(c.hw)
		if got.Name != c.name || got.Aim != c.aim {
			t.Errorf("classifyHardware(%q) = {%q, %q}, want {%q, %q}",
				c.hw, got.Name, got.Aim, c.name, c.aim)
		}
	}
}

// The CLI gloss is empty rather than half-formed when there is nothing to say,
// so an unknown model prints its raw string and stops.
func TestHardwareNote(t *testing.T) {
	if got, want := hardwareNote("rev3_proto2"), "  (Standard Gen2, self-aiming)"; got != want {
		t.Errorf("hardwareNote = %q, want %q", got, want)
	}
	if got, want := hardwareNote("mini1_panda_prod1"), "  (Mini, aim by hand)"; got != want {
		t.Errorf("hardwareNote = %q, want %q", got, want)
	}
	if got := hardwareNote("rev9_martian"); got != "" {
		t.Errorf("hardwareNote of an unknown model = %q, want empty", got)
	}
}
