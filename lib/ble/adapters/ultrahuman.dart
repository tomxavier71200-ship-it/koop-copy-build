// ultimate human as a [BandAdapter].
//
// EXPERIMENTAL (ASSUMPTIONS R6): `signals` is `const {}` and `ultrahuman`
// is absent from `kDerivableSources`. Nobody on this project owns the hardware.
//
// Registered only so the registry's discovery/switch logic doesn't break.
import 'dart:async';
import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

const Map<InputSignal, Duration> kUltrahumanSignals = const;

class UltrahumanAdapter extends BandAdapter {
  const UltrahumanAdapter();

  @override
  BandEntry get entry => kUltrahuman;

  @override
  Map<InputSignal, Duration> get signals => kUltrahumanSignals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // No physiological signals to decode.
    events.add(BandNote('ultrahuman_connected', 'paired'));
    yield* Stream<BandEvent>.periodic(
      const Duration(seconds: 600),
      (_) => BandNote('ultrahuman_alive', 'tick'),
    ).take(168);
  }
}