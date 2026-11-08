// auto_detect.dart — opt-in "did you just work out?" SUGGESTION detector.
//
// Opt-in workout suggestion detector (ported from AutoWorkoutDetector.swift).
// DELIBERATELY conservative (low sensitivity): a sustained ≥10-min elevation of
// HR ≥ max(RHR+[elevatedMarginBPM], RHR+[hrrFloorFraction]·HRR) — RHR+59 at
// RHR 60 / HRmax 190 — brief (≤90 s) dips tolerated, near windows merged,
// optional motion confirmation, overlap-excluded against saved spans.
// (The header and the note used to quote "RHR+30", the margin this detector
// deliberately abandoned: see [hrrFloorFraction] for the 30 false windows on a
// sedentary week that motivated replacing it.)
//
// This NEVER writes a row — it only ever SUGGESTS.
//
// HYBRID SEAM: every surviving bout is run through a [SportClassifier]; the
// default returns "detected" (no sport typing). OpenStrap's motion-based HAR typer
// can be injected to type each bout when high-rate accel features exist.
//
// Pure / headless: no I/O, no clock, dart:math only. All ts/start/end are unix
// SECONDS. NOT medical advice.

import 'dart:math' as math;

import '../types.dart';
import 'sport.dart';

/// A candidate workout window the user can accept (Save) or reject (dismiss).
/// All fields derived purely from the HR samples inside the window.
class DetectedWorkout {
  final int startSec;
  final int endSec;
  final int avgBpm;
  final int peakBpm;

  /// Whole minutes, floor of (endSec - startSec) / 60.
  final int durationMin;

  /// Sport label from the [SportClassifier] ("detected" by default).
  final String sport;

  const DetectedWorkout({
    required this.startSec,
    required this.endSec,
    required this.avgBpm,
    required this.peakBpm,
    required this.durationMin,
    this.sport = defaultSportLabel,
  });

  Map<String, dynamic> toJson() => {
        'start_sec': startSec,
        'end_sec': endSec,
        'avg_bpm': avgBpm,
        'peak_bpm': peakBpm,
        'duration_min': durationMin,
        'sport': sport,
      };
}

/// A [startSec, endSec] span of an already-saved workout, used to exclude windows
/// that overlap a session the user has already logged.
class SavedWorkoutSpan {
  final int startSec;
  final int endSec;
  const SavedWorkoutSpan(this.startSec, this.endSec);
}

/// One motion-intensity reading aligned to the HR timeline (optional confirmation
/// signal). [intensity] is L2 gravity-delta vs the previous record.
class MotionPoint {
  final int ts;
  final double intensity;
  const MotionPoint(this.ts, this.intensity);
}

/// Opt-in suggestion detector.
class AutoWorkoutDetector {
  // ── Constants ─────────────────────────────────────────────────────────────

  /// Minimum elevated-gate margin (bpm above resting). A safety floor for the
  /// %HRR gate below when HRmax is low/unknown — the real threshold is [hrrFloor].
  static const int elevatedMarginBPM = 40;

  /// PRIMARY gate: a bout must sit at ≥ this fraction of heart-rate RESERVE
  /// (HRmax − RHR), not just a few bpm above rest. Calibrated on a full week of a
  /// sedentary user's data (zero real workouts): a fixed RHR+30 margin (≈90 bpm)
  /// flagged 30 windows; 0.45·HRR (~117 bpm at RHR 57 / HRmax 190) rejects
  /// ordinary daytime and even a 3 h steady-state evening elevation, leaving only
  /// short genuinely-cardio bouts (avg ≥ ~120 bpm) — which is exactly what a "did
  /// you work out?" prompt should ask about.
  static const double hrrFloorFraction = 0.45;

  /// Lower %HRR gate used only to place the boundaries around an already
  /// qualified high-intensity core. Detection still requires
  /// [hrrFloorFraction]; this recovers a contiguous warm-up/cool-down instead
  /// of reporting only the minutes that cleared the high detection gate.
  static const double boundaryHrrFraction = 0.30;

