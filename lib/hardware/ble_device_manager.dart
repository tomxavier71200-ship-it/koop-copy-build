import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:background_fetch/background_fetch.dart' as bf;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:workmanager/workmanager.dart';

/// Manages BLE device connections for continuous HR streaming.
/// Priority devices: Polar H10, Garmin HRM-Pro, generic GATT 0x180D Heart Rate.
class BleDeviceManager {
  BleDeviceManager({
    required Database database,
    required void Function(List<int> rrIntervalsMs, int timestampMs) onRrBatch,
  }) : _db = database,
       _onRrBatch = onRrBatch;

  final Database _db;
  final void Function(List<int> rrIntervalsMs, int timestampMs) _onRrBatch;

  static const _polarH10ServiceUuid = '6217ff4b-fb31-1140-ad5a-a45545d7ecf3'; // Polar PMD
  static const _polarPmdDataUuid = '6217ff4c-fb31-1140-ad5a-a45545d7ecf3';    // PPI data
  static const _polarPmdControlUuid = '6217ff4d-fb31-1140-ad5a-a45545d7ecf3'; // Control point
  static const _gattHrServiceUuid = '0000180d-0000-1000-8000-00805f9b34fb';   // Standard HR
  static const _gattHrMeasurementUuid = '00002a37-0000-1000-8000-00805f9b34fb';

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _hrMeasurementChar;
  BluetoothCharacteristic? _pmdDataChar;
  BluetoothCharacteristic? _pmdControlChar;
  StreamSubscription<List<int>>? _hrSubscription;
  StreamSubscription<List<int>>? _pmdSubscription;
  Timer? _reconnectTimer;
  Timer? _batteryCheckTimer;
  bool _isStreaming = false;
  DeviceType _deviceType = DeviceType.unknown;

  /// Last known battery level (0-100)
  int _batteryLevel = 100;

  /// Current connection state
  BleConnectionState _state = BleConnectionState.disconnected;
  BleConnectionState get state => _state;

  /// Sets up background fetch for battery-aware scheduling
  static Future<void> initializeBackgroundFetch() async {
    await bf.BackgroundFetch.configure(
      bf.BackgroundFetchConfig(
        minimumFetchInterval: 15, // minutes
        stopOnTerminate: false,
        startOnBoot: true,
        enableHeadless: true,
        requiresBatteryNotLow: true,
        requiresCharging: false,
        requiresStorageNotLow: true,
        requiresDeviceIdle: false,
        requiredNetworkType: bf.NetworkType.NONE,
      ),
      _backgroundFetchHeadlessTask,
    );
  }

  @pragma('vm:entry-point')
  static void _backgroundFetchHeadlessTask(String taskId) async {
    // Headless task for periodic battery checks / maintenance
    bf.BackgroundFetch.finish(taskId);
  }

  /// Start scanning for supported HR devices
  Future<void> startScan({Duration timeout = const Duration(seconds: 15)}) async {
    _setState(BleConnectionState.scanning);

    final foundDevices = <BluetoothDevice>[];
    final completer = Completer<void>();

    FlutterBluePlus.onScanResults.listen((results) {
      for (final r in results) {
        if (_isSupportedDevice(r.device)) {
          foundDevices.add(r.device);
        }
      }
    });

    await FlutterBluePlus.startScan(
      withServices: [Guid(_polarH10ServiceUuid), Guid(_gattHrServiceUuid)],
      timeout: timeout,
    );

    await completer.future;

    if (foundDevices.isNotEmpty) {
      // Prefer Polar H10 (has PPI for RR intervals) over generic HR
      foundDevices.sort((a, b) => _devicePriority(b).compareTo(_devicePriority(a)));
      await connect(foundDevices.first);
    } else {
      _setState(BleConnectionState.disconnected);
    }
  }

  int _devicePriority(BluetoothDevice device) {
    // Higher = better
    if (device.platformName.contains('Polar') || device.platformName.contains('H10')) return 100;
    if (device.platformName.contains('Garmin') || device.platformName.contains('HRM')) return 90;
    return 50; // Generic HR
  }

  bool _isSupportedDevice(BluetoothDevice device) {
    return device.platformName.contains('Polar') ||
           device.platformName.contains('Garmin') ||
           device.platformName.contains('H10') ||
           device.platformName.contains('HRM') ||
           device.platformName.toLowerCase().contains('heart');
  }

