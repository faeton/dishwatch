package main

import (
	"context"
	"fmt"

	"github.com/faeton/dishwatch/internal/geo"
)

func runLocation(ctx context.Context) error {
	c, err := dialDish(ctx)
	if err != nil {
		return err
	}
	defer c.Close()

	loc, err := c.GetLocation(ctx)
	if err != nil {
		return err
	}
	if loc == nil {
		fmt.Println("location not available — enable location access in the Starlink app")
		return nil
	}
	fmt.Printf("lat=%.6f  lon=%.6f  alt=%.0fm\n", loc.LLA.Lat, loc.LLA.Lon, loc.LLA.Alt)
	place, _ := geo.Reverse(ctx, loc.LLA.Lat, loc.LLA.Lon)
	if place != "" && place != "unknown" {
		fmt.Println("place:", place)
	}
	return nil
}
