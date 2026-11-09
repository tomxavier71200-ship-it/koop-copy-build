// onehz_pipeline_optimization_test.dart — Unit tests for the 4 compute optimizations.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/compute/onehz_pipeline.dart';

void main() {
  group('Optimization A: Mean/StdDev Caching + Welford (via deriveDayBundle)', () {
    test('deriveDayBundle produces consistent results for same input', () {
      final input = _createTestInput();

      final result1 = deriveDayBundle(input.toJson());
      final result2 = deriveDayBundle(input.toJson());

      expect(result1['date'], equals(result2['date']));
      expect(result1['clinical'], equals(result2['clinical']));
      expect(result1['sleep'], equals(result2['sleep']));
      expect(result1['scalars'], equals(result2['scalars']));
    });

    test('deriveDayBundle produces valid clinical metrics', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());

      final clinical = result['clinical'] as Map<String, dynamic>;
      expect(clinical['hrv_time'], isNotNull);
      expect(clinical['hrv_freq'], isNotNull);
      expect(clinical['resting_hr'], isNotNull);
      expect(clinical['hr_dip'], isNotNull);
      expect(clinical['rmssd_sleep_session'], isNotNull);
      expect(clinical['rmssd_nocturnal'], isNotNull);
      expect(clinical['readiness_composite'], isNotNull);
      expect(clinical['strain'], isNotNull);
    });

    test('deriveDayBundle produces valid sleep metrics', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      expect(sleep['window'], isNotNull);
      expect(sleep['accounting'], isNotNull);
      expect(sleep['stager'], isNotNull);
      expect(sleep['cycles'], isNotNull);
      expect(sleep['cycle_count'], isNotNull);
    });

    test('deriveDayBundle produces valid scalars', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());

      final scalars = result['scalars'] as Map<String, dynamic>;
      expect(scalars.containsKey('rhr'), isTrue);
      expect(scalars.containsKey('rmssd'), isTrue);
      expect(scalars.containsKey('readiness'), isTrue);
      expect(scalars.containsKey('strain'), isTrue);
      expect(scalars.containsKey('resp_rate'), isTrue);
      expect(scalars.containsKey('skin_temp_z'), isTrue);
    });
  });

  group('Optimization B: Share NN Cleaning Across HRV Metrics', () {
    test('All 6 HRV metrics present when sufficient data', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());
      final clinical = result['clinical'] as Map<String, dynamic>;
      final respiration = result['respiration'] as Map<String, dynamic>;
      final stress = result['stress'] as Map<String, dynamic>;

      // The 6 metrics that share NN cleaning:
      // 1. hrv_time (hrvTime)
      expect(clinical['hrv_time'], isNotNull);
      // 2. hrv_freq (hrvFreq)
      expect(clinical['hrv_freq'], isNotNull);
      // 3. rmssd_sleep_session (sleepSessionWindowedRmssd)
      expect(clinical['rmssd_sleep_session'], isNotNull);
      // 4. rmssd_nocturnal (nocturnalRmssd)
      expect(clinical['rmssd_nocturnal'], isNotNull);
      // 5. resting_hr (nocturnalRhr)
      expect(clinical['resting_hr'], isNotNull);
      // 6. cvhr_apnea (cvhrApneaScreen) - under respiration
      expect(respiration['cvhr_apnea'], isNotNull);

      // Baevsky stress is in stress block
      expect(stress['si'], isNotNull);
    });
  });

  group('Optimization C: Zero-Copy Isolate Transfer', () {
    test('DayBundleInput toJson produces typed lists', () {
      final input = _createTestInput();
      final json = input.toJson();

      // Verify typed lists are used
      expect(json['day_ts'], isA<Int32List>());
      expect(json['day_hr'], isA<Int32List>());
      expect(json['sleep_ts'], isA<Int32List>());
      expect(json['sleep_hr'], isA<Int32List>());
      expect(json['sleep_rr_ts_ms'], isA<Float64List>());
      expect(json['sleep_rr_ms'], isA<Float64List>());
      expect(json['sleep_skin_temp'], isA<Int32List>());
      expect(json['hypno_stages'], isA<Uint8List>());

      // Verify hypno encoding: nrem=1, rem=2
      final hypno = json['hypno_stages'] as Uint8List;
      expect(hypno[0], equals(1)); // nrem
      expect(hypno[14399], equals(1)); // last nrem
      expect(hypno[14400], equals(2)); // first rem
      expect(hypno[28799], equals(2)); // last rem
    });

    test('DayBundleInput fromJson handles typed lists', () {
      final input = _createTestInput();
      final json = input.toJson();
      final restored = DayBundleInput.fromJson(json);

      expect(restored.date, equals(input.date));
      expect(restored.dayTsSec, equals(input.dayTsSec));
      expect(restored.sleepHr, equals(input.sleepHr));
      expect(restored.hypnoStages, equals(input.hypnoStages));
    });

    test('deriveDayBundle works with zero-copy input', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());

      expect(result['date'], equals('2026-01-01'));
      expect(result['clinical'], isNotNull);
      expect(result['sleep'], isNotNull);
      expect(result['scalars'], isNotNull);
      expect(result['series'], isNotNull);
    });
  });

  group('Optimization D: Incremental Sleep Staging (via deriveDayBundle)', () {
    test('Sleep runs data present in sleep accounting', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      final accounting = sleep['accounting'] as Map<String, dynamic>?;

      expect(accounting, isNotNull);
      expect(accounting!['value'], isNotNull);
      final value = accounting['value'] as Map<String, dynamic>;
      expect(value.containsKey('awakenings'), isTrue);
      expect(value.containsKey('longest_sleep_sec'), isTrue);
      expect(value.containsKey('sol_sec'), isTrue);
    });

    test('sleepSource manual provides SOL in accounting', () {
      final input = _createTestInput(sleepSource: 'manual');
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      final accounting = sleep['accounting'] as Map<String, dynamic>?;
      final value = accounting!['value'] as Map<String, dynamic>;

      expect(value['sol_sec'], isNotNull);
      expect(value['sol_sec'], greaterThan(0));
    });

    test('sleepSource confirmed provides SOL in accounting', () {
      final input = _createTestInput(sleepSource: 'confirmed');
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      final accounting = sleep['accounting'] as Map<String, dynamic>?;
      final value = accounting!['value'] as Map<String, dynamic>;

      expect(value['sol_sec'], isNotNull);
      expect(value['sol_sec'], greaterThan(0));
    });

    test('sleepSource auto does not provide SOL in accounting', () {
      final input = _createTestInput(sleepSource: 'auto');
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      final accounting = sleep['accounting'] as Map<String, dynamic>?;
      final value = accounting!['value'] as Map<String, dynamic>;

      expect(value['sol_sec'], isNull);
    });

    test('sleepSource auto_fallback does not provide SOL in accounting', () {
      final input = _createTestInput(sleepSource: 'auto_fallback');
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      final accounting = sleep['accounting'] as Map<String, dynamic>?;
      final value = accounting!['value'] as Map<String, dynamic>;

      expect(value['sol_sec'], isNull);
    });

    test('Sleep runs data includes awakenings and longest_sleep_sec', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());

      final sleep = result['sleep'] as Map<String, dynamic>;
      final accounting = sleep['accounting'] as Map<String, dynamic>?;
      final value = accounting!['value'] as Map<String, dynamic>;

      expect(value['awakenings'], isA<int>());
      expect(value['longest_sleep_sec'], isA<int>());
      expect((value['awakenings'] as int), greaterThanOrEqualTo(0));
      expect((value['longest_sleep_sec'] as int), greaterThan(0));
    });
  });

  group('All 6 HRV metrics use shared NN cleaning (via deriveDayBundle)', () {
    test('All HRV-related clinical metrics present', () {
      final input = _createTestInput();
      final result = deriveDayBundle(input.toJson());
      final clinical = result['clinical'] as Map<String, dynamic>;
      final respiration = result['respiration'] as Map<String, dynamic>;
      final stress = result['stress'] as Map<String, dynamic>;

      // The 6 metrics that share NN cleaning:
      // 1. hrv_time (hrvTime)
      expect(clinical['hrv_time'], isNotNull);
      // 2. hrv_freq (hrvFreq)
      expect(clinical['hrv_freq'], isNotNull);
      // 3. rmssd_sleep_session (sleepSessionWindowedRmssd)
      expect(clinical['rmssd_sleep_session'], isNotNull);
      // 4. rmssd_nocturnal (nocturnalRmssd)
      expect(clinical['rmssd_nocturnal'], isNotNull);
      // 5. resting_hr (nocturnalRhr)
      expect(clinical['resting_hr'], isNotNull);
      // 6. cvhr_apnea (cvhrApneaScreen) - under respiration
      expect(respiration['cvhr_apnea'], isNotNull);

      // Baevsky stress is in stress block
      expect(stress['si'], isNotNull);
    });
  });
}

DayBundleInput _createTestInput({String sleepSource = 'auto'}) {
  return DayBundleInput(
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
    sleepSource: sleepSource,
  );
}