/// Response DTOs mirroring the backend's Pydantic schemas. Deliberately
/// lean: each class only carries the fields Phase 5b's flows actually use,
/// not a full transcription of every backend field -- `SectorOut` in
/// particular carries many geospatial tuning parameters (Phase 3/4
/// concerns) that have no reader yet on the client.
library;

class UserInfo {
  final String id;
  final String phoneE164;
  final String displayName;
  final String verificationStatus;

  const UserInfo({
    required this.id,
    required this.phoneE164,
    required this.displayName,
    required this.verificationStatus,
  });

  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
    id: json['id'] as String,
    phoneE164: json['phone_e164'] as String,
    displayName: json['display_name'] as String,
    verificationStatus: json['verification_status'] as String,
  );
}

class OtpRequestResult {
  final String challengeId;
  final DateTime expiresAt;

  /// Only populated when the backend runs with ENV=local -- lets local
  /// development proceed without a real SMS provider. Always null against
  /// a real deployment.
  final String? devCode;

  const OtpRequestResult({
    required this.challengeId,
    required this.expiresAt,
    this.devCode,
  });

  factory OtpRequestResult.fromJson(Map<String, dynamic> json) =>
      OtpRequestResult(
        challengeId: json['challenge_id'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        devCode: json['dev_code'] as String?,
      );
}

class AuthTokenResult {
  final String accessToken;
  final DateTime expiresAt;
  final UserInfo user;

  const AuthTokenResult({
    required this.accessToken,
    required this.expiresAt,
    required this.user,
  });

  factory AuthTokenResult.fromJson(Map<String, dynamic> json) =>
      AuthTokenResult(
        accessToken: json['access_token'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        user: UserInfo.fromJson(json['user'] as Map<String, dynamic>),
      );
}

class KeyChallengeResult {
  final String challengeId;

  /// Base64-encoded nonce the device must sign with its Ed25519 private key.
  final String nonceBase64;
  final DateTime expiresAt;

  const KeyChallengeResult({
    required this.challengeId,
    required this.nonceBase64,
    required this.expiresAt,
  });

  factory KeyChallengeResult.fromJson(Map<String, dynamic> json) =>
      KeyChallengeResult(
        challengeId: json['challenge_id'] as String,
        nonceBase64: json['nonce'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
      );
}

class DeviceInfo {
  final String id;
  final int wireId;
  final String publicKeyBase64;
  final String platform;
  final bool meshCapable;

  const DeviceInfo({
    required this.id,
    required this.wireId,
    required this.publicKeyBase64,
    required this.platform,
    required this.meshCapable,
  });

  factory DeviceInfo.fromJson(Map<String, dynamic> json) => DeviceInfo(
    id: json['id'] as String,
    wireId: json['wire_id'] as int,
    publicKeyBase64: json['public_key'] as String,
    platform: json['platform'] as String,
    meshCapable: json['mesh_capable'] as bool,
  );
}

class JoinResult {
  final String membershipId;
  final String sectorId;
  final String status;
  final String? batteryWarning;

  const JoinResult({
    required this.membershipId,
    required this.sectorId,
    required this.status,
    this.batteryWarning,
  });

  factory JoinResult.fromJson(Map<String, dynamic> json) => JoinResult(
    membershipId: json['membership_id'] as String,
    sectorId: json['sector_id'] as String,
    status: json['status'] as String,
    batteryWarning: json['battery_warning'] as String?,
  );
}

class MembershipInfo {
  final String id;
  final String sectorId;
  final String status;
  final String role;
  final String movementMode;
  final DateTime? sessionExpiresAt;

  const MembershipInfo({
    required this.id,
    required this.sectorId,
    required this.status,
    required this.role,
    required this.movementMode,
    this.sessionExpiresAt,
  });

  factory MembershipInfo.fromJson(Map<String, dynamic> json) => MembershipInfo(
    id: json['id'] as String,
    sectorId: json['sector_id'] as String,
    status: json['status'] as String,
    role: json['role'] as String,
    movementMode: json['movement_mode'] as String,
    sessionExpiresAt: json['session_expires_at'] == null
        ? null
        : DateTime.parse(json['session_expires_at'] as String),
  );
}

/// One WGS84 position.
///
/// GeoJSON orders each coordinate pair as `[longitude, latitude]` -- the
/// reverse of the `(lat, lng)` order every map widget and every other part
/// of this app uses. That swap happens exactly ONCE, in
/// [GeoPoint.fromGeoJson], rather than at each call site: a flipped pair is
/// the classic silent geo bug (it doesn't throw, it just puts the sector in
/// the wrong hemisphere).
class GeoPoint {
  final double latitude;
  final double longitude;

