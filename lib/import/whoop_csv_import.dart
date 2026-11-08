// whoop_csv_import.dart — PARSE WHOOP "MY DATA" EXPORT (ZIP OF CSVs)
//
// WHOOP exports a ZIP of CSVs. This parser handles the schema as of
// WHOOP v4.0 firmware, with graceful degradation for missing columns.
//
// Expected CSVs (some optional):
//   - heart_rate.csv: time, bpm
//   - hrv.csv: time, rmssd
//   - sleep.csv: sleep_id, start, end, stages (light/deep/rem/wake), duration, efficiency
//   - workouts.csv: workout_id, sport, start, end, avg_hr, max_hr, calories
//   - cycles.csv: cycle_id, start, end, avg_hr, strain
//   - recovery.csv: date, recovery_score, rhr, hrv, sleep_performance
//
// Output: a stream of day-bundles compatible with `deriveDayBundle`'s input format.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../compute/onehz_pipeline.dart';
import '../data/day_label.dart';

/// Parse a WHOOP export ZIP and yield per-day input bundles for `deriveDayBundle`.
Stream<Map<String, dynamic>> parseWhoopExport({
  required String zipPath,
  required LocalDb db,
}) async* {
  final bytes = await File(zipPath).readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);

  // Extract CSV files
  final heartRateCsv = _findCsv(archive, 'heart_rate');
  final hrvCsv = _findCsv(archive, 'hrv');
  final sleepCsv = _findCsv(archive, 'sleep');
  final workoutsCsv = _findCsv(archive, 'workouts');
  final cyclesCsv = _findCsv(archive, 'cycles');
  final recoveryCsv = _findCsv(archive, 'recovery');

  // Build per-day data structures
  final dayHr = <String, List<int>>{};
  final dayHrTs = <String, List<int>>{};
  final dayHrv = <String, List<double>>{};
  final daySleep = <String, Map<String, dynamic>>{};
  final dayWorkouts = <String, List<Map<String, dynamic>>>{};
  final dayRecovery = <String, Map<String, dynamic>>{};

  // Parse each CSV
  if (heartRateCsv != null) _parseHeartRate(heartRateCsv, dayHr, dayHrTs);
  if (hrvCsv != null) _parseHrv(hrvCsv, dayHrv);
  if (sleepCsv != null) _parseSleep(sleepCsv, daySleep);
  if (workoutsCsv != null) _parseWorkouts(workoutsCsv, dayWorkouts);
  if (recoveryCsv != null) _parseRecovery(recoveryCsv, dayRecovery);

  // Combine into day bundles
  final allDates = <String>{};
  allDates.addAll(dayHr.keys);
  allDates.addAll(dayHrv.keys);
  allDates.addAll(daySleep.keys);
  allDates.addAll(dayWorkouts.keys);
  allDates.addAll(dayRecovery.keys);

  final sortedDates = allDates.toList()..sort();

  for (final date in sortedDates) {
    yield _buildDayBundle(
      date: date,
      hr: dayHr[date] ?? [],
      hrTs: dayHrTs[date] ?? [],
      hrv: dayHrv[date] ?? [],
      sleep: daySleep[date],
      workouts: dayWorkouts[date] ?? [],
      recovery: dayRecovery[date],
    );
  }
}

ArchiveFile? _findCsv(Archive archive, String name) {
  return archive.files.firstWhere(
    (f) => f.name.toLowerCase().contains(name.toLowerCase()) &&
        f.name.toLowerCase().endsWith('.csv'),
    orElse: () => null,
  );
}

void _parseHeartRate(ArchiveFile csv, Map<String, List<int>> dayHr,
    Map<String, List<int>> dayHrTs) {
  final content = utf8.decode(csv.content as List<int>);
  final lines = LineSplitter.split(content).toList();
  if (lines.isEmpty) return;
  final header = lines[0].split(',');
  final timeIdx = header.indexOf('time');
  final bpmIdx = header.indexOf('bpm');
  if (timeIdx < 0 || bpmIdx < 0) return;

  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].split(',');
    if (cols.length <= timeIdx || cols.length <= bpmIdx) continue;
    final time = cols[timeIdx];
    final bpm = int.tryParse(cols[bpmIdx]) ?? 0;
    if (bpm <= 0) continue;
    final dt = DateTime.tryParse(time);
    if (dt == null) continue;
    final dayId = dayLabelOf(dt);
    dayHr.putIfAbsent(date, () => []).add(bpm);
    dayHrTs.putIfAbsent(date, () => []).add(dt.millisecondsSinceEpoch ~/ 1000);
  }
}

