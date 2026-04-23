package dish

import (
	"context"
	"encoding/json"
	"fmt"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// Location is a trimmed view of GetLocation. The dish only populates this
// when "location access" is enabled in the Starlink app.
type Location struct {
	LLA struct {
		Lat float64 `json:"lat"`
		Lon float64 `json:"lon"`
		Alt float64 `json:"alt"`
	} `json:"lla"`
}

// GetLocation fetches and decodes GetLocation. Returns (nil, nil) if the dish
// returned an empty response (access likely disabled).
func (c *Client) GetLocation(ctx context.Context) (*Location, error) {
	raw, err := c.Call(ctx, []byte(`{"get_location":{}}`))
	if err != nil {
		// Dish returns PermissionDenied when location access is disabled
		// in the app — treat as "not available" rather than a hard error.
		if st, ok := status.FromError(err); ok && st.Code() == codes.PermissionDenied {
			return nil, nil
		}
		return nil, err
	}
	var wrap struct {
		GetLocation json.RawMessage `json:"getLocation"`
	}
	if err := json.Unmarshal(raw, &wrap); err != nil {
		return nil, fmt.Errorf("decode envelope: %w", err)
	}
	if len(wrap.GetLocation) == 0 || string(wrap.GetLocation) == "{}" {
		return nil, nil
	}
	var l Location
	if err := json.Unmarshal(wrap.GetLocation, &l); err != nil {
		return nil, fmt.Errorf("decode location: %w", err)
	}
	if l.LLA.Lat == 0 && l.LLA.Lon == 0 {
		return nil, nil
	}
	return &l, nil
}