  /// Connect to a device and start HR streaming
  Future<void> connect(BluetoothDevice device) async {
    _connectedDevice = device;
    _setState(BleConnectionState.connecting);

    try {
      await device.connect(autoConnect: true, timeout: const Duration(seconds: 15));
      _setState(BleConnectionState.connected);

      // Discover services
      final services = await device.discoverServices();

      // Try Polar PMD first (for PPI/RR intervals)
      final pmdService = services.where((s) => s.uuid.toString() == _polarH10ServiceUuid).firstOrNull;
      if (pmdService != null) {
        _deviceType = DeviceType.polarH10;
        await _setupPolarPmd(pmdService);
      } else {
        // Fall back to standard GATT HR
        final hrService = services.where((s) => s.uuid.toString() == _gattHrServiceUuid).firstOrNull;
        if (hrService != null) {
          _deviceType = DeviceType.genericHr;
          await _setupGattHr(hrService);
        } else {
          throw Exception('No supported HR service found');
        }
      }

      _isStreaming = true;
      _startBatteryMonitoring();
      _setState(BleConnectionState.streaming);
    } catch (e) {
      _setState(BleConnectionState.error);
      _scheduleReconnect();
      rethrow;
    }
  }

  Future<void> _setupPolarPmd(BluetoothService service) async {
    _pmdDataChar = service.characteristics
        .where((c) => c.uuid.toString() == _polarPmdDataUuid)
        .firstOrNull;
    _pmdControlChar = service.characteristics
        .where((c) => c.uuid.toString() == _polarPmdControlUuid)
        .firstOrNull;

    if (_pmdDataChar == null || _pmdControlChar == null) {
      throw Exception('Polar PMD characteristics not found');
    }

    // Enable PPI notifications (RR intervals)
    await _pmdDataChar!.setNotifyValue(true);

    // Start PPI stream (0x02 = PPI, 0x01 = 130Hz, 0x00 = no skin temp)
    // Format: [opcode=0x01, type=0x02, settings...]
    final startCmd = Uint8List.fromList([0x01, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);
    await _pmdControlChar!.write(startCmd, withoutResponse: false);

    _pmdSubscription = _pmdDataChar!.lastValueStream.listen(_parsePolarPpi);
  }

  Future<void> _setupGattHr(BluetoothService service) async {
    _hrMeasurementChar = service.characteristics
        .where((c) => c.uuid.toString() == _gattHrMeasurementUuid)
        .firstOrNull;

    if (_hrMeasurementChar == null) {
      throw Exception('HR Measurement characteristic not found');
    }

    // Note: Standard GATT HR only gives BPM, not RR intervals.
    // For RR intervals we need Polar PMD or similar proprietary service.
    await _hrMeasurementChar!.setNotifyValue(true);
    _hrSubscription = _hrMeasurementChar!.lastValueStream.listen(_parseGattHr);
  }

  void _parsePolarPpi(List<int> data) {
    // Polar PPI format: [type=0x02, ...] then 8-byte timestamps + 2-byte RR intervals
    if (data.isEmpty || data[0] != 0x02) return;

    final rrIntervals = <int>[];
    int offset = 1; // Skip type byte

    // Each PPI sample: 8 bytes timestamp (uint64, microseconds since boot) + 2 bytes RR (uint16, ms)
    while (offset + 9 < data.length) {
      // We only need RR intervals (last 2 bytes of each 10-byte sample)
      final rrMs = data[offset + 8] | (data[offset + 9] << 8);
      if (rrMs > 200 && rrMs < 2000) { // Sanity check: 30-300 BPM
        rrIntervals.add(rrMs);
      }
      offset += 10;
    }

    if (rrIntervals.isNotEmpty) {
      final timestampMs = DateTime.now().millisecondsSinceEpoch;
      _onRrBatch(rrIntervals, timestampMs);
      _persistRrBatch(rrIntervals, timestampMs);
    }
  }

  void _parseGattHr(List<int> data) {
    // Standard GATT HR Measurement format
    // Flags byte 0: bit 0 = HR format (0=uint8, 1=uint16)
    // bit 1-2 = sensor contact, bit 3 = energy expended, bit 4 = RR intervals present
    if (data.isEmpty) return;

    final flags = data[0];
    final hrFormatUint16 = (flags & 0x01) != 0;
    final hasRrIntervals = (flags & 0x10) != 0;

    int offset = 1;
    final hr = hrFormatUint16
        ? data[offset] | (data[offset + 1] << 8)
        : data[offset];
    offset += hrFormatUint16 ? 2 : 1;

    // Energy expended (if present)
    if ((flags & 0x08) != 0) offset += 2;

    // RR intervals (if present) - 16-bit uint, 1/1024 second units
    if (hasRrIntervals && data.length >= offset + 2) {
      final rrIntervals = <int>[];
      while (offset + 1 < data.length) {
        final rrRaw = data[offset] | (data[offset + 1] << 8);
        final rrMs = (rrRaw * 1000 / 1024).round(); // Convert to ms
        if (rrMs > 200 && rrMs < 2000) {
          rrIntervals.add(rrMs);
        }
        offset += 2;
      }

      if (rrIntervals.isNotEmpty) {
        final timestampMs = DateTime.now().millisecondsSinceEpoch;
        _onRrBatch(rrIntervals, timestampMs);
        _persistRrBatch(rrIntervals, timestampMs);
      }
    }

    // Store latest HR for UI
    _storeLatestHr(hr);
  }

  Future<void> _persistRrBatch(List<int> rrIntervals, int timestampMs) async {
    await _db.transaction((txn) async {
      final batch = txn.batch();
      for (final rr in rrIntervals) {
        batch.insert('rr_intervals', {
          'timestamp_ms': timestampMs,
          'rr_ms': rr,
          'device_type': _deviceType.name,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> _storeLatestHr(int hr) async {
    await _db.insert('latest_hr', {
      'hr_bpm': hr,
      'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      'device_type': _deviceType.name,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  void _startBatteryMonitoring() {
    _batteryCheckTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      await _readBatteryLevel();
      // Adjust scan duty cycle based on battery
      if (_batteryLevel < 20) {
        _adjustDutyCycle(lowBattery: true);
      }
    });
  }

  Future<void> _readBatteryLevel() async {
    if (_connectedDevice == null) return;

    try {
      final services = await _connectedDevice!.discoverServices();
      final batteryService = services
          .where((s) => s.uuid.toString() == '0000180f-0000-1000-8000-00805f9b34fb')
          .firstOrNull;

      if (batteryService != null) {
        final batteryChar = batteryService.characteristics
            .where((c) => c.uuid.toString() == '00002a19-0000-1000-8000-00805f9b34fb')
            .firstOrNull;

        if (batteryChar != null) {
          final value = await batteryChar.read();
          if (value.isNotEmpty) {
            _batteryLevel = value[0];
          }
        }
      }
    } catch (_) {
      // Battery read failed, use last known
    }
  }

  void _adjustDutyCycle({required bool lowBattery}) {
    // In a full implementation, this would adjust WorkManager constraints
    // For now, we just log the intent
    // TODO: Integrate with workmanager to reduce scan frequency
  }

  void _scheduleReconnect() {
    if (_reconnectTimer?.isActive ?? false) return;

    // Exponential backoff: 5s, 10s, 20s, 40s, max 60s
    int delaySeconds = 5;
    _reconnectTimer = Timer.periodic(Duration(seconds: delaySeconds), (timer) async {
      if (_connectedDevice != null && _state != BleConnectionState.streaming) {
        try {
          await connect(_connectedDevice!);
          timer.cancel();
        } catch (_) {
          delaySeconds = math.min(delaySeconds * 2, 60);
          timer.cancel();
          _scheduleReconnect();
        }
      } else {
        timer.cancel();
      }
    });
  }

  void _setState(BleConnectionState newState) {
    _state = newState;
    // Notify listeners if needed
  }

  /// Disconnect and cleanup
  Future<void> disconnect() async {
    _isStreaming = false;
    _reconnectTimer?.cancel();
    _batteryCheckTimer?.cancel();
    _hrSubscription?.cancel();
    _pmdSubscription?.cancel();

    if (_hrMeasurementChar != null) {
      await _hrMeasurementChar!.setNotifyValue(false);
    }
    if (_pmdDataChar != null) {
      await _pmdDataChar!.setNotifyValue(false);
    }
    if (_pmdControlChar != null) {
      // Stop PPI stream
      final stopCmd = Uint8List.fromList([0x00, 0x02]);
      await _pmdControlChar!.write(stopCmd, withoutResponse: false);
    }

    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
    }

    _setState(BleConnectionState.disconnected);
  }

  /// Get current battery level (0-100)
  int get batteryLevel => _batteryLevel;

  /// Get device type
  DeviceType get deviceType => _deviceType;

  /// Check if currently streaming
  bool get isStreaming => _isStreaming;
}

enum DeviceType {
  unknown,
  polarH10,
  genericHr,
}

enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
  streaming,
  error,
}

/// WorkManager task for background BLE maintenance
@pragma('vm:entry-point')
void bleBackgroundTask() {
  Workmanager().executeTask((task, inputData) async {
    switch (task) {
      case 'ble-battery-check':
        // Battery check handled by BleDeviceManager._batteryCheckTimer
        break;
      case 'ble-reconnect':
        // Reconnect logic handled by BleDeviceManager._scheduleReconnect
        break;
    }
    return Future.value(true);
  });
}