void _parseHrv(ArchiveFile csv, Map<String, List<double>> dayHrv) {
  final content = utf8.decode(csv.content as List<int>);
  final lines = LineSplitter.split(content).toList();
  if (lines.isEmpty) return;
  final header = lines[0].split(',');
  final timeIdx = header.indexOf('time');
  final rmssdIdx = header.indexOf('rmssd');
  if (timeIdx < 0 || rmssdIdx < 0) return;

  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].split(',');
    if (cols.length <= timeIdx || cols.length <= rmssdIdx) continue;
    final time = cols[timeIdx];
    final rmssd = double.tryParse(cols[rmssdIdx]);
    if (rmssd == null) continue;
    final dt = DateTime.tryParse(time);
    if (dt == null) continue;
    final dayId = dayLabelOf(dt);
    dayHrv.putIfAbsent(dayId, () => []).add(rmssd);
  }
}

void _parseSleep(ArchiveFile csv, Map<String, Map<String, dynamic>> daySleep) {
  final content = utf8.decode(csv.content as List<int>);
  final lines = LineSplitter.split(content).toList();
  if (lines.isEmpty) return;
  final header = lines[0].split(',');
  final sleepIdIdx = header.indexOf('sleep_id');
  final startIdx = header.indexOf('start');
  final endIdx = header.indexOf('end');
  final stagesIdx = header.indexOf('stages');
  final durationIdx = header.indexOf('duration');
  final efficiencyIdx = header.indexOf('efficiency');
  if (startIdx < 0 || endIdx < 0) return;

  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].split(',');
    if (cols.length <= startIdx || cols.length <= endIdx) continue;
    final start = DateTime.tryParse(cols[startIdx]);
    final end = DateTime.tryParse(cols[endIdx]);
    if (start == null || end == null) continue;
    final dayId = dayLabelOf(start);
    daySleep[dayId] = {
      'sleep_id': cols.length > sleepIdIdx ? cols[sleepIdIdx] : null,
      'onset_sec': start.millisecondsSinceEpoch ~/ 1000,
      'offset_sec': end.millisecondsSinceEpoch ~/ 1000,
      'tst_sec': (end.millisecondsSinceEpoch - start.millisecondsSinceEpoch) ~/ 1000,
      'stages': cols.length > stagesIdx ? cols[stagesIdx] : null,
      'efficiency_pct': cols.length > efficiencyIdx ? double.tryParse(cols[efficiencyIdx]) : null,
    };
  }
}

void _parseWorkouts(ArchiveFile csv, Map<String, List<Map<String, dynamic>>> dayWorkouts) {
  final content = utf8.decode(csv.content as List<int>);
  final lines = LineSplitter.split(content).toList();
  if (lines.isEmpty) return;
  final header = lines[0].split(',');
  final workoutIdIdx = header.indexOf('workout_id');
  final sportIdx = header.indexOf('sport');
  final startIdx = header.indexOf('start');
  final endIdx = header.indexOf('end');
  final avgHrIdx = header.indexOf('avg_hr');
  final maxHrIdx = header.indexOf('max_hr');
  final caloriesIdx = header.indexOf('calories');
  if (startIdx < 0 || endIdx < 0) return;

  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].split(',');
    if (cols.length <= startIdx || cols.length <= endIdx) continue;
    final start = DateTime.tryParse(cols[startIdx]);
    final end = DateTime.tryParse(cols[endIdx]);
    if (start == null || end == null) continue;
    final dayId = dayLabelOf(start);
    final workout = {
      'workout_id': cols.length > workoutIdIdx ? cols[workoutIdIdx] : null,
      'sport': cols.length > sportIdx ? cols[sportIdx] : null,
      'start_sec': start.millisecondsSinceEpoch ~/ 1000,
      'end_sec': end.millisecondsSinceEpoch ~/ 1000,
      'avg_hr': cols.length > avgHrIdx ? int.tryParse(cols[avgHrIdx]) : null,
      'max_hr': cols.length > maxHrIdx ? int.tryParse(cols[maxHrIdx]) : null,
      'calories': cols.length > caloriesIdx ? double.tryParse(cols[caloriesIdx]) : null,
    };
    dayWorkouts.putIfAbsent(dayId, () => []).add(workout);
  }
}

