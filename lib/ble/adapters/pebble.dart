// pebble.dart — Pebble smartwatch as a [BandAdapter].
//
// Pebble is experimental: ASSUMPTIONS R6/E5/E6. The Pebble SDK abstracts
// the band entirely — the app cannot read its physiological signals, only
// basic metadata. We register it so the host infrastructure recognises it,
// but derive nothing from its sensors.
//
// WHY IT EXISTS: the registry needs every band to have an entry; unnamed bands
// break the discovery + host switch logic. Its `signals` is `const {}`, and
// it contributes nothing to `kDerivableSources`.
import 'dart:async';

import 'dart:typed_data';

import 'package:openstrap_protocol/openstrap_protocol.dart';

import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

const Map<InputSignal, Duration> kPebbleSignals = const {};

class PebbleAdapter extends BandAdapter {
  const PebbleAdapter();

  @override
  BandEntry get entry => kPebble;

  @override
  Map<InputSignal, Duration> get signals => kPebbleSignals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // Pebble has no physiological signals we can decode.
    // Register its identity only; yield nothing.
    events.add(BandNote('pebble_connected', 'paired'));
    yield* Stream<BandEvent>.periodic(
      const Duration(seconds: 3600),
      (_) => BandNote('pebble_alive', 'heartbeat'),
    ).take(100);
  }
}