  /// Boundary floor above resting HR. This is never a detection threshold.
  static const int boundaryMarginBpm = 20;

  /// A boundary may expand at most this far on either side of the qualified
  /// core. This prevents an otherwise-active day from being absorbed into it.
  static const int maxBoundaryExtensionS = 10 * 60;

  /// HRmax fallback when the caller passes none (age-predicted is preferred).
  static const int defaultMaxHR = 190;

  /// A suggested WORKOUT is time-bounded. A sustained elevation longer than this
  /// (observed: ~3 h of steady 131 bpm from an active evening) is lifestyle
  /// activity, not a workout — don't suggest it. Endurance sessions beyond this
  /// are better logged manually than auto-prompted.
  static const int maxWorkoutMin = 120;

  /// A candidate must hold the gate for a contiguous span ≥ this (10 min).
  static const double minSustainedMin = 10.0;

  /// A dip below the gate no longer than this does NOT break the span.
  static const int maxDipS = 90;

  /// A GAP IN THE DATA longer than this breaks the span.
  ///
  /// A dip is "HR present and low"; a gap is "no HR at all", and only the dip
  /// used to be time-bounded — so an off-wrist stretch produced no samples, the
  /// loop never saw it, and the span simply resumed at the next elevated
  /// sample. Two 12-minute efforts 40 minutes apart came out as one 64-minute
  /// workout whose mean HR (a mean over present samples only) still read
  /// normal. Absence of data is not evidence of continuity.
  static const int maxGapS = 90;

  /// Two windows whose gap is strictly < this are merged (5 min).
  static const int mergeGapS = 5 * 60;

  /// When a motion series is supplied, the window's mean per-second motion
  /// intensity (L2 gravity-vector change/s, in g) must be ≥ this to qualify.
  /// 0.05 was far too low — desk fidgeting/typing/gesturing while seated averages
  /// above it, so an elevated resting HR alone got confirmed as a "workout". Real
  /// ambulatory exercise (walking/running/lifting) sustains well above 0.15.
  /// Ignored in HR-only mode.
  static const double motionConfirmMean = 0.15;

  /// Lookback immediately before a span's start, used to test for an
  /// exercise-like HR ONSET as a motion-gate bypass — see [onsetRiseBpm].
  static const int onsetLookbackS = 60;

  /// The onset check's "post" window: the first stretch of the span itself.
  static const int onsetWindowS = 60;

  /// Bypass the motion-confirmation gate when it fails BUT the HR shows a
  /// genuine exercise ONSET: mean bpm over [onsetWindowS] at the START of the
  /// span must rise by at least this many bpm versus mean bpm over
  /// [onsetLookbackS] immediately BEFORE it.
  ///
  /// Real aerobic effort produces a fast (~1-2 min time-constant) phase-II HR
  /// kinetic response right as exertion begins (Whipp & Wasserman 1972) —
  /// exactly what low-limb-swing cardio (cycling, rowing) shows even though
  /// the wrist stays still on a handlebar/oar and [motionConfirmMean] (tuned
  /// for arm-swing activities) never clears. A slow-drifting elevation —
  /// fever, heat, anxiety climbing over many minutes, or a plateau with no
  /// visible start because the data begins mid-elevation — shows no such rise
  /// and stays gated: this is what keeps the bypass from turning "every
  /// sustained heart-rate elevation" into a suggested activity. No usable
  /// pre-window (nothing in [onsetLookbackS], e.g. the day/recording starts
  /// mid-span) → the onset can't be evaluated → abstain, motion gate stays in
  /// force (never fabricate an onset that isn't there).
  static const double onsetRiseBpm = 12.0;

  /// Resting-HR fallback when the caller has no nightly RHR.
  static const int defaultRestingHR = 60;

