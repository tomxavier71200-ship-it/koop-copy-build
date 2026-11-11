// gen4/gen5 as a [BandAdapter], by DELEGATION. NO DECODE LOGIC LIVES HERE —
// every byte-level fact (opcodes, offsets, framing) stays in `ble_engine.dart`
// and the sealed `protocol` package. This file exists so the seam has an
// entry for the primary band at all; it is a facade, not a second decoder.
//
// `run(link)` in M1 is a no-op that yields nothing — the engine drives its
// own flutter_blue_plus connection directly, and app_state.dart / background_sync.dart
// route COMMIT and ACK through BandHost directly (M1a/M1b). In M2 the engine's
// link is replaced with `link` and this run() body drives native batch commits
// through BandHost.commitNativeBatch.
//
// M2 replaces the engine's link with `link` and deletes this file's UnsupportedError.
// Until then, this run() body is a no-op that yields nothing, so M1 remains functional
// without the engine being forced through the adapter seam.

import 'dart:async';

import '../ble_engine.dart' show BleEngine;
import '_registry.dart';
import 'adapter.dart';
import 'signals.dart';

/// gen4 R24 v24/v12 — every entry is a column `LocalDb._queueDecodedOneHz`
/// actually writes (db.dart:4722, cross-checked against the schema rather
/// than the wire offsets, which are protocol-repo facts this file cannot
/// verify without touching the sealed protocol package). `ppgGreen` (the
/// green channel, @29/31) is NOT declared — it lands in `samples`, not a
/// substrate column any metric reads. `accelHighRate` is NOT declared — R10's
/// 100 Hz stream is ephemeral and never persisted (invariant 1), and a 1 Hz
/// accel bound is invalid there anyway (see `signals.dart`).
const Map<InputSignal, Duration> kWhoopGen4Signals = <InputSignal, Duration>{
  InputSignal.hr1Hz: Duration(seconds: 1), // hr u8@17
  InputSignal.rrIntervals: Duration(seconds: 1), // rrCount@18 + i16LE pairs@19
  InputSignal.accel1Hz: Duration(seconds: 1), // f32 @36/40/44
  InputSignal.ppgRedIr: Duration(seconds: 1), // u16 @64/66
  InputSignal.skinTempRaw: Duration(seconds: 1), // u16 @68
};

class WhoopFramedAdapter extends BandAdapter {
  const WhoopFramedAdapter(this._engine, this.entry);

  final BleEngine _engine;

  /// The delegate. Unused by anything in M1 (see the file header) — kept
  /// reachable for the caller that constructs this facade and for M2, which
  /// is what finally drives it through [run].
  BleEngine get engine => _engine;

  @override
  final BandEntry entry;

  @override
  Map<InputSignal, Duration> get signals => kWhoopGen4Signals;

  @override
  Stream<BandEvent> run(BandLink link) async* {
    // M1: this adapter's run() is a no-op. The engine drives its own
    // flutter_blue_plus connection, and COMMIT/ACK flow through BandHost
    // directly (see app_state.dart and background_sync.dart, M1a/M1b).
    // Yielding nothing keeps M1 functional without forcing the engine
    // through the adapter seam. M2 will replace this body to drive
    // native batch commits through BandHost.commitNativeBatch via the link.
    //
    // For now: yield nothing so M1's existing BleEngine-driven path
    // continues uninterrupted.
    // ignore: close_sinks
    // ignore: body_might_complete_normally
    // TODO(M2): replace this body to read from `link.notify(...)` and
    // yield SampleBatch/NeutralSample events decoded via the protocol package.
    // The engine's onDataStored / onRecordsBatch callbacks will then drive
    // the host commit path rather than the adapter being the source of truth.
    // Until M2, this is a passive facade.
  }
}