  const GeoPoint({required this.latitude, required this.longitude});

  factory GeoPoint.fromGeoJson(List<dynamic> pair) => GeoPoint(
    longitude: (pair[0] as num).toDouble(),
    latitude: (pair[1] as num).toDouble(),
  );
}

class SectorInfo {
  final String id;
  final String eventId;
  final String name;
  final String status;

  /// The sector's exterior boundary ring. Empty when the payload carried no
  /// boundary -- callers must handle that rather than assume a polygon (the
  /// map degrades to "your position only" instead of failing).
  final List<GeoPoint> boundary;

  const SectorInfo({
    required this.id,
    required this.eventId,
    required this.name,
    required this.status,
    this.boundary = const [],
  });

  factory SectorInfo.fromJson(Map<String, dynamic> json) => SectorInfo(
    id: json['id'] as String,
    eventId: json['event_id'] as String,
    name: json['name'] as String,
    status: json['status'] as String,
    boundary: _parseBoundary(json['boundary']),
  );

  /// Reads the exterior ring out of a GeoJSON Polygon. Interior rings
  /// (holes) are deliberately ignored -- `SectorCreate` only ever accepts a
  /// single-ring polygon, so a hole would mean the backend contract changed.
  static List<GeoPoint> _parseBoundary(Object? raw) {
    if (raw is! Map) return const [];
    final coordinates = raw['coordinates'];
    if (coordinates is! List || coordinates.isEmpty) return const [];
    final exteriorRing = coordinates.first;
    if (exteriorRing is! List) return const [];
    return exteriorRing
        .whereType<List>()
        .where((pair) => pair.length >= 2)
        .map(GeoPoint.fromGeoJson)
        .toList(growable: false);
  }
}

/// One derived H3 coverage cell. [boundary] is already expanded by the
/// backend so the field app can render and cache it without an H3 runtime.
class CoverageCell {
  final String hexId;
  final double cumulativePod;
  final int distinctSearchers;
  final DateTime? lastContributionAt;
  final List<GeoPoint> boundary;

  const CoverageCell({
    required this.hexId,
    required this.cumulativePod,
    required this.distinctSearchers,
    required this.lastContributionAt,
    required this.boundary,
  });

  factory CoverageCell.fromJson(Map<String, dynamic> json) => CoverageCell(
    hexId: json['hex_id'] as String,
    cumulativePod: (json['cumulative_pod'] as num).toDouble(),
    distinctSearchers: json['distinct_searchers'] as int,
    lastContributionAt: json['last_contribution_at'] == null
        ? null
        : DateTime.parse(json['last_contribution_at'] as String),
    // Coverage boundaries use the native H3 [lat, lng] order, unlike
    // GeoJSON sector boundaries. Keep the two parsers deliberately distinct.
    boundary: (json['boundary'] as List<dynamic>? ?? const [])
        .whereType<List>()
        .where((pair) => pair.length >= 2)
        .map(
          (pair) => GeoPoint(
            latitude: (pair[0] as num).toDouble(),
            longitude: (pair[1] as num).toDouble(),
          ),
        )
        .toList(growable: false),
  );

  Map<String, dynamic> toJson() => {
    'hex_id': hexId,
    'cumulative_pod': cumulativePod,
    'distinct_searchers': distinctSearchers,
    'last_contribution_at': lastContributionAt?.toIso8601String(),
    'boundary': boundary
        .map((point) => [point.latitude, point.longitude])
        .toList(growable: false),
  };
}

class CoverageSnapshot {
  final String sectorId;
  final int resolution;
  final List<CoverageCell> cells;

  const CoverageSnapshot({
    required this.sectorId,
    required this.resolution,
    required this.cells,
  });

