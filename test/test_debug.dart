import 'dart:typed_data';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../lib/compute/onehz_pipeline.dart';

void main() {
  final input = DayBundleInput(
    date: '2026-01-01',
    dayTsSec: List.generate(86400, (i) => i),
    dayHr: List.generate(86400, (i) => 60 + (i % 20)),
    dayActivityClass: List.generate(86400, (i) => i < 3600 ? 1 : 0),
    sleepTsSec: List.generate(28800, (i) => 3600 + i),
    sleepHr: List.generate(28800, (i) => 55 + (i % 10)),
    sleepRrTsMs: List.generate(28800, (i) => (1000.0 + i * 1000.0)),
    sleepRrMs: List.generate(28800, (i) => 1000.0 + (i % 50).toDouble()),
    sleepSkinTemp: List.generate(28800, (i) => 3200 + (i % 5)),
    sleepJson: {
      'tst_sec': 28800,
      'waso_sec': 300,
      'in_bed_sec': 32400,
      'efficiency_pct': 90.0,
      'nrem_sec': 14400,
      'light_sec': 10800,
      'deep_sec': 3600,
      'rem_sec': 7200,
      'wake_sec': 300,
      'confidence': 0.9,
      'window': {'start': 3600, 'end': 32400},
    },
    hypnoStages: List.generate(28800, (i) => i < 14400 ? 'nrem' : 'rem'),
    sleepOnsetSec: 3600,
    sleepOffsetSec: 32400,
    profile: {'age': 30, 'sex': 'male', 'weight_kg': 70.0, 'height_cm': 175.0},
    lnRmssdHistory: [4.5, 4.6, 4.4, 4.5, 4.7],
    rhrHistory: [55.0, 56.0, 54.0, 55.0, 54.0],
    respHistory: [14.0, 14.5, 13.5, 14.0, 14.2],
    rmssdHistory: [45.0, 46.0, 44.0, 45.0, 47.0],
    skinTempAdcHistory: [3200.0, 3201.0, 3202.0, 3203.0, 3201.0],
    quietHrrHistory: [2.0, 2.1, 1.9, 2.0, 2.2],
    sleepPerfHistory: [85.0, 87.0, 83.0, 86.0, 88.0],
    sleepSource: 'auto',
  );

  final json = input.toJson();
  print('Keys in json: ${json.keys.toList()}');
  print('day_ts type: ${json['day_ts'].runtimeType}');
  print('hypno_stages type: ${json['hypno_stages'].runtimeType}');
  print('hypno_stages length: ${(json['hypno_stages'] as Uint8List).length}');
  print('hypno_stages[0]: ${(json['hypno_stages'] as Uint8List)[0]}');
  print('hypno_stages[1]: ${(json['hypno_stages'] as Uint8List)[1]}');
  print('hypno_stages[2]: ${(json['hypno_stages'] as Uint8List)[2]}');
  
  final result = deriveDayBundle(json);
  print('Result keys: ${result.keys.toList()}');
  print('Clinical keys: ${(result['clinical'] as Map).keys.toList()}');
  print('Sleep keys: ${(result['sleep'] as Map).keys.toList()}');
  final sleep = result['sleep'] as Map;
  print('Sleep accounting: ${sleep['accounting']}');
}