void _parseRecovery(ArchiveFile csv, Map<String, Map<String, dynamic>> dayRecovery) {
  final content = utf8.decode(csv.content as List<int>);
  final lines = LineSplitter.split(content).toList();
  if (lines.isEmpty) return;
  final header = lines[0].split(',');
  final dateIdx = header.indexOf('date');
  final scoreIdx = header.indexOf('recovery_score');
  final rhrIdx = header.indexOf('rhr');
  final hrvIdx = header.indexOf('hrv');
  final perfIdx = header.indexOf('sleep_performance');
  if (dateIdx < 0) return;

  for (var i = 1; i < lines.length; i++) {
    final cols = lines[i].split(',');
    if (cols.length <= dateIdx) continue;
    final dateStr = cols[dateIdx];
    if (!dateStr.contains('-')) continue; // must be YYYY-MM-DD
    dayRecovery[dateStr] = {
      'recovery_score': cols.length > scoreIdx ? int.tryParse(cols[scoreIdx]) : null,
      'rhr': cols.length > rhrIdx ? int.tryParse(cols[rhrIdx]) : null,
      'hrv': cols.length > hrvIdx ? double.tryParse(cols[hrvIdx]) : null,
      'sleep_performance': cols.length > perfIdx ? double.tryParse(cols[perfIdx]) : null,
    };
  }
}

Map<String, dynamic> _buildDayBundle({
  required String date,
  required List<int> hr,
  required List<int> hrTs,
  required List<double> hrv,
  Map<String, dynamic>? sleep,
  required List<Map<String, dynamic>> workouts,
  Map<String, dynamic>? recovery,
}) {
  return {
    'date': date,
    'day_ts': hrTs,
    'day_hr': hr,
    'sleep_ts': sleep != null
        ? List<int>.generate(sleep['tst_sec'] as int? ?? 0, (i) => (sleep['onset_sec'] as int) + i)
        : [],
    'sleep_hr': [], // would need interpolation from hr
    'sleep_rr_ts_ms': [],
    'sleep_rr_ms': [],
    'sleep_skin_temp': [],
    'sleep_json': sleep != null ? {
      'window': {},
      'tst_sec': sleep['tst_sec'],
      'onset_sec': sleep['onset_sec'],
      'offset_sec': sleep['offset_sec'],
      'efficiency_pct': sleep['efficiency_pct'],
      'confidence': 0.9,
    } : {},
    'hypno_stages': List<String>.filled(sleep != null ? (sleep['tst_sec'] as int? ?? 0) : 0, 'nrem'),
    'sleep_onset_sec': sleep != null ? (sleep['onset_sec'] as int) : 0,
    'sleep_offset_sec': sleep != null ? (sleep['offset_sec'] as int) : 0,
    'profile': {},
    'ln_rmssd_history': [],
    'rhr_history': [],
    'resp_history': [],
    'rmssd_history': [],
    'skin_temp_adc_history': [],
    'quiet_hrr_history': [],
    'prev_sleep_need_min': recovery != null ? (recovery['sleep_performance'] != null ? recovery['sleep_performance'] * 8 * 60 : null) : null,
    'prev_sleep_consistency': null,
    'sleep_perf_history': [],
    'observed_hr_ceiling_bpm': null,
    'day_confidence': 0.9,
    'day_flags': [],
    'device_family': 'gen4',
    'sleep_source': 'import',
    'step_spans': [],
  };
}