import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:tflite_flutter/tflite_flutter.dart';

/// Service for computing recovery scores using the TFLite model.
/// Loads the model from assets and provides a predict() method.
/// Falls back to a heuristic when the model is unavailable.
class RecoveryScoreService {
  RecoveryScoreService._();

  static RecoveryScoreService? _instance;
  static RecoveryScoreService get instance =>
      _instance ??= RecoveryScoreService._();

  Interpreter? _interpreter;
  Float32List? _inputBuffer;
  Float32List? _outputBuffer;
  bool _isInitialized = false;

  /// Scaler parameters (mean, std) for input normalization
  late List<double> _scalerMean;
  late List<double> _scalerScale;

  /// Initialize the TFLite interpreter and load scaler info.
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Load model from assets
      _interpreter = await Interpreter.fromAsset('assets/ml/recovery_model.tflite');

      // Allocate input/output buffers
      // Input: [1, 6], Output: [1, 1]
      _inputBuffer = Float32List(6);
      _outputBuffer = Float32List(1);

      // Load scaler info
      final scalerJson = await rootBundle.loadString('assets/ml/scaler_info.json');
      final scalerData = _parseScalerJson(scalerJson);
      _scalerMean = scalerData['mean']!;
      _scalerScale = scalerData['scale']!;

