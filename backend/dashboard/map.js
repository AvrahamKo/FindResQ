// Leaflet-based tactical map: sector boundaries, POD-shaded H3 hex coverage,
// presence markers, SOS markers, and report markers. `L` and `h3` are loaded
// as globals from CDN scripts in index.html (no bundler in this project).

export const SECTOR_PALETTE = [
  "#3fa9f5", "#e67e22", "#9b59b6", "#1abc9c", "#e91e63", "#f1c40f", "#2ecc71",
];

export const PRESENCE_COLORS = {
  active: "#2ecc71",
  stale: "#f1c40f",
  dead_zone: "#e67e22",
  battery_dead: "#7f8c8d",
  mia: "#e74c3c",
};

// Keys match the `reports.kind` check constraint (migration 0001), which is
// what ReportOut.kind actually serializes -- not the shorthand names used in
// HANDOVER.md's prose.
export const REPORT_KIND_STYLE = {
  subject_found: { color: "#2980b9", label: "S" },
  medical: { color: "#c0392b", label: "+" },
  item_found: { color: "#f39c12", label: "I" },
  hazard: { color: "#d35400", label: "!" },
  no_passage: { color: "#8e44ad", label: "X" },
};

// Green at POD=1 (well searched), red at POD=0 (unsearched). Clamped since a
// tuned sector could in principle exceed 1 with repeat coverage stacking.
function podColor(pod) {
  const t = Math.max(0, Math.min(1, pod));
  return `hsl(${Math.round(t * 120)}, 70%, 45%)`;
}

function pinIcon(className, html) {
  return L.divIcon({ className: "", html: `<div class="${className}">${html}</div>`, iconSize: [26, 26], iconAnchor: [13, 13] });
}

class SectorLayers {
  constructor(color) {
    this.color = color;
    this.boundaryLayer = null;
    this.hexLayers = new Map(); // hex_id -> polygon
    this.presenceMarkers = new Map(); // device_id -> marker
    this.sosMarkers = new Map(); // alert_id -> marker
    this.reportMarkers = new Map(); // report_id -> marker
  }
}

