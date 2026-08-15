package dish

import (
	"reflect"
	"testing"
)

// ring builds a History whose buffers are 0..n-1, with the write cursor at cur.
func ring(n int, cur int64) *History {
	v := make([]float64, n)
	for i := range v {
		v[i] = float64(i)
	}
	return &History{Current: cur, PopPingLatencyMs: v, PowerIn: v}
}

func TestLastN(t *testing.T) {
	tests := []struct {
		name string
		h    *History
		n    int
		want []float64
	}{
		{
			// Cursor has not wrapped: the last 3 samples end at index cur-1.
			name: "no wrap",
			h:    ring(10, 5),
			n:    3,
			want: []float64{2, 3, 4},
		},
		{
			// Cursor past the end wraps modulo the ring length.
			name: "wrapped",
			h:    ring(10, 12),
			n:    4,
			want: []float64{8, 9, 0, 1},
		},
		{
			// Asking for more than the ring holds is clamped, not an error.
			name: "n exceeds ring",
			h:    ring(4, 4),
			n:    99,
			want: []float64{0, 1, 2, 3},
		},
		{
			// The shape a real dish sends shortly after a reboot: the ring is
			// always full-size (900 slots, measured) and `Current` says how much
			// of it was ever written. Clamping to the allocation alone returned
			// the unwritten slots as readings — flat-then-real sparklines, means
			// diluted toward zero, and a covered-window figure that overstated
			// the data by the whole unwritten remainder.
			name: "allocated but partially written",
			h:    ring(10, 3),
			n:    10,
			want: []float64{0, 1, 2},
		},
		{
			// Same shape, asking for less than was written: still the newest.
			name: "partially written, n below the written count",
			h:    ring(10, 3),
			n:    2,
			want: []float64{1, 2},
		},
		{
			name: "empty ring",
			h:    &History{Current: 5},
			n:    3,
			want: nil,
		},
		{
			// A zero cursor means the dish has reported nothing yet; returning
			// the raw ring here would invent samples.
			name: "zero cursor",
			h:    ring(10, 0),
			n:    3,
			want: nil,
		},
		{
			name: "n is zero",
			h:    ring(10, 5),
			n:    0,
			want: []float64{},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.h.LastN(tc.h.PopPingLatencyMs, tc.n)
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("LastN(%d) = %v, want %v", tc.n, got, tc.want)
			}
		})
	}
}

func TestLatest(t *testing.T) {
	tests := []struct {
		name   string
		h      *History
		want   float64
		wantOK bool
	}{
		{"no wrap", ring(10, 5), 4, true},
		{"exact wrap", ring(10, 10), 9, true},
		{"past wrap", ring(10, 13), 2, true},
		{"empty ring", &History{Current: 5}, 0, false},
		{"zero cursor", ring(10, 0), 0, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := tc.h.Latest(tc.h.PopPingLatencyMs)
			if got != tc.want || ok != tc.wantOK {
				t.Errorf("Latest() = (%v, %v), want (%v, %v)", got, ok, tc.want, tc.wantOK)
			}
		})
	}
}
