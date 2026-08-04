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
    this.onClick = null;
    this.hexLayers = new Map(); // hex_id -> polygon
    this.presenceMarkers = new Map(); // device_id -> marker
    this.sosMarkers = new Map(); // alert_id -> marker
    this.reportMarkers = new Map(); // report_id -> marker
  }
}

export class TacticalMap {
  constructor(containerId) {
    // zoomAnimation is OFF deliberately. Leaflet's animated path defers the
    // actual view change into a requestAnimationFrame callback and returns
    // "handled" to setView, so in any tab where rAF is throttled or not
    // running (a backgrounded dashboard, a headless/non-compositing browser)
    // fitBounds silently does nothing -- the map just never moves, with no
    // error. It can also wedge permanently: setView bails early forever if
    // `_animatingZoom` is left true by a transitionend that never fires.
    // "Click a sector, map doesn't move" is a bad failure for a tactical
    // map, so we trade the glide for a deterministic synchronous snap.
    this.map = L.map(containerId, { zoomAnimation: false }).setView([31.5, 34.8], 12);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", {
      attribution: "&copy; OpenStreetMap contributors",
      maxZoom: 19,
    }).addTo(this.map);

    this.sectors = new Map(); // sectorId -> SectorLayers
    this._paletteIndex = 0;
    this._selectedSectorId = null;

    this._drawing = false;
    this._editing = false;
    this._editingSectorId = null;
    this._drawPoints = [];
    this._drawPreview = null;
    this._drawClickHandler = null;
    this._vertexHandles = [];
    this._onGeometryChange = null;
  }

  sectorColor(sectorId) {
    const existing = this.sectors.get(sectorId);
    if (existing) return existing.color;
    const color = SECTOR_PALETTE[this._paletteIndex % SECTOR_PALETTE.length];
    this._paletteIndex += 1;
    return color;
  }

  addSector(sector, { onClick } = {}) {
    if (this.sectors.has(sector.id)) return;
    const color = this.sectorColor(sector.id);
    const layers = new SectorLayers(color);
    layers.boundaryLayer = L.geoJSON(sector.boundary, {
      style: { color, weight: 2, fillOpacity: 0.03 },
    })
      .bindTooltip(sector.name)
      .addTo(this.map);
    // Clicking the polygon itself selects the sector, same as clicking its
    // row in the sidebar -- but only when not mid-draw, since drawing needs
    // raw map clicks and a stray polygon hit would otherwise hijack them.
    if (onClick) {
      // Retained so replaceSectorBoundary can rebind it after a boundary edit.
      layers.onClick = onClick;
      layers.boundaryLayer.on("click", (e) => {
        if (this._drawing || this._editing) return;
        L.DomEvent.stop(e);
        onClick(sector.id);
      });
    }
    this.sectors.set(sector.id, layers);
    this._applySelectionStyling();
    // Deliberately does NOT fit here: sectors are added in a batch at load,
    // and one fitBounds per sector means N-1 wasted view changes. The caller
    // fits once, when it knows the batch is done.
  }

  // ---- Selection / focus ----

  focusSector(sectorId) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    this._selectedSectorId = sectorId;
    this._applySelectionStyling();
    const bounds = layers.boundaryLayer.getBounds();
    if (bounds.isValid()) this.map.fitBounds(bounds, { padding: [60, 60] });
  }

  clearFocus() {
    this._selectedSectorId = null;
    this._applySelectionStyling();
    this.fitAll();
  }

  _applySelectionStyling() {
    for (const [id, layers] of this.sectors) {
      const isSelected = id === this._selectedSectorId;
      const dimmed = this._selectedSectorId !== null && !isSelected;
      layers.boundaryLayer.setStyle({
        color: layers.color,
        weight: isSelected ? 3 : dimmed ? 1 : 2,
        opacity: dimmed ? 0.35 : 1,
        fillOpacity: isSelected ? 0.1 : dimmed ? 0.01 : 0.03,
      });
    }
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

  // Fits every sector into view. Public: the caller decides when a batch of
  // addSector() calls is finished (see addSector).
  fitAll() {
    const combined = L.latLngBounds([]);
    for (const layers of this.sectors.values()) {
      const b = layers.boundaryLayer.getBounds();
      if (b.isValid()) combined.extend(b);
    }
    if (!combined.isValid()) return;
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
  //
  // Drawing and editing share `_drawPoints`, `_renderDrawPreview` and the
  // same {added, removed, moved} -> onChange callback, so the area readout
  // and self-intersection warning are computed in one place for both modes.

  startDrawing(onChange) {
    this.cancelDrawing();
    this._drawing = true;
    this._drawPoints = [];
    this._onGeometryChange = onChange;
    this.map.getContainer().style.cursor = "crosshair";
    this._drawClickHandler = (e) => {
      this._drawPoints.push(e.latlng);
      this._renderDrawPreview();
      this._emitGeometryChange();
    };
    this.map.on("click", this._drawClickHandler);
    this._emitGeometryChange();
  }

  /// Removes the most recently placed point. No-op when empty, so a commander
  /// can hold the button down without it throwing.
  undoLastPoint() {
    if (this._drawPoints.length === 0) return;
    this._drawPoints.pop();
    this._renderDrawPreview();
    this._emitGeometryChange();
  }

  _emitGeometryChange() {
    if (!this._onGeometryChange) return;
    this._onGeometryChange({
      points: this._drawPoints.map((ll) => ({ lat: ll.lat, lng: ll.lng })),
      count: this._drawPoints.length,
    });
  }

  _renderDrawPreview() {
    if (this._drawPreview) {
      this.map.removeLayer(this._drawPreview);
      this._drawPreview = null;
    }
    for (const handle of this._vertexHandles) this.map.removeLayer(handle);
    this._vertexHandles = [];

    if (this._drawPoints.length === 0) return;

    this._drawPreview = L.polygon(this._drawPoints, {
      color: "#3fa9f5",
      dashArray: "4 4",
      fillOpacity: 0.1,
    }).addTo(this.map);

    // Vertex handles exist in BOTH modes: while drawing they show what has
    // been placed so far, and while editing they are the drag targets.
    this._drawPoints.forEach((latlng, index) => {
      const handle = L.circleMarker(latlng, {
        radius: 6,
        color: "#ffffff",
        weight: 2,
        fillColor: "#3fa9f5",
        fillOpacity: 1,
        // Only draggable in edit mode -- during drawing, map clicks are
        // placing points and a draggable handle would swallow them.
        interactive: this._editing,
        bubblingMouseEvents: false,
      }).addTo(this.map);

      if (!this._editing) return;

      handle.on("mousedown", (e) => this._beginVertexDrag(index, e));
      // Right-click removes, but never below the 3 vertices a polygon needs.
      handle.on("contextmenu", (e) => {
        L.DomEvent.stop(e);
        if (this._drawPoints.length <= 3) return;
        this._drawPoints.splice(index, 1);
        this._renderDrawPreview();
        this._emitGeometryChange();
      });
      this._vertexHandles.push(handle);
    });

    if (this._editing) this._renderMidpointHandles();
  }

  /// Faint handles at each edge midpoint; dragging one inserts a new vertex
  /// there. This is the standard way to ADD detail to an existing outline --
  /// without it, a commander could only move or delete what was already drawn.
  _renderMidpointHandles() {
    const points = this._drawPoints;
    for (let i = 0; i < points.length; i++) {
      const a = points[i];
      const b = points[(i + 1) % points.length];
      const mid = L.latLng((a.lat + b.lat) / 2, (a.lng + b.lng) / 2);
      const handle = L.circleMarker(mid, {
        radius: 4,
        color: "#ffffff",
        weight: 1,
        fillColor: "#8b95a1",
        fillOpacity: 0.85,
        interactive: true,
        bubblingMouseEvents: false,
      }).addTo(this.map);
      const insertAt = i + 1;
      handle.on("mousedown", (e) => {
        this._drawPoints.splice(insertAt, 0, mid);
        this._renderDrawPreview();
        this._beginVertexDrag(insertAt, e);
      });
      this._vertexHandles.push(handle);
    }
  }

  /// Hand-rolled drag rather than L.Marker's `draggable`: circleMarker has no
  /// drag support, and using real markers would mean managing icon anchors
  /// for what is a 6px dot.
  _beginVertexDrag(index, event) {
    L.DomEvent.stop(event);
    this.map.dragging.disable();

    const onMove = (moveEvent) => {
      this._drawPoints[index] = moveEvent.latlng;
      if (this._drawPreview) this._drawPreview.setLatLngs(this._drawPoints);
      this._emitGeometryChange();
    };
    const onUp = () => {
      this.map.off("mousemove", onMove);
      this.map.off("mouseup", onUp);
      this.map.dragging.enable();
      // Re-render once at the end so midpoint handles land on the new edges.
      this._renderDrawPreview();
      this._emitGeometryChange();
    };
    this.map.on("mousemove", onMove);
    this.map.on("mouseup", onUp);
  }

  // ---- Editing an existing sector's boundary ----

  /// Starts vertex editing from the sector's current outline. The sector's
  /// own boundary layer is hidden meanwhile so the editable preview is not
  /// drawn on top of a stale copy of itself.
  startEditingSector(sectorId, ring, onChange) {
    this.cancelDrawing();
    this._editing = true;
    this._editingSectorId = sectorId;
    this._onGeometryChange = onChange;
    this._drawPoints = ring.map((p) => L.latLng(p.lat, p.lng));

    const layers = this.sectors.get(sectorId);
    if (layers) this.map.removeLayer(layers.boundaryLayer);

    this._renderDrawPreview();
    this._emitGeometryChange();
  }

  /// Returns the edited ring as a GeoJSON Polygon, or null if it is not a
  /// usable polygon. Does NOT clear edit mode -- the caller keeps editing if
  /// the save fails.
  getEditedBoundary() {
    if (this._drawPoints.length < 3) return null;
    const ring = this._drawPoints.map((ll) => [ll.lng, ll.lat]);
    ring.push(ring[0]);
    return { type: "Polygon", coordinates: [ring] };
  }

  cancelDrawing() {
    // Restore the boundary layer hidden by startEditingSector.
    if (this._editingSectorId) {
      const layers = this.sectors.get(this._editingSectorId);
      if (layers && !this.map.hasLayer(layers.boundaryLayer)) {
        layers.boundaryLayer.addTo(this.map);
      }
    }
    this._drawing = false;
    this._editing = false;
    this._editingSectorId = null;
    this._onGeometryChange = null;
    if (this._drawClickHandler) {
      this.map.off("click", this._drawClickHandler);
      this._drawClickHandler = null;
    }
    if (this._drawPreview) {
      this.map.removeLayer(this._drawPreview);
      this._drawPreview = null;
    }
    for (const handle of this._vertexHandles) this.map.removeLayer(handle);
    this._vertexHandles = [];
    this._drawPoints = [];
    this.map.getContainer().style.cursor = "";
  }

  /// Replaces a sector's rendered outline after a successful boundary save,
  /// without tearing down its hex/presence/marker layers.
  replaceSectorBoundary(sectorId, geojsonBoundary, name) {
    const layers = this.sectors.get(sectorId);
    if (!layers) return;
    this.map.removeLayer(layers.boundaryLayer);
    layers.boundaryLayer = L.geoJSON(geojsonBoundary, {
      style: { color: layers.color, weight: 2, fillOpacity: 0.03 },
    })
      .bindTooltip(name)
      .addTo(this.map);
    if (layers.onClick) {
      layers.boundaryLayer.on("click", (e) => {
        if (this._drawing || this._editing) return;
        L.DomEvent.stop(e);
        layers.onClick(sectorId);
      });
    }
    this._applySelectionStyling();
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