  /// Per-second motion intensity = L2 magnitude of the gravity change vs the
  /// previous record. First row → 0. Empty input → [].
  /// [gravTs]/[gx]/[gy]/[gz] are parallel arrays for building the optional [motion] argument.
  /// [gravTs]/[gx]/[gy]/[gz] are parallel arrays (any order; sorted internally).
  static List<MotionPoint> motionPoints(
      List<int> gravTs, List<double> gx, List<double> gy, List<double> gz) {
    final n = gravTs.length;
    if (n == 0) return const [];
    final idx = List<int>.generate(n, (i) => i)
      ..sort((a, b) => gravTs[a].compareTo(gravTs[b]));
    final out = <MotionPoint>[];
    double? px, py, pz;
    for (var k = 0; k < n; k++) {
      final i = idx[k];
      final double intensity;
      if (k == 0 || px == null) {
        intensity = 0.0;
      } else {
        final dx = gx[i] - px;
        final dy = gy[i] - py!;
        final dz = gz[i] - pz!;
        intensity = math.sqrt(dx * dx + dy * dy + dz * dz);
      }
      out.add(MotionPoint(gravTs[i], intensity));
      px = gx[i];
      py = gy[i];
      pz = gz[i];
    }
    return out;
  }

  /// Detect candidate sustained-elevated-HR workout windows.
  ///
  /// [hrTs]/[hrBpm] the day's HR samples (parallel, any order; empty → []).
  /// [restingBpm] nightly resting HR for the day; null → [defaultRestingHR] (60).
  /// [motion] OPTIONAL continuous motion series for confirmation; null/empty →
  /// HR-only. [savedSpans] already-saved windows to exclude by overlap.
  /// [classify] the sport seam — runs on each surviving bout; default
  /// [defaultSportClassifier] returns "detected" (no sport typing).
  static List<DetectedWorkout> detect({
    required List<int> hrTs,
    required List<int> hrBpm,
    int? restingBpm,
    int? maxBpm,
    List<MotionPoint>? motion,
    List<SavedWorkoutSpan> savedSpans = const [],
    SportClassifier classify = defaultSportClassifier,
  }) {
    final n = hrTs.length;
    if (n == 0) return const [];
    final order = List<int>.generate(n, (i) => i)
      ..sort((a, b) => hrTs[a].compareTo(hrTs[b]));
    final ts = [for (final i in order) hrTs[i]];
    final bpm = [for (final i in order) hrBpm[i]];

    // %HRR floor (primary), never below the RHR+margin safety floor.
    final rhr = restingBpm ?? defaultRestingHR;
    final hrMax = maxBpm ?? defaultMaxHR;
    final hrrFloor = (rhr + hrrFloorFraction * (hrMax - rhr)).round();
    final floor = math.max(rhr + elevatedMarginBPM, hrrFloor);
    final boundaryHrrFloor =
        (rhr + boundaryHrrFraction * (hrMax - rhr)).round();
    final boundaryFloor = math.max(rhr + boundaryMarginBpm, boundaryHrrFloor);

    // --- 1+2+3: grow sustained spans tolerating brief dips ---
    final spans = <List<int>>[]; // [start, end]
    int? spanStart;
    var spanEnd = 0;
    int? dipStart;

    void closeSpan() {
      if (spanStart != null) spans.add([spanStart!, spanEnd]);
      spanStart = null;
      dipStart = null;
    }

    for (var k = 0; k < n; k++) {
      // Break on a hole in the record before anything else — see [maxGapS].
      if (k > 0 && spanStart != null && ts[k] - ts[k - 1] > maxGapS)
        closeSpan();
      if (bpm[k] >= floor) {
        spanStart ??= ts[k];
        spanEnd = ts[k];
        dipStart = null; // the dip (if any) is bridged
      } else if (spanStart != null) {
        dipStart ??= ts[k];
        if (ts[k] - dipStart! > maxDipS) closeSpan();
      }
    }
    closeSpan();

    if (spans.isEmpty) return const [];

    // --- 4: merge spans whose gap is strictly < mergeGapS ---
    final merged = <List<int>>[];
    var curStart = spans[0][0];
    var curEnd = spans[0][1];
    for (var k = 1; k < spans.length; k++) {
      final next = spans[k];
      if (next[0] - curEnd < mergeGapS) {
        curEnd = math.max(curEnd, next[1]);
      } else {
        merged.add([curStart, curEnd]);
        curStart = next[0];
        curEnd = next[1];
      }
    }
    merged.add([curStart, curEnd]);

    // --- 5+6+7 ---
    final motionSeries = (motion == null || motion.isEmpty) ? null : motion;
    final results = <DetectedWorkout>[];
    for (final span in merged) {
      final coreStart = span[0], coreEnd = span[1];

      // Apply the minimum to the merged elevated window, not each fragment.
      // Otherwise a real short workout with a two-minute HR dip becomes two
      // discarded sub-threshold fragments even though its full elevated
      // window and mean HR meet the same conservative gates below.
      if ((coreEnd - coreStart).toDouble() < minSustainedMin * 60.0) continue;

      // A workout is time-bounded — a multi-hour sustained elevation is lifestyle
      // activity, not a workout to suggest.
      if ((coreEnd - coreStart) > maxWorkoutMin * 60) continue;

      // Core HR samples. The high gate qualifies the bout; a lower gate is
      // allowed to place its edges only after every qualification check passes.
      final coreBpm = <int>[];
      for (var k = 0; k < n; k++) {
        if (ts[k] >= coreStart && ts[k] <= coreEnd) coreBpm.add(bpm[k]);
      }
      if (coreBpm.isEmpty) continue;

      // The WHOLE window must be genuinely elevated, not just brief floor
      // crossings that dip-bridging stitched together — require the mean HR to
      // clear the floor too. (A sedentary afternoon oscillating around the gate
      // averaged below it; a real bout averages well above.)
      final coreMean = coreBpm.reduce((a, b) => a + b) / coreBpm.length;
      if (coreMean < floor) continue;

      // 5: motion confirmation when a continuous motion series was supplied.
      double? meanMotion;
      if (motionSeries != null) {
        var sum = 0.0;
        var cnt = 0;
        for (final p in motionSeries) {
          if (p.ts >= coreStart && p.ts <= coreEnd) {
            sum += p.intensity;
            cnt++;
          }
        }
        meanMotion = cnt == 0 ? 0.0 : sum / cnt;
        if (meanMotion < motionConfirmMean) {
          // Low-motion but a genuine exercise-like onset — see [onsetRiseBpm].
          final preMean =
              _meanBpmInRange(ts, bpm, coreStart - onsetLookbackS, coreStart);
          final earlyMean = _meanBpmInRange(ts, bpm, coreStart,
              math.min(coreEnd + 1, coreStart + onsetWindowS));
          if (preMean == null ||
              earlyMean == null ||
              (earlyMean - preMean) < onsetRiseBpm) {
            continue;
          }
        }
      }

      final bounds = _refineBoundaries(
        ts,
        bpm,
        coreStart,
        coreEnd,
        boundaryFloor,
      );
      final start = bounds.$1, end = bounds.$2;
      if ((end - start) > maxWorkoutMin * 60) continue;

      // Never re-suggest a window overlapping a saved workout. Compare the
      // final window, not only its high-HR core: a saved warm-up is still the
      // same workout.
      if (savedSpans.any((s) => _overlaps(start, end, s.startSec, s.endSec))) {
        continue;
      }

      final winBpm = <int>[];
      for (var k = 0; k < n; k++) {
        if (ts[k] >= start && ts[k] <= end) winBpm.add(bpm[k]);
      }
      if (winBpm.isEmpty) continue;

      var sum = 0;
      var peak = winBpm.first;
      for (final v in winBpm) {
        sum += v;
        if (v > peak) peak = v;
      }
      final avg = (sum / winBpm.length).round();
      final durMin = (end - start) ~/ 60;

      // HYBRID SEAM: type the bout. Default classifier returns "detected".
      final bout = WorkoutBout(
        startSec: start,
        endSec: end,
        avgBpm: avg.toDouble(),
        peakBpm: peak.toDouble(),
        durationS: (end - start).toDouble(),
      );
      final feats =
          meanMotion == null ? null : MotionFeatures(meanIntensity: meanMotion);
      final sport = classify(bout, feats);

      results.add(DetectedWorkout(
        startSec: start,
        endSec: end,
        avgBpm: avg,
        peakBpm: peak,
        durationMin: durMin,
        sport: sport,
      ));
    }
    return results;
  }

