import 'dart:math' as math;

import 'auto_detect.dart';

/// A clock minute with enough usable heart rate, motion and step readings.
typedef CyclingMinute = ({
  int startSec,
  double bpm,
  int peak,
  int steps,
  double motion
});

/// Surface a possible easy ride when brisk gait stops, wrist motion continues
/// with few foot steps, HR rises, and gait resumes. These are review candidates
/// because optical HR and wrist motion cannot distinguish all forms of riding
/// from seated activity.
List<DetectedWorkout> suggestEasyCycling(
  List<CyclingMinute> observations, {
  required int restingBpm,
  required int maxBpm,
}) {
  const minutes = 10;
  final byTime = {for (final m in observations) m.startSec: m};
  final sorted = byTime.keys.toList()..sort();
  final reserve = math.max(0, maxBpm - restingBpm);
  final core = math.max(AutoWorkoutDetector.elevatedMarginBPM,
      (reserve * AutoWorkoutDetector.hrrFloorFraction).round());
  final boundary = math.max(AutoWorkoutDetector.boundaryMarginBpm,
      (reserve * AutoWorkoutDetector.boundaryHrrFraction).round());
  final floor = restingBpm + (core + boundary) ~/ 2;
  List<CyclingMinute> around(int start, int length) => [
        for (var i = 0; i < length; i++)
          if (byTime[start + i * 60] case final value?) value,
      ];
  double mean(List<CyclingMinute> w) =>
      w.fold<double>(0, (sum, m) => sum + m.bpm) / w.length;
  bool gait(CyclingMinute m) => m.steps >= 50;
  bool lowSteps(CyclingMinute m) => m.steps < 40;
  bool cyclingMotion(CyclingMinute m) => m.motion >= .025 && m.motion <= .25;

  final candidates = <DetectedWorkout>[];
  for (final start in sorted) {
    final end = start + minutes * 60;
    final window = around(start, minutes);
    if (window.length != minutes ||
        !lowSteps(window.first) ||
        !lowSteps(window.last) ||
        window.where(lowSteps).length < 9 ||
        window.where(cyclingMotion).length < 6 ||
        window.where((m) => m.bpm >= floor).length < 7) {
      continue;
    }
    if (mean(window) < floor) continue;
    final before = around(start - 3 * 60, 3);
    if (before.length < 2) continue;
    final preMean = mean(before);
    final rises = [
      for (var i = 0; i < 4; i++) (window[i].bpm + window[i + 1].bpm) / 2,
    ];
    if (rises
        .every((bpm) => bpm - preMean < AutoWorkoutDetector.onsetRiseBpm)) {
      continue;
    }
    var first = start, last = end;
    bool continued(CyclingMinute? minute) =>
        minute != null && !gait(minute) && minute.bpm >= floor;
    while (continued(byTime[first - 60]) &&
        last - first < AutoWorkoutDetector.maxWorkoutMin * 60) {
      first -= 60;
    }
    while (continued(byTime[last]) &&
        last - first < AutoWorkoutDetector.maxWorkoutMin * 60) {
      last += 60;
    }
    while (first < last && !lowSteps(byTime[first]!)) first += 60;
    while (last > first && !lowSteps(byTime[last - 60]!)) last -= 60;
    if (last - first < minutes * 60 ||
        !around(first - 5 * 60, 5).any(gait) ||
        !around(last, 5).any(gait)) {
      continue;
    }
    final ride = around(first, (last - first) ~/ 60);
    final candidate = DetectedWorkout(
      startSec: first,
      endSec: last,
      avgBpm: mean(ride).round(),
      peakBpm: ride.map((m) => m.peak).reduce(math.max),
      durationMin: (last - first) ~/ 60,
      sport: 'cycling',
    );
    if (candidates.isNotEmpty && candidates.last.endSec > first) {
      if (candidate.avgBpm > candidates.last.avgBpm) {
        candidates[candidates.length - 1] = candidate;
      }
    } else {
      candidates.add(candidate);
    }
  }
  return candidates;
}
