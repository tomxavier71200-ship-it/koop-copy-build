import 'dart:typed_data';

/// Advanced sleep staging using heuristic classification per 30-second epoch.
/// Stages: Wake(0), N1(1), N2(2), N3(3), REM(4).
/// Falls back to rule-based classification; in production a TFLite model would
/// replace this with learned accuracy >= 88% vs PSG.
class AdvancedSleepStager {
  /// Feature vector per epoch: [rmssd_ms, lf_hf_ratio, resp_rate, movement_variance,
  /// temp_delta_c, circadian_phase_0_1].
  static const int kFeatureDim = 6;

  /// Sleep stage indices
  static const int kWake = 0;
  static const int kN1 = 1;
  static const int kN2 = 2;
  static const int kN3 = 3;
  static const int kREM = 4;

  /// Stage names for display
  static const List<String> kStageNames = [
    'Wake',
    'N1',
    'N2',
    'N3',
    'REM',
  ];

  static const List<int> kStageColors = [
    0xFFFFFFFF, // Wake
    0xFF81C784, // N1
    0xFF4CAF50, // N2
    0xFF1B5E20, // N3
    0xFFF48FB1, // REM
  ];

  /// Classify a single 30-second epoch using physiological rules.
  static int classifyEpoch(Float64List features) {
    final rmssd = features[0];
    final lfHf = features[1];
    final respRate = features[2];
    final movement = features[3];
    final circadian = features[4];

    // High movement → Wake
    if (movement > 0.5) return kWake;

    // Low HRV + high LF/HF → Wake/N1
    if (rmssd < 15 && lfHf > 3.0) {
      return movement < 0.1 ? kN1 : kWake;
    }

    // Very low LF/HF + high RMSSD → N3
    if (lfHf < 0.5 && rmssd > 50 && respRate > 12 && respRate < 18) {
      return kN3;
    }

    // Moderate LF/HF + good RMSSD → N2
    if (lfHf < 2.0 && rmssd > 25 && respRate > 10 && respRate < 22) {
      return kN2;
    }

    // Low LF/HF + moderate RMSSD + irregular breathing → REM
    if (lfHf < 1.0 && rmssd > 20 && movement < 0.15) {
      return circadian > 0.5 ? kREM : kN2;
    }

    // Default to light sleep
    return kN1;
  }

  /// Enforce minimum bout durations to reduce fragmentation.
  /// Wake: 1 epoch(30s), N1: 1 epoch, N2: 4 epochs(2min),
  /// N3: 10 epochs(5min), REM: 10 epochs(5min).
  static List<int> enforceMinimumBouts(List<int> stages) {
    final result = List<int>.from(stages);
    final minDuration = <int, int>{
      kWake: 1,
      kN1: 1,
      kN2: 4,
      kN3: 10,
      kREM: 10,
    };

    int i = 0;
    while (i < result.length) {
      final stage = result[i];
      int j = i + 1;
      while (j < result.length && result[j] == stage) j++;
      final boutLength = j - i;
      final minLen = minDuration[stage] ?? 1;

      if (boutLength < minLen) {
        if (i > 0) {
          final prevStage = result[i - 1];
          for (int k = i; k < j; k++) result[k] = prevStage;
        } else if (j < result.length) {
          final nextStage = result[j];
          for (int k = i; k < j; k++) result[k] = nextStage;
        }
      }
      i = j;
    }
    return result;
  }

  /// Compute sleep metrics from staged epochs.
  static Map<String, dynamic> computeMetrics(List<int> stages,
      {int epochCount = 0}) {
    if (stages.isEmpty) return _emptyMetrics();

    final n = epochCount > 0 ? epochCount : stages.length;
    final totalMin = n * 0.5; // 30s epochs

    int wakeCount = 0, n1Count = 0, n2Count = 0, n3Count = 0, remCount = 0;
    for (final s in stages) {
      switch (s) {
        case kWake: wakeCount++; break;
        case kN1: n1Count++; break;
        case kN2: n2Count++; break;
        case kN3: n3Count++; break;
        case kREM: remCount++; break;
      }
    }

    final sleepMin = totalMin - wakeCount * 0.5;
    final efficiency = totalMin > 0 ? sleepMin / totalMin * 100 : 0;

    // Sleep onset latency (first non-wake epoch)
    int onsetIdx = stages.indexWhere((s) => s != kWake);
    final onsetLatencyMin = onsetIdx >= 0 ? onsetIdx * 0.5 : totalMin;

    // WASO - Wake after sleep onset
    int wasoCount = 0;
    if (onsetIdx >= 0) {
      for (int i = onsetIdx + 1; i < stages.length; i++) {
        if (stages[i] == kWake) wasoCount++;
      }
    }
    final wasoMin = wasoCount * 0.5;

    final deepMin = n3Count * 0.5;
    final remMin = remCount * 0.5;
    final lightMin = (n1Count + n2Count) * 0.5;

    return {
      'total_min': totalMin,
      'sleep_min': sleepMin,
      'efficiency_pct': totalMin > 0 ? efficiency : 0,
      'onset_latency_min': onsetLatencyMin,
      'waso_min': wasoMin,
      'deep_min': deepMin,
      'deep_pct': totalMin > 0 ? deepMin / sleepMin * 100 : 0,
      'rem_min': remMin,
      'rem_pct': totalMin > 0 ? remMin / sleepMin * 100 : 0,
      'light_min': lightMin,
      'light_pct': totalMin > 0 ? lightMin / sleepMin * 100 : 0,
      'wake_min': wakeCount * 0.5,
      'stage_counts': {
        'wake': wakeCount,
        'n1': n1Count,
        'n2': n2Count,
        'n3': n3Count,
        'rem': remCount,
      },
    };
  }

  static Map<String, dynamic> _emptyMetrics() {
    return {
      'total_min': 0.0,
      'sleep_min': 0.0,
      'efficiency_pct': 0.0,
      'onset_latency_min': 0.0,
      'waso_min': 0.0,
      'deep_min': 0.0,
      'deep_pct': 0.0,
      'rem_min': 0.0,
      'rem_pct': 0.0,
      'light_min': 0.0,
      'light_pct': 0.0,
      'wake_min': 0.0,
      'stage_counts': {
        'wake': 0, 'n1': 0, 'n2': 0, 'n3': 0, 'rem': 0,
      },
    };
  }

  /// Convert stages to human-readable string.
  static String stagesToString(List<int> stages) =>
      stages.map((s) => kStageNames[s]).join(' → ');
}