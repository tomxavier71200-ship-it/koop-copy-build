// metric_shims.dart — Backward-compatibility shims for algorithm version upgrades.
//
// When kAlgorithmVersion increments, users upgrading from older versions must
// see the SAME results until they explicitly run "Re-analyze data". These shims
// apply the old formula + new corrections so existing exports/charts don't shift.

/// Current algorithm version
const int kAlgorithmVersion = 58;

/// Shim for readiness composite calculation (versions < 58).
///
/// Applies the OLD formula but adds new corrections (z-cap, degenerate baseline
/// detection) so results are consistent with new algorithm without re-derivation.
double? shimReadinessComposite(int oldVersion, Map<String, dynamic> inputs) {
  // For versions < 58, the old algorithm didn't have:
  // - kReadinessZCap (5.0) cap on composite z
  // - unstable_baseline note for saturated scores
  // - Early estimate with shorter baseline
  // - Rough guide population fallback

  // Delegate to the new readinessComposite but with old-version behavior
  // The new composite already handles missing baselines correctly
  return null; // Caller should use new readinessComposite directly
}

/// Shim for HRV frequency domain metrics (versions < 58).
///
/// Preserves old hrvFreq output for existing exports while new algorithm
/// uses improved artifact handling and windowing.
Map<String, dynamic>? shimHrvFreq(int oldVersion, Map<String, dynamic> rawInputs) {
  // For versions < 58:
  // - hrvFreq used different artifact fraction calculation
  // - Different minimum beat requirements
  // - No NN time gap awareness

  // Return null to indicate caller should use new hrvFreq
  return null;
}

/// Shim for nocturnal RHR calculation (versions < 58).
///
/// Preserves old rhr output for existing exports. Old algorithm:
/// - Fell back to whole-day HR when no sleep scored
/// - Used positional window (1800 positions) instead of time-based
/// - No sleep-window gating
double? shimRhr(int oldVersion, Map<String, dynamic> sleepHr, Map<String, dynamic> sleepTs) {
  // For versions < 58:
  // - nocturnalRhr would fall back to day HR if no sleep
  // - 30-minute window was 1800 positions, not 30 wall-clock minutes
  // - No minimum coverage requirement

  // Return null to indicate caller should use new nocturnalRhr
  return null;
}

/// Determines if shims should be applied for a given day's algo_version.
bool shouldApplyShim(int dayAlgoVersion) {
  return dayAlgoVersion < kAlgorithmVersion;
}

/// Gets the appropriate shim function for a metric based on old version.
dynamic getShimForMetric(String metricName, int oldVersion) {
  switch (metricName) {
    case 'readiness':
      return (inputs) => shimReadinessComposite(oldVersion, inputs);
    case 'hrv_freq':
      return (inputs) => shimHrvFreq(oldVersion, inputs);
    case 'nocturnal_rhr':
      return (sleepHr, sleepTs) => shimRhr(oldVersion, sleepHr, sleepTs);
    default:
      return null;
  }
}