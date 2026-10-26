// The e2e road: a straight north-south segment (a meridian, so the simulator's linear interpolation is also the
// great circle the analysis measures against), ~55 km — over an hour at 15 m/s.
export const ROUTE = { a: [43.8, 18.4], b: [44.3, 18.4] };

const R = 6371008.8;
const metersPerDegLat = (Math.PI / 180) * R;

/** Point `m` meters along ROUTE from a. */
export const pointAlong = (m) => [ROUTE.a[0] + m / metersPerDegLat, ROUTE.a[1]];

/** Default parking point (start of the road) when no drive state is known. */
export const PARK = ROUTE.a;

/**
 * Waypoints of a small square (side 4 m) around `center`, `loops` times: walked at 0.5 m/s it gives ~1 fix/s
 * within ~3 m of the center at a speed far below movingSpeedMps — what a parked phone reports.
 */
export const parkLoop = (center = PARK, loops = 60) => {
  const dLat = 2 / metersPerDegLat;
  const dLon = 2 / (metersPerDegLat * Math.cos((center[0] * Math.PI) / 180));
  const square = [
    [center[0] + dLat, center[1] + dLon],
    [center[0] + dLat, center[1] - dLon],
    [center[0] - dLat, center[1] - dLon],
    [center[0] - dLat, center[1] + dLon],
  ];
  return Array.from({ length: loops }, () => square).flat();
};