export class TacticalMap {
  constructor(containerId) {
    this.map = L.map(containerId).setView([31.5, 34.8], 12);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors",
      maxZoom: 19,
    }).addTo(this.map);

    this.sectors = new Map(); // sectorId -> SectorLayers
    this._paletteIndex = 0;

    this._drawing = false;
    this._drawPoints = [];
    this._drawPreview = null;
    this._drawClickHandler = null;
  }

  sectorColor(sectorId) {
    const existing = this.sectors.get(sectorId);
    if (existing) return existing.color;
    const color = SECTOR_PALETTE[this._paletteIndex % SECTOR_PALETTE.length];
    this._paletteIndex += 1;
    return color;
  }

  addSector(sector) {
    if (this.sectors.has(sector.id)) return;
    const color = this.sectorColor(sector.id);
    const layers = new SectorLayers(color);
    layers.boundaryLayer = L.geoJSON(sector.boundary, {
      style: { color, weight: 2, fillOpacity: 0.03 },
    })
      .bindTooltip(sector.name)
      .addTo(this.map);
    this.sectors.set(sector.id, layers);
    this._fitAll();
  }

  removeSector(sectorId) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    this.map.removeLayer(layers.boundaryLayer);
    for (const l of layers.hexLayers.values()) this.map.removeLayer(l);
    for (const l of layers.presenceMarkers.values()) this.map.removeLayer(l);
    for (const l of layers.sosMarkers.values()) this.map.removeLayer(l);
    for (const l of layers.reportMarkers.values()) this.map.removeLayer(l);
    this.sectors.delete(sectorId);
  }

  _fitAll() {
    const bounds = [];
    for (const layers of this.sectors.values()) {
      const b = layers.boundaryLayer.getBounds();
      if (b.isValid()) bounds.push(b);
    }
    if (bounds.length === 0) return;
    let combined = bounds[0];
    for (const b of bounds.slice(1)) combined = combined.extend(b);
    this.map.fitBounds(combined, { padding: [40, 40] });
  }

  applyHexes(sectorId, hexes) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    for (const hex of hexes) {
      const pod = Number(hex.cumulative_pod);
      const boundary = h3.cellToBoundary(hex.hex_id);
      const existing = layers.hexLayers.get(hex.hex_id);
      if (existing) {
        existing.setStyle({ color: podColor(pod), fillColor: podColor(pod) });
        existing.setLatLngs(boundary);
      } else {
        const poly = L.polygon(boundary, {
          color: podColor(pod),
          weight: 1,
          fillColor: podColor(pod),
          fillOpacity: 0.45,
        }).addTo(this.map);
        poly.bindTooltip(
          () => `POD ${pod.toFixed(2)} · ${hex.distinct_searchers} searcher(s)`,
          { sticky: true }
        );
        layers.hexLayers.set(hex.hex_id, poly);
      }
    }
  }

  applyPresence(sectorId, devices) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    for (const dev of devices) {
      if (dev.last_lat == null || dev.last_lng == null) continue;
      const color = PRESENCE_COLORS[dev.presence_state] || "#ffffff";
      const latlng = [dev.last_lat, dev.last_lng];
      const existing = layers.presenceMarkers.get(dev.device_id);
      const popup = `Device ${dev.device_id.slice(0, 8)}<br>State: ${dev.presence_state}<br>Battery: ${dev.last_battery_pct ?? "?"}%`;
      if (existing) {
        existing.setLatLng(latlng);
        existing.setStyle({ color, fillColor: color });
        existing.setPopupContent(popup);
      } else {
        const marker = L.circleMarker(latlng, {
          radius: 7,
          color,
          fillColor: color,
          fillOpacity: 0.9,
          weight: 2,
        })
          .bindPopup(popup)
          .addTo(this.map);
        layers.presenceMarkers.set(dev.device_id, marker);
      }
    }
  }

  applySos(sectorId, alerts) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    for (const alert of alerts) {
      const isClosed = alert.status === "resolved" || alert.status === "cancelled";
      const existing = layers.sosMarkers.get(alert.id);
      if (isClosed) {
        if (existing) {
          this.map.removeLayer(existing);
          layers.sosMarkers.delete(alert.id);
        }
        continue;
      }
      if (alert.lat == null || alert.lng == null) continue;
      const latlng = [alert.lat, alert.lng];
      const iconClass = alert.status === "acknowledged" ? "sos-pin acknowledged" : "sos-pin";
      const popup = `SOS · ${alert.status}<br>Triggered ${new Date(alert.triggered_at).toLocaleTimeString()}`;
      if (existing) {
        existing.setLatLng(latlng);
        existing.setIcon(pinIcon(iconClass, "SOS"));
        existing.setPopupContent(popup);
      } else {
        const marker = L.marker(latlng, { icon: pinIcon(iconClass, "SOS") })
          .bindPopup(popup)
          .addTo(this.map);
        layers.sosMarkers.set(alert.id, marker);
      }
    }
  }

  applyReports(sectorId, reports) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    for (const report of reports) {
      const style = REPORT_KIND_STYLE[report.kind] || { color: "#95a5a6", label: "?" };
      const latlng = [report.lat, report.lng];
      const html = `<div class="report-pin" style="background:${style.color}">${style.label}</div>`;
      const icon = L.divIcon({ className: "", html, iconSize: [22, 22], iconAnchor: [11, 11] });
      const popup = `${report.kind}${report.status === "acknowledged" ? " (ack'd)" : ""}<br>${report.note || ""}`;
      const existing = layers.reportMarkers.get(report.id);
      if (existing) {
        existing.setLatLng(latlng);
        existing.setIcon(icon);
        existing.setPopupContent(popup);
      } else {
        const marker = L.marker(latlng, { icon }).bindPopup(popup).addTo(this.map);
        layers.reportMarkers.set(report.id, marker);
      }
    }
  }

  // ---- Sector boundary drawing (for "New Sector") ----

  startDrawing(onPointsChange) {
    this.cancelDrawing();
    this._drawing = true;
    this._drawPoints = [];
    this.map.getContainer().style.cursor = "crosshair";
    this._drawClickHandler = (e) => {
      this._drawPoints.push(e.latlng);
      this._renderDrawPreview();
      onPointsChange(this._drawPoints.length);
    };
    this.map.on("click", this._drawClickHandler);
  }

  _renderDrawPreview() {
    if (this._drawPreview) {
      this.map.removeLayer(this._drawPreview);
      this._drawPreview = null;
    }
    if (this._drawPoints.length === 0) return;
    this._drawPreview = L.polygon(this._drawPoints, {
      color: "#3fa9f5",
      dashArray: "4 4",
      fillOpacity: 0.1,
    }).addTo(this.map);
  }

  cancelDrawing() {
    this._drawing = false;
    if (this._drawClickHandler) {
      this.map.off("click", this._drawClickHandler);
      this._drawClickHandler = null;
    }
    if (this._drawPreview) {
      this.map.removeLayer(this._drawPreview);
      this._drawPreview = null;
    }
    this._drawPoints = [];
    this.map.getContainer().style.cursor = "";
  }

  // Returns a GeoJSON Polygon body, or null if fewer than 3 points were placed.
  finishDrawing() {
    if (this._drawPoints.length < 3) return null;
    const ring = this._drawPoints.map((ll) => [ll.lng, ll.lat]);
    ring.push(ring[0]);
    const boundary = { type: "Polygon", coordinates: [ring] };
    this.cancelDrawing();
    return boundary;
  }
}