  /// Expand an already-qualified core through contiguous lower-intensity
  /// warm-up/cool-down HR. Real timestamp gaps and sustained recovery stop the
  /// expansion; short dips use the same tolerance as core detection.
  static (int, int) _refineBoundaries(
    List<int> ts,
    List<int> bpm,
    int coreStart,
    int coreEnd,
    int boundaryFloor,
  ) {
    final first = _lowerBound(ts, coreStart);
    final afterLast = _upperBound(ts, coreEnd);
    if (first >= ts.length || afterLast <= 0) return (coreStart, coreEnd);

    var start = coreStart;
    int? lowEnd;
    for (var k = first - 1; k >= 0; k--) {
      if (coreStart - ts[k] > maxBoundaryExtensionS) break;
      if (ts[k + 1] - ts[k] > maxGapS) break;
      if (bpm[k] >= boundaryFloor) {
        start = ts[k];
        lowEnd = null;
      } else {
        lowEnd ??= ts[k + 1];
        if (lowEnd - ts[k] > maxDipS) break;
      }
    }

    var end = coreEnd;
    int? lowStart;
    for (var k = afterLast; k < ts.length; k++) {
      if (ts[k] - coreEnd > maxBoundaryExtensionS) break;
      if (ts[k] - ts[k - 1] > maxGapS) break;
      if (bpm[k] >= boundaryFloor) {
        end = ts[k];
        lowStart = null;
      } else {
        lowStart ??= ts[k - 1];
        if (ts[k] - lowStart > maxDipS) break;
      }
    }
    return (start, end);
  }