  factory CoverageSnapshot.fromJson(Map<String, dynamic> json) =>
      CoverageSnapshot(
        sectorId: json['sector_id'] as String,
        resolution: json['resolution'] as int,
        cells: (json['hexes'] as List<dynamic>? ?? const [])
            .map((item) => CoverageCell.fromJson(item as Map<String, dynamic>))
            .toList(growable: false),
      );

  Map<String, dynamic> toJson() => {
    'sector_id': sectorId,
    'resolution': resolution,
    'hexes': cells.map((cell) => cell.toJson()).toList(growable: false),
  };
}

class SessionIssueResult {
  final String accessToken;
  final DateTime expiresAt;
  final int keyEpoch;

  /// Base64-encoded, 32-byte raw sector key. Delivered exactly once, over
  /// TLS -- the caller is responsible for persisting it into Secure Storage
  /// immediately and never logging or re-transmitting it.
  final String sectorKeyBase64;
  final SectorInfo sector;

  const SessionIssueResult({
    required this.accessToken,
    required this.expiresAt,
    required this.keyEpoch,
    required this.sectorKeyBase64,
    required this.sector,
  });

  factory SessionIssueResult.fromJson(Map<String, dynamic> json) =>
      SessionIssueResult(
        accessToken: json['access_token'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        keyEpoch: json['key_epoch'] as int,
        sectorKeyBase64: json['sector_key'] as String,
        sector: SectorInfo.fromJson(json['sector'] as Map<String, dynamic>),
      );
}

/// Mirrors `backend/app/api/schemas/ingest.py`'s `IngestResponse` -- counts
/// only, no per-blob outcome. That's deliberate on the backend's part: every
/// count bucket here (accepted, duplicate, decrypt_failed, signature_invalid,
/// wrong_device, malformed) is a TERMINAL, deterministic outcome for the
/// exact packet the pipeline evaluated. There is no "try again later"
/// category in a 200 response -- a decrypt failure or bad signature will
/// fail identically on every retry, so [IngestSyncController] acknowledges
/// (deletes from the local buffer) the WHOLE batch it sent on any 200,
/// regardless of how the counts split, and only leaves a batch buffered for
/// retry when the request itself didn't get a 200 at all (network failure,
/// 5xx, timeout).
class IngestResult {
  final int accepted;
  final int duplicate;
  final int decryptFailed;
  final int signatureInvalid;
  final int wrongDevice;
  final int malformed;
  final int segmentsOpened;
  final int segmentsExtended;
  final int segmentsClosed;
  final int hexesTouched;

  const IngestResult({
    required this.accepted,
    required this.duplicate,
    required this.decryptFailed,
    required this.signatureInvalid,
    required this.wrongDevice,
    required this.malformed,
    required this.segmentsOpened,
    required this.segmentsExtended,
    required this.segmentsClosed,
    required this.hexesTouched,
  });

  /// Every blob the pipeline looked at ends up in exactly one bucket, so
  /// this is the count of blobs actually resolved -- everything except
  /// [accepted] is still terminal, just not newly-added data.
  int get rejected =>
      duplicate + decryptFailed + signatureInvalid + wrongDevice + malformed;

  factory IngestResult.fromJson(Map<String, dynamic> json) => IngestResult(
    accepted: json['accepted'] as int,
    duplicate: json['duplicate'] as int,
    decryptFailed: json['decrypt_failed'] as int,
    signatureInvalid: json['signature_invalid'] as int,
    wrongDevice: json['wrong_device'] as int,
    malformed: json['malformed'] as int,
    segmentsOpened: json['segments_opened'] as int,
    segmentsExtended: json['segments_extended'] as int,
    segmentsClosed: json['segments_closed'] as int,
    hexesTouched: json['hexes_touched'] as int,
  );
}

/// Mirrors `backend/app/api/schemas/sos.py`'s `SosOut`. Status is one of
/// `active`, `acknowledged`, `resolved`, `cancelled` -- see
/// `backend/migrations/0006_sos.sql` for the full state diagram.
class SosAlert {
  final String id;
  final String sectorId;
  final String deviceId;
  final String userId;
  final String status;
  final double? lat;
  final double? lng;
  final DateTime triggeredAt;
  final DateTime? acknowledgedAt;
  final String? acknowledgedBy;
  final DateTime? resolvedAt;
  final String? resolvedBy;
  final DateTime? cancelledAt;
  final DateTime updatedAt;

