// onboarding_flow.dart — FIRST-LAUNCH FLOW < 2 MIN
//
// Steps:
//  1. Permissions (BLE, location, notifications, health)
//  2. Strap pair (scan → connect → verify)
//  3. Profile (age, sex, weight, height, resting HR)
//  4. Done → Home screen
//
// Target: < 120 seconds total, < 3 taps per step, no dead ends.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:health/health.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/adapters/adapter.dart';
import '../ble/ble_engine.dart';
import '../data/db.dart';
import '../state/app_state.dart';

/// The onboarding flow state.
enum OnboardingStep {
  welcome,
  permissions,
  strapPair,
  profile,
  complete,
}

/// Controller for the onboarding flow.
class OnboardingController extends ChangeNotifier {
  OnboardingController({
    required this.appState,
    required this.bleEngine,
    required this.db,
  });

  final AppState appState;
  final BleEngine bleEngine;
  final LocalDb db;

  OnboardingStep _step = OnboardingStep.welcome;
  OnboardingStep get step => _step;

  String _error = '';
  String get error => _error;

  BluetoothDevice? _foundDevice;
  BluetoothDevice? get foundDevice => _foundDevice;

  Map<String, dynamic> _profile = {
    'age': 30,
    'sex': 'male',
    'weight_kg': 75.0,
    'height_cm': 180.0,
    'resting_hr': 60,
  };
  Map<String, dynamic> get profile => _profile;

  /// Start the onboarding flow.
  Future<void> start() async {
    _step = OnboardingStep.permissions;
    notifyListeners();
    await _requestPermissions();
  }

  /// Step 1: Permissions.
  Future<void> _requestPermissions() async {
    final permissions = [
      Permission.bluetooth,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.locationWhenInUse,
      Permission.notification,
    ];

    if (Platform.isIOS) {
      // iOS: HealthKit permissions requested via Health framework
    } else {
      permissions.add(Permission.healthConnect);
    }

    final results = await Future.wait([
      for (final p in permissions) p.request(),
    ]);

    final denied = <Permission>[
      for (var i = 0; i < permissions.length; i++)
        if (results[i] != PermissionStatus.granted) permissions[i]
    ];

    if (denied.isNotEmpty) {
      _error = 'Required permissions denied: ${denied.join(", ")}';
      notifyListeners();
      return;
    }

    _step = OnboardingStep.strapPair;
    notifyListeners();
    await _scanForStrap();
  }

  /// Step 2: Strap pairing.
  Future<void> _scanForStrap() async {
    _error = '';

    bleEngine.scan(
      onFound: (device, adv) {
        if (device.advName.contains('WHOOP') ||
            device.advName.contains('OpenStrap')) {
          _foundDevice = device;
          notifyListeners();
        }
      },
    );

    // Auto-connect after 10s if a device was found
    await Future.delayed(const Duration(seconds: 10));
    if (_foundDevice != null && _step == OnboardingStep.strapPair) {
      await _connectToStrap();
    }
  }

  Future<void> _connectToStrap() async {
    if (_foundDevice == null) return;

    try {
      await bleEngine.connect(_foundDevice!);
      _step = OnboardingStep.profile;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to connect: $e';
      notifyListeners();
    }
  }

  /// Step 3: Profile.
  Future<void> _saveProfile() async {
    await db.putProfile(_profile);
    appState.profile = _profile;

    _step = OnboardingStep.complete;
    notifyListeners();
  }

  /// Complete onboarding.
  void complete() {
    _step = OnboardingStep.complete;
    notifyListeners();
    // AppState will transition to main UI
    appState.completeOnboarding();
  }

  void updateProfile(String key, dynamic value) {
    _profile[key] = value;
    notifyListeners();
  }

  void setError(String message) {
    _error = message;
    notifyListeners();
  }

  void clearError() {
    _error = '';
    notifyListeners();
  }
}

/// UI for the onboarding flow.
class OnboardingFlow extends StatelessWidget {
  const OnboardingFlow({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      child: _stepContent(context),
    );
  }

  Widget _stepContent(BuildContext context) {
    final controller = context.watch<OnboardingController>();

    switch (controller.step) {
      case OnboardingStep.welcome:
        return _WelcomeScreen(onStart: controller.start);
      case OnboardingStep.permissions:
        return _PermissionsScreen(
          error: controller.error,
          onRetry: controller._requestPermissions,
        );
      case OnboardingStep.strapPair:
        return _StrapPairScreen(
          device: controller.foundDevice,
          error: controller.error,
          onConnect: controller._connectToStrap,
        );
      case OnboardingStep.profile:
        return _ProfileScreen(
          profile: controller.profile,
          onSave: controller._saveProfile,
          onUpdate: controller.updateProfile,
        );
      case OnboardingStep.complete:
        return _CompleteScreen(onDone: controller.complete);
    }
  }
}

