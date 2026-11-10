// Recovery ML — on-device TensorFlow Lite inference for recovery score prediction.
// Loads the bundled .tflite model and scaler, runs inference on the isolate thread.

import 'dart:async';
import 'dart:math';

import 'package:tflite_flutter/tflite_flutter.dart';

/// Input features for recovery prediction (must match training feature order).
class RecoveryFeatures {
  final double rhr;
  final double rmssd;
  final double lnrmssdMean7d;
  final double rhrMean7d;
  final double sleepPerfMean7d;
  final double sleepConsistencyMean7d;
  final double strainPrior;
  final double strainMean7d;
  final double stressMean7d;
  final double skinTempZMean7d;

  const RecoveryFeatures({
    required this.rhr,
    required this.rmssd,
    required this.lnrmssdMean7d,
    required this.rhrMean7d,
    required this.sleepPerfMean7d,
    required this.sleepConsistencyMean7d,
    required this.strainPrior,
    required this.strainMean7d,
    required this.stressMean7d,
    required this.skinTempZMean7d,
  });

  List<double> toList() => [
    rhr,
    rmssd,
    lnrmssdMean7d,
    rhrMean7d,
    sleepPerfMean7d,
    sleepConsistencyMean7d,
    strainPrior,
    strainMean7d,
    stressMean7d,
    skinTempZMean7d,
  ];

  static int get featureCount => 10;
}

/// Result of recovery prediction.
class RecoveryPrediction {
  final double score; // 0-100
  final double confidence; // 0-1
  final DateTime timestamp;

  const RecoveryPrediction({
    required this.score,
    required this.confidence,
    required this.timestamp,
  });

  /// Clamped score for display.
  int get displayScore => score.clamp(0, 100).round();

  /// Human-readable band.
  String get band {
    if (score >= 80) return 'Optimal';
    if (score >= 65) return 'Good';
    if (score >= 50) return 'Moderate';
    if (score >= 35) return 'Low';
    return 'Critical';
  }
}

/// On-device recovery score inference using TFLite.
class RecoveryMlService {
  RecoveryMlService._();
  static final RecoveryMlService instance = RecoveryMlService._();

  Interpreter? _interpreter;
  List<double>? _scalerMean;
  List<double>? _scalerScale;
  bool _initialized = false;
  final _initLock = Completer<void>();

  /// Initialize the TFLite interpreter and load scaler.
  Future<void> initialize() async {
    if (_initialized) return _initLock.future;
    if (_initLock.isCompleted) return _initLock.future;

    try {
      // Load TFLite model from assets
      _interpreter = await Interpreter.fromAsset('assets/ml/recovery_model.tflite');

      // Load scaler parameters (hardcoded from training)
      await _loadScalerFromTraining();

      _initialized = true;
      _initLock.complete();
    } catch (e) {
      _initLock.completeError(e);
    }

    return _initLock.future;
  }

  Future<void> _loadScalerFromTraining() async {
    // These values come from the StandardScaler fitted on training data.
    // After training, run: print(scaler.mean_, scaler.scale_) and paste here.
    // For now, using approximate values from the 109-day dataset.
    _scalerMean = [
      58.5,   // rhr
      58.0,   // rmssd
      4.05,   // lnrmssd_mean_7d
      58.2,   // rhr_mean_7d
      55.0,   // sleep_perf_mean_7d
      45.0,   // sleep_consistency_mean_7d
      2.5,    // strain_prior
      2.8,    // strain_mean_7d
      25.0,   // stress_mean_7d
      0.1,    // skin_temp_z_mean_7d
    ];

    _scalerScale = [
      5.5,    // rhr
      12.0,   // rmssd
      0.2,    // lnrmssd_mean_7d
      4.5,    // rhr_mean_7d
      15.0,   // sleep_perf_mean_7d
      18.0,   // sleep_consistency_mean_7d
      1.8,    // strain_prior
      1.5,    // strain_mean_7d
      10.0,   // stress_mean_7d
      0.8,    // skin_temp_z_mean_7d
    ];

    // debugPrint('[RecoveryML] Scaler loaded: ...');
  }

  /// Run inference on features, returns recovery score 0-100.
  Future<RecoveryPrediction> predict(RecoveryFeatures features) async {
    await initialize();

    if (_interpreter == null) {
      throw StateError('RecoveryML not initialized');
    }

    // Scale features
    final raw = features.toList();
    final scaled = <double>[];
    for (int i = 0; i < raw.length; i++) {
      scaled.add((raw[i] - _scalerMean![i]) / _scalerScale![i]);
    }

    // Prepare input tensor [1, 10]
    final input = [scaled];
    final output = List.filled(1, 0.0).reshape([1, 1]);

    // Run inference
    _interpreter!.run(input, output);

    final rawScore = output[0][0];
    final score = rawScore.clamp(0.0, 100.0);

    // Simple confidence based on how far from extremes
    final confidence = 1.0 - (score - 50).abs() / 50.0;

    return RecoveryPrediction(
      score: score,
      confidence: confidence.clamp(0.0, 1.0),
      timestamp: DateTime.now(),
    );
  }

  /// Quick prediction from pre-computed daily aggregates.
  Future<RecoveryPrediction?> predictFromAggregates({
    required double rhr,
    required double rmssd,
    required double sleepPerf,
    required double sleepConsistency,
    required double strainPrior,
    required double strainMean,
    required double stressMean,
    required double skinTempZ,
  }) async {
    // Compute lnRMSSD and 7-day means (simplified - in reality these come from rolling windows)
    final lnrmssd = rmssd > 0 ? log(rmssd) : 4.0;
    final rhrMean7d = rhr; // Placeholder - should be 7-day rolling
    final strainMean7d = strainMean;
    final stressMean7d = stressMean;
    final skinTempMean7d = skinTempZ;
    final sleepPerfMean7d = sleepPerf;
    final sleepConsistencyMean7d = sleepConsistency;

    return predict(RecoveryFeatures(
      rhr: rhr,
      rmssd: rmssd,
      lnrmssdMean7d: lnrmssd,
      rhrMean7d: rhrMean7d,
      sleepPerfMean7d: sleepPerfMean7d,
      sleepConsistencyMean7d: sleepConsistencyMean7d,
      strainPrior: strainPrior,
      strainMean7d: strainMean7d,
      stressMean7d: stressMean7d,
      skinTempZMean7d: skinTempMean7d,
    ));
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _initialized = false;
  }
}

/// Extension to reshape list for TFLite.
extension ReshapeList<T> on List<T> {
  List<List<T>> reshape(List<int> shape) {
    if (shape.length != 2) throw ArgumentError('Only 2D reshape supported');
    final rows = shape[0];
    final cols = shape[1];
    if (length != rows * cols) throw ArgumentError('Shape mismatch');
    return List.generate(rows, (r) => sublist(r * cols, (r + 1) * cols));
  }
}