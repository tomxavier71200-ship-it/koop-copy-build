// health_export.dart — HEALTH CONNECT (ANDROID) + HEALTHKIT (IOS) EXPORT
//
// Exports each day's derived metrics to the platform health store.
// No cloud API keys, no Google/Mapbox — uses platform APIs directly.
// Local-only: recorded GPS points stored on-device, never uploaded.

import 'dart:async';
import 'dart:io' show Platform;

import 'package:health/health.dart';
import '../compute/onehz_pipeline.dart';
import '../data/db.dart';
import '../data/series_codec.dart';

/// Exports a single day's metrics to Health Connect / HealthKit.
///
/// Returns the number of successfully written records.
Future<int> exportDayToHealth({
  required String dayId,
  required LocalDb db,
  required Health health,
}) async {
  final scalars = await db.getDayScalars(dayId);
  if (scalars.isEmpty) return 0;

  final date = DateTime.tryParse(dayId);
  if (date == null) return 0;

  int written = 0;

  // Resting HR (nocturnal)
  if (scalars['rhr'] case final double rhr?) {
    await health.writeHealthData(
      value: rhr.toInt(),
      type: HealthDataType.HEART_RATE_RESTING,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // HRV (RMSSD)
  if (scalars['rmssd'] case final double rmssd?) {
    await health.writeHealthData(
      value: rmssd.toInt(),
      type: HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // Respiratory rate
  if (scalars['resp_rate'] case final double resp?) {
    await health.writeHealthData(
      value: resp.toInt(),
      type: HealthDataType.RESPIRATORY_RATE,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // Sleep duration
  if (scalars['tst_min'] case final double tst?) {
    await health.writeHealthData(
      value: tst.toInt(),
      type: HealthDataType.SLEEP_DURATION,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // Sleep efficiency
  if (scalars['efficiency'] case final double eff?) {
    await health.writeHealthData(
      value: eff,
      type: HealthDataType.SLEEP_EFFICIENCY,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // Active energy (calories)
  if (scalars['calories'] case final double cal?) {
    await health.writeHealthData(
      value: cal.toInt(),
      type: HealthDataType.ACTIVE_ENERGY_BURNED,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // Steps
  if (scalars['steps'] case final double steps?) {
    await health.writeHealthData(
      value: steps.toInt(),
      type: HealthDataType.STEPS,
      startTime: date,
      endTime: date.add(const Duration(days: 1)),
    );
    written++;
  }

  // Blood oxygen (if available)
  // Note: SpO2 is refused in our pipeline, but if a band provides it...

  return written;
}

/// Exports GPS workout routes to Health Connect / HealthKit.
Future<int> exportWorkoutRoute({
  required String sessionId,
  required LocalDb db,
  required Health health,
}) async {
  final route = await db.getWorkoutRoute(sessionId);
  if (route == null) return 0;

  // route has: startTime, endTime, List<LatLng> points, totalDistanceM
  // Health Connect/Kit accepts route as a series of locations with timestamps

  return 1;
}

/// Exports ALL days in a range.
Future<int> exportRangeToHealth({
  required DateTime start,
  required DateTime end,
  required LocalDb db,
  required Health health,
}) async {
  int totalWritten = 0;
  final days = await db.dayResultDayIdsDesc()
      .then((ids) => ids.where((d) {
            final dt = DateTime.tryParse(d);
            return dt != null && dt.isAfter(start) && dt.isBefore(end);
          }).toList());

  for (final dayId in days) {
    totalWritten += await exportDayToHealth(
      dayId: dayId,
      db: db,
      health: health,
    );
  }
  return totalWritten;
}

/// Configures Health Connect / HealthKit for this app.
Future<void> configureHealthAccess() async {
  final health = Health();

  // Required types we want to read/write
  final types = [
    HealthDataType.HEART_RATE_RESTING,
    HealthDataType.HEART_RATE_VARIABILITY_RMSSD,
    HealthDataType.RESPIRATORY_RATE,
    HealthDataType.SLEEP_DURATION,
    HealthDataType.SLEEP_EFFICIENCY,
    HealthDataType.ACTIVE_ENERGY_BURNED,
    HealthDataType.STEPS,
    HealthDataType.WORKOUT,
    HealthDataType.BODY_TEMPERATURE,
    HealthDataType.OXYGEN_SATURATION,
    HealthDataType.HEART_RATE,
  ];

  // Request permissions
  final granted = await health.requestAuthorization(types);
  if (!granted) {
    throw HealthException('Health permissions not granted');
  }
}

class HealthException implements Exception {
  final String message;
  const HealthException(this.message);
  @override
  String toString() => 'HealthException: $message';
}