class _WelcomeScreen extends StatelessWidget {
  final VoidCallback onStart;
  const _WelcomeScreen({required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.favorite, size: 80, color: Colors.red),
              const SizedBox(height: 24),
              Text(
                'OpenStrap Edge',
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Your local-first fitness companion',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 48),
              FilledButton.icon(
                onPressed: onStart,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Get Started'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionsScreen extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;
  const _PermissionsScreen({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.security, size: 80, color: Colors.blue),
              const SizedBox(height: 24),
              Text(
                'Permissions Required',
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const SizedBox(height: 16),
              const Text(
                'We need Bluetooth, Location, and Notifications to connect your band and track your health.',
                textAlign: TextAlign.center,
              ),
              if (error.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(error, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Grant Permissions'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StrapPairScreen extends StatelessWidget {
  final BluetoothDevice? device;
  final String error;
  final VoidCallback onConnect;
  const _StrapPairScreen({
    required this.device,
    required this.error,
    required this.onConnect,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.bluetooth_searching, size: 80, color: Colors.green),
              const SizedBox(height: 24),
              Text(
                device != null ? 'Found ${device!.advName}' : 'Searching for band...',
                style: Theme.of(context).textTheme.displaySmall,
              ),
              if (device != null) ...[
                const SizedBox(height: 16),
                Text(
                  'Connecting...',
                  style: Theme.of(context).textTheme.bodyLarge,
                ),
                const SizedBox(height: 8),
                const CircularProgressIndicator(),
              ],
              if (error.isNotEmpty) ...[
                const SizedBox(height: 24),
                Text(error, style: const TextStyle(color: Colors.red)),
              ],
              const SizedBox(height: 32),
              FilledButton.icon(
                onPressed: onConnect,
                icon: const Icon(Icons.bluetooth),
                label: const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProfileScreen extends StatelessWidget {
  final Map<String, dynamic> profile;
  final VoidCallback onSave;
  final Function(String, dynamic) onUpdate;
  const _ProfileScreen({
    required this.profile,
    required this.onSave,
    required this.onUpdate,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Your Profile',
              style: Theme.of(context).textTheme.displayMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Used to personalize your health metrics',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 32),
            _ProfileField(
              label: 'Age',
              value: profile['age'] as int,
              onChanged: (v) => onUpdate('age', v),
              min: 10,
              max: 100,
            ),
            const SizedBox(height: 16),
            _ProfileSelect(
              label: 'Sex',
              value: profile['sex'] as String,
              options: const ['male', 'female', 'other'],
              onChanged: (v) => onUpdate('sex', v),
            ),
            const SizedBox(height: 16),
            _ProfileField(
              label: 'Weight (kg)',
              value: (profile['weight_kg'] as double).round(),
              onChanged: (v) => onUpdate('weight_kg', v.toDouble()),
              min: 30,
              max: 200,
            ),
            const SizedBox(height: 16),
            _ProfileField(
              label: 'Height (cm)',
              value: (profile['height_cm'] as double).round(),
              onChanged: (v) => onUpdate('height_cm', v.toDouble()),
              min: 100,
              max: 250,
            ),
            const SizedBox(height: 16),
            _ProfileField(
              label: 'Resting HR (bpm)',
              value: profile['resting_hr'] as int,
              onChanged: (v) => onUpdate('resting_hr', v),
              min: 30,
              max: 120,
            ),
            const SizedBox(height: 48),
            FilledButton.icon(
              onPressed: onSave,
              icon: const Icon(Icons.check),
              label: const Text('Save & Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileField extends StatelessWidget {
  final String label;
  final int value;
  final ValueChanged<int> onChanged;
  final int min;
  final int max;
  const _ProfileField({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.min,
    required this.max,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Row(
          children: [
            IconButton(
              onPressed: value > min ? () => onChanged(value - 1) : null,
              icon: const Icon(Icons.remove),
            ),
            Expanded(
              child: Text(
                '$value',
                style: Theme.of(context).textTheme.displayMedium,
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              onPressed: value < max ? () => onChanged(value + 1) : null,
              icon: const Icon(Icons.add),
            ),
          ],
        ),
      ],
    );
  }
}

class _ProfileSelect extends StatelessWidget {
  final String label;
  final String value;
  final List<String> options;
  final ValueChanged<String> onChanged;
  const _ProfileSelect({
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: value,
          items: options
              .map((o) => DropdownMenuItem(value: o, child: Text(o)))
              .toList(),
          onChanged: (v) => onChanged(v ?? value),
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }
}

class _CompleteScreen extends StatelessWidget {
  final VoidCallback onDone;
  const _CompleteScreen({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.check_circle, size: 80, color: Colors.green),
              const SizedBox(height: 24),
              Text(
                'All Set!',
                style: Theme.of(context).textTheme.displayMedium,
              ),
              const SizedBox(height: 16),
              const Text(
                'Your band is connected and your profile is saved.\nOpenStrap Edge is ready to track your health.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              FilledButton.icon(
                onPressed: onDone,
                icon: const Icon(Icons.arrow_forward),
                label: const Text('Go to Dashboard'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}