  const SosAlert({
    required this.id,
    required this.sectorId,
    required this.deviceId,
    required this.userId,
    required this.status,
    required this.lat,
    required this.lng,
    required this.triggeredAt,
    required this.acknowledgedAt,
    required this.acknowledgedBy,
    required this.resolvedAt,
    required this.resolvedBy,
    required this.cancelledAt,
    required this.updatedAt,
  });

  bool get isOpen => status == 'active' || status == 'acknowledged';

  factory SosAlert.fromJson(Map<String, dynamic> json) => SosAlert(
    id: json['id'] as String,
    sectorId: json['sector_id'] as String,
    deviceId: json['device_id'] as String,
    userId: json['user_id'] as String,
    status: json['status'] as String,
    lat: (json['lat'] as num?)?.toDouble(),
    lng: (json['lng'] as num?)?.toDouble(),
    triggeredAt: DateTime.parse(json['triggered_at'] as String),
    acknowledgedAt: json['acknowledged_at'] == null
        ? null
        : DateTime.parse(json['acknowledged_at'] as String),
    acknowledgedBy: json['acknowledged_by'] as String?,
    resolvedAt: json['resolved_at'] == null
        ? null
        : DateTime.parse(json['resolved_at'] as String),
    resolvedBy: json['resolved_by'] as String?,
    cancelledAt: json['cancelled_at'] == null
        ? null
        : DateTime.parse(json['cancelled_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}

/// Mirrors `backend/app/api/schemas/reports.py`'s `ReportIngestResponse` --
/// same counts-only shape as [IngestResult], for the same reason: every
/// bucket is a terminal, deterministic outcome for that exact packet.
class ReportIngestResult {
  final int accepted;
  final int duplicate;
  final int decryptFailed;
  final int signatureInvalid;
  final int wrongDevice;
  final int malformed;

  const ReportIngestResult({
    required this.accepted,
    required this.duplicate,
    required this.decryptFailed,
    required this.signatureInvalid,
    required this.wrongDevice,
    required this.malformed,
  });

  factory ReportIngestResult.fromJson(Map<String, dynamic> json) =>
      ReportIngestResult(
        accepted: json['accepted'] as int,
        duplicate: json['duplicate'] as int,
        decryptFailed: json['decrypt_failed'] as int,
        signatureInvalid: json['signature_invalid'] as int,
        wrongDevice: json['wrong_device'] as int,
        malformed: json['malformed'] as int,
      );
}

/// Mirrors `backend/app/api/schemas/reports.py`'s `ReportOut`.
class Report {
  final String id;
  final String sectorId;
  final String deviceId;
  final String userId;
  final String kind;
  final double lat;
  final double lng;
  final String? note;
  final DateTime recordedAt;
  final DateTime receivedAt;
  final String deliveryPath;
  final String status;
  final String? acknowledgedBy;
  final DateTime? acknowledgedAt;
  final DateTime updatedAt;

  const Report({
    required this.id,
    required this.sectorId,
    required this.deviceId,
    required this.userId,
    required this.kind,
    required this.lat,
    required this.lng,
    required this.note,
    required this.recordedAt,
    required this.receivedAt,
    required this.deliveryPath,
    required this.status,
    required this.acknowledgedBy,
    required this.acknowledgedAt,
    required this.updatedAt,
  });

  factory Report.fromJson(Map<String, dynamic> json) => Report(
    id: json['id'] as String,
    sectorId: json['sector_id'] as String,
    deviceId: json['device_id'] as String,
    userId: json['user_id'] as String,
    kind: json['kind'] as String,
    lat: (json['lat'] as num).toDouble(),
    lng: (json['lng'] as num).toDouble(),
    note: json['note'] as String?,
    recordedAt: DateTime.parse(json['recorded_at'] as String),
    receivedAt: DateTime.parse(json['received_at'] as String),
    deliveryPath: json['delivery_path'] as String,
    status: json['status'] as String,
    acknowledgedBy: json['acknowledged_by'] as String?,
    acknowledgedAt: json['acknowledged_at'] == null
        ? null
        : DateTime.parse(json['acknowledged_at'] as String),
    updatedAt: DateTime.parse(json['updated_at'] as String),
  );
}