      _isInitialized = true;
    } catch (e) {
      // If model fails to load, we'll use fallback heuristic
      _isInitialized = false;
      print('RecoveryScoreService: Failed to initialize TFLite model: $e');
    }
  }

  Map<String, List<double>> _parseScalerJson(String jsonStr) {
    // Simple JSON parsing for our known structure
    final meanMatch = RegExp(r'"mean"\s*:\s*\[([^\]]+)\]').firstMatch(jsonStr);
    final scaleMatch = RegExp(r'"scale"\s*:\s*\[([^\]]+)\]').firstMatch(jsonStr);

    List<double> mean = [];
    List<double> scale = [];

    if (meanMatch != null) {
      mean = meanMatch.group(1)!.split(',').map((s) => double.parse(s.trim())).toList();
    }
    if (scaleMatch != null) {
      scale = scaleMatch.group(1)!.split(',').map((s) => double.parse(s.trim())).toList();
    }

    // Default fallback
    if (mean.isEmpty) mean = [0, 0, 0, 0, 0, 0];
    if (scale.isEmpty) scale = [1, 1, 1, 1, 1, 1];

    return {'mean': mean, 'scale': scale};
  }

  /// Predicts recovery score (0-100) from features.
  ///
  /// Features:
  /// - rmssd7dAvg: 7-day average RMSSD (ms)
  /// - rhr7dAvg: 7-day average RHR (bpm)
  /// - sleepEfficiency: Sleep efficiency (%)
  /// - hrvTrend: RMSSD trend slope (ms/day)
  /// - sleepConsistency: Sleep midpoint consistency (0-1)
  /// - isCharging: Whether device is charging (0 or 1)
  ///
  /// Returns: recovery score 0-100, or -1 if model not available
  double predict({
    required double rmssd7dAvg,
    required double rhr7dAvg,
    required double sleepEfficiency,
    required double hrvTrend,
    required double sleepConsistency,
    required int isCharging,
  }) {
    if (!_isInitialized || _interpreter == null || _inputBuffer == null || _outputBuffer == null) {
      return _fallbackHeuristic(
        rmssd7dAvg: rmssd7dAvg,
        rhr7dAvg: rhr7dAvg,
        sleepEfficiency: sleepEfficiency,
        hrvTrend: hrvTrend,
        sleepConsistency: sleepConsistency,
        isCharging: isCharging,
      );
    }

    // Normalize inputs
    final rawInputs = [
      rmssd7dAvg,
      rhr7dAvg,
      sleepEfficiency,
      hrvTrend,
      sleepConsistency,
      isCharging.toDouble(),
    ];

    for (int i = 0; i < 6; i++) {
      _inputBuffer![i] = (rawInputs[i] - _scalerMean[i]) / _scalerScale[i];
    }

    // Run inference
    _interpreter!.run(_inputBuffer!, _outputBuffer!);

    // Model outputs 0-1 (sigmoid), scale to 0-100
    final score = _outputBuffer![0] * 100.0;
    return score.clamp(0.0, 100.0);
  }

  /// Fallback heuristic when TFLite model is unavailable.
  double _fallbackHeuristic({
    required double rmssd7dAvg,
    required double rhr7dAvg,
    required double sleepEfficiency,
    required double hrvTrend,
    required double sleepConsistency,
    required int isCharging,
  }) {
    // Linear combination that approximates the target function
    double score = 20.0; // baseline

    score += 0.15 * rmssd7dAvg;      // +0.15 per ms RMSSD
    score -= 0.10 * rhr7dAvg;        // -0.10 per bpm RHR
    score += 15.0 * sleepEfficiency / 100.0; // +15% per efficiency
    score += 10.0 * hrvTrend;        // +10 per ms/day trend
    score += 20.0 * sleepConsistency; // +20 per consistency
    score += 5.0 * isCharging;       // +5 if charging

    return score.clamp(0.0, 100.0);
  }

  /// Computes 7-day rolling features from day_results.
  static Future<Map<String, double>> computeRollingFeatures({
    required String currentDate,
    required List<Map<String, dynamic>> last7Days,
  }) async {
    if (last7Days.isEmpty) {
      return {
        'rmssd_7d_avg': 0.0,
        'rhr_7d_avg': 0.0,
        'sleep_efficiency': 0.0,
        'hrv_trend': 0.0,
        'sleep_consistency': 0.0,
        'charging_flag': 0.0,
      };
    }

    // Filter last 7 days
    final recent = last7Days.take(7).toList();

    // Compute averages
    final rmssdVals = recent.where((d) => d['rmssd'] != null).map((d) => (d['rmssd'] as num).toDouble()).toList();
    final rhrVals = recent.where((d) => d['rhr'] != null).map((d) => (d['rhr'] as num).toDouble()).toList();
    final effVals = recent.where((d) => d['sleep_efficiency'] != null).map((d) => (d['sleep_efficiency'] as num).toDouble()).toList();

    final rmssdAvg = rmssdVals.isNotEmpty ? rmssdVals.reduce((a, b) => a + b) / rmssdVals.length : 0.0;
    final rhrAvg = rhrVals.isNotEmpty ? rhrVals.reduce((a, b) => a + b) / rhrVals.length : 0.0;
    final effAvg = effVals.isNotEmpty ? effVals.reduce((a, b) => a + b) / effVals.length : 0.0;

    // HRV trend (linear regression slope over last 7 days)
    double hrvTrend = 0.0;
    if (rmssdVals.length >= 3) {
      final n = rmssdVals.length;
      double sumX = 0, sumY = 0, sumXY = 0, sumX2 = 0;
      for (int i = 0; i < n; i++) {
        sumX += i;
        sumY += rmssdVals[i];
        sumXY += i * rmssdVals[i];
        sumX2 += i * i;
      }
      hrvTrend = (n * sumXY - sumX * sumY) / (n * sumX2 - sumX * sumX);
    }

    // Sleep consistency: inverse of sleep midpoint variance
    double sleepConsistency = 0.0;
    final midpoints = recent.where((d) => d['sleep_midpoint'] != null).map((d) => (d['sleep_midpoint'] as num).toDouble()).toList();
    if (midpoints.length >= 2) {
      final mean = midpoints.reduce((a, b) => a + b) / midpoints.length;
      double sumSq = 0;
      for (final m in midpoints) sumSq += (m - mean) * (m - mean);
      final variance = sumSq / midpoints.length;
      sleepConsistency = (1.0 / (1.0 + variance)).clamp(0.0, 1.0);
    }

    return <String, double>{
      'rmssd_7d_avg': rmssdAvg,
      'rhr_7d_avg': rhrAvg,
      'sleep_efficiency': effAvg,
      'hrv_trend': hrvTrend,
      'sleep_consistency': sleepConsistency,
      'charging_flag': 0.0, // TODO: get from battery_plus
    };
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
  }
}