  static int _lowerBound(List<int> xs, int value) {
    var lo = 0, hi = xs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (xs[mid] < value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  static int _upperBound(List<int> xs, int value) {
    var lo = 0, hi = xs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (xs[mid] <= value) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Closed-interval overlap (touching endpoints count).
  static bool _overlaps(int aStart, int aEnd, int bStart, int bEnd) =>
      aStart <= bEnd && bStart <= aEnd;

  /// Mean bpm for samples with `lo <= ts < hi`. Null when nothing falls in
  /// range (can't evaluate — caller must abstain, not substitute a default).
  static double? _meanBpmInRange(List<int> ts, List<int> bpm, int lo, int hi) {
    var sum = 0, cnt = 0;
    for (var k = 0; k < ts.length; k++) {
      if (ts[k] >= lo && ts[k] < hi) {
        sum += bpm[k];
        cnt++;
      }
    }
    return cnt == 0 ? null : sum / cnt;
  }
}

/// Wrap a list of [DetectedWorkout] in the honesty envelope. Always present
/// (an empty list is a valid, honest "no suggested workouts" answer).
Metric<List<DetectedWorkout>> autoDetectWorkouts({
  required List<int> hrTs,
  required List<int> hrBpm,
  int? restingBpm,
  int? maxBpm,
  List<MotionPoint>? motion,
  List<SavedWorkoutSpan> savedSpans = const [],
  SportClassifier classify = defaultSportClassifier,
}) {
  final list = AutoWorkoutDetector.detect(
    hrTs: hrTs,
    hrBpm: hrBpm,
    restingBpm: restingBpm,
    maxBpm: maxBpm,
    motion: motion,
    savedSpans: savedSpans,
    classify: classify,
  );
  return Metric<List<DetectedWorkout>>(
    value: list,
    confidence: list.isEmpty ? 0.0 : 0.6,
    tier: Tier.estimate,
    inputs_used: const ['hr_1hz', 'resting_hr', 'motion_1hz'],
    note: 'opt-in workout suggestion (HR ≥ max(RHR+'
        '${AutoWorkoutDetector.elevatedMarginBPM}, RHR+'
        '${AutoWorkoutDetector.hrrFloorFraction}·HRR) sustained ≥10 min); '
        'wrist-HR ESTIMATE, not medical advice',
  );
}
