// Pure geometry helpers for sector drawing/editing. No Leaflet, no DOM --
// everything here takes and returns plain {lat, lng} objects so it can be
// reasoned about (and, if a JS test runner ever lands, tested) on its own.

const EARTH_RADIUS_M = 6371008.8; // IUGG mean radius, same sphere PostGIS uses

/// Spherical excess ("shoelace on a sphere") area of a ring, in m².
///
/// Deliberately NOT a planar shoelace on raw degrees: at Israel's latitude a
/// degree of longitude is ~30% shorter than a degree of latitude, so a planar
/// formula would overstate a sector's area by roughly that much. A commander
/// sizing a sector against "how much ground can a team sweep in an hour"
/// needs this to be true, not indicative.
export function ringAreaSquareMeters(points) {
  if (!points || points.length < 3) return 0;
  const toRad = (deg) => (deg * Math.PI) / 180;
  let total = 0;
  for (let i = 0; i < points.length; i++) {
    const a = points[i];
    const b = points[(i + 1) % points.length];
    total +=
      (toRad(b.lng) - toRad(a.lng)) *
      (2 + Math.sin(toRad(a.lat)) + Math.sin(toRad(b.lat)));
  }
  return Math.abs((total * EARTH_RADIUS_M * EARTH_RADIUS_M) / 2);
}

export function formatArea(squareMeters) {
  const km2 = squareMeters / 1e6;
  if (km2 >= 10) return `${km2.toFixed(0)} km²`;
  if (km2 >= 1) return `${km2.toFixed(1)} km²`;
  if (km2 >= 0.01) return `${km2.toFixed(2)} km²`;
  return `${Math.round(squareMeters).toLocaleString()} m²`;
}

// --- Self-intersection -----------------------------------------------------

function orientation(p, q, r) {
  const value =
    (q.lat - p.lat) * (r.lng - q.lng) - (q.lng - p.lng) * (r.lat - q.lat);
  if (Math.abs(value) < 1e-12) return 0;
  return value > 0 ? 1 : 2;
}

function onSegment(p, q, r) {
  return (
    q.lng <= Math.max(p.lng, r.lng) &&
    q.lng >= Math.min(p.lng, r.lng) &&
    q.lat <= Math.max(p.lat, r.lat) &&
    q.lat >= Math.min(p.lat, r.lat)
  );
}

function segmentsIntersect(p1, q1, p2, q2) {
  const o1 = orientation(p1, q1, p2);
  const o2 = orientation(p1, q1, q2);
  const o3 = orientation(p2, q2, p1);
  const o4 = orientation(p2, q2, q1);
  if (o1 !== o2 && o3 !== o4) return true;
  if (o1 === 0 && onSegment(p1, p2, q1)) return true;
  if (o2 === 0 && onSegment(p1, q2, q1)) return true;
  if (o3 === 0 && onSegment(p2, p1, q2)) return true;
  if (o4 === 0 && onSegment(p2, q1, q2)) return true;
  return false;
}

/// True when the ring crosses itself (a "bowtie").
///
/// Worth catching in the UI: PostGIS accepts a self-intersecting ring into a
/// `geography` column without complaint, but the H3 hexification in
/// `polygon_to_cells` will produce a nonsense cell set for it -- which shows
/// up much later as coverage in the wrong place, with nothing pointing back
/// at the moment the sector was drawn.
///
/// O(n²), which is fine: sector rings are hand-drawn, so a dozen vertices.
/// Adjacent edges are skipped since they legitimately share an endpoint.
export function isSelfIntersecting(points) {
  const n = points.length;
  if (n < 4) return false;
  for (let i = 0; i < n; i++) {
    const a1 = points[i];
    const a2 = points[(i + 1) % n];
    for (let j = i + 1; j < n; j++) {
      // Skip edges sharing a vertex (j === i+1, or the wrap-around pair).
      if (j === i || j === (i + 1) % n || (j + 1) % n === i) continue;
      const b1 = points[j];
      const b2 = points[(j + 1) % n];
      if (segmentsIntersect(a1, a2, b1, b2)) return true;
    }
  }
  return false;
}

/// Converts a ring of {lat,lng} into a closed GeoJSON Polygon.
/// GeoJSON is [lng, lat] -- the reverse of every map API -- and the ring must
/// repeat its first position last, which the backend validates.
export function ringToGeoJsonPolygon(points) {
  const ring = points.map((p) => [p.lng, p.lat]);
  ring.push(ring[0]);
  return { type: "Polygon", coordinates: [ring] };
}

/// Inverse of [ringToGeoJsonPolygon]: drops the repeated closing position.
export function geoJsonPolygonToRing(polygon) {
  if (!polygon || !Array.isArray(polygon.coordinates) || !polygon.coordinates[0]) {
    return [];
  }
  const ring = polygon.coordinates[0].map(([lng, lat]) => ({ lat, lng }));
  if (ring.length > 1) {
    const first = ring[0];
    const last = ring[ring.length - 1];
    if (first.lat === last.lat && first.lng === last.lng) ring.pop();
  }
  return ring;
}
