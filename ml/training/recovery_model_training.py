#!/usr/bin/env python3
"""
Recovery Score ML Model Training Script
Trains a lightweight TensorFlow Lite model to predict 0-100 recovery score
from HRV, RHR, and sleep features.
"""

import os
import numpy as np
import pandas as pd
from sklearn.model_selection import train_test_split
from sklearn.preprocessing import StandardScaler
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
import json

# ============================================================
# CONFIGURATION
# ============================================================
SEED = 42
TEST_SIZE = 0.2
VAL_SIZE = 0.1
MAX_EPOCHS = 50
BATCH_SIZE = 32
PATIENCE = 10

# Input feature order (must match what the isolate passes)
FEATURE_NAMES = [
    'rmssd_7d_avg',      # 7-day avg RMSSD (ms)
    'rhr_7d_avg',        # 7-day avg RHR (bpm)
    'sleep_efficiency',  # Sleep efficiency (%)
    'hrv_trend',         # RMSSD trend slope (last 7 days)
    'sleep_consistency', # Sleep midpoint consistency
    'charging_flag',     # 1 if charging, 0 if on battery
]

TARGET_NAME = 'recovery_score'  # 0-100

# ============================================================
# SYNTHETIC DATA GENERATION
# ============================================================
# In production, replace this with real user DB data.
# The synthetic data mirrors typical HRV/RHR/recovery relationships.

def generate_synthetic_data(n_samples: int = 5000) -> pd.DataFrame:
    rng = np.random.RandomState(SEED)

    # Base physiological ranges
    # RMSSD typical: 20-100 ms for good recovery, < 20 ms for poor
    # RHR typical: 50-80 bpm for active, 40-60 bpm for very fit
    # Sleep efficiency: 75-95% typical

    data = {
        'rmssd_7d_avg': rng.uniform(15, 120, n_samples),       # ms
        'rhr_7d_avg': rng.uniform(45, 95, n_samples),         # bpm
        'sleep_efficiency': rng.uniform(70, 98, n_samples),   # %
        'hrv_trend': rng.uniform(-5, 5, n_samples),           # ms/day slope
        'sleep_consistency': rng.uniform(0.5, 1.0, n_samples), # 0-1
        'charging_flag': rng.choice([0, 1], n_samples, p=[0.7, 0.3]),  # mostly on battery
    }

    # Recovery score formula (ground truth, noisy)
    # Higher RMSSD → higher recovery
    # Lower RHR → higher recovery
    # Higher sleep efficiency → higher recovery
    # Positive HRV trend → higher recovery
    # Consistent sleep → higher recovery
    # Charging = yes slightly boosts recovery (more rest)

    raw_score = (
        20.0 +                                                       # baseline
        0.15 * data['rmssd_7d_avg'] +                              # +0.15 per ms RMSSD
       -0.10 * data['rhr_7d_avg'] +                                # -0.10 per bpm RHR
        15.0 * data['sleep_efficiency'] / 100.0 +                # +15% per efficiency
        10.0 * data['hrv_trend'] +                                 # +10 per ms/day trend
        20.0 * data['sleep_consistency'] +                        # +20 per consistency
        5.0 * data['charging_flag']                                # +5 if charging
    )

    # Clip to 0-100 and add noise
    recovery_score = np.clip(raw_score + rng.normal(0, 5, n_samples), 0, 100)

    df = pd.DataFrame(data)
    df[TARGET_NAME] = recovery_score
    return df


# ============================================================
# DATA PREPARATION
# ============================================================
def prepare_datasets(df: pd.DataFrame, test_size: float = TEST_SIZE, val_size: float = VAL_SIZE):
    X = df[FEATURE_NAMES].values.astype('float32')
    y = df[TARGET_NAME].values.astype('float32')

    # Split: train + val + test
    X_train_val, X_test, y_train_val, y_test = train_test_split(
        X, y, test_size=test_size, random_state=SEED, shuffle=True
    )
    X_train, X_val, y_train, y_val = train_test_split(
        X_train_val, y_train_val, test_size=val_size/(1-test_size), random_state=SEED, shuffle=True
    )

    # Scale using train-only statistics
    scaler = StandardScaler()
    X_train_scaled = scaler.fit_transform(X_train)
    X_val_scaled = scaler.transform(X_val)
    X_test_scaled = scaler.transform(X_test)

    # Save scaler info for the isolate
    scaler_info = {
        'mean': scaler.mean_.tolist(),
        'scale': scaler.scale_.tolist(),
        'feature_names': FEATURE_NAMES,
    }

    return {
        'X_train': X_train_scaled, 'y_train': y_train,
        'X_val': X_val_scaled, 'y_val': y_val,
        'X_test': X_test_scaled, 'y_test': y_test,
        'scaler_info': scaler_info,
        'feature_names': FEATURE_NAMES,
    }


# ============================================================
# MODEL ARCHITECTURE
# ============================================================
def build_model(input_dim: int = 6) -> keras.Model:
    model = keras.Sequential([
        layers.Dense(64, activation='relu', input_shape=(input_dim,)),
        layers.Dense(32, activation='relu'),
        layers.Dense(16, activation='relu'),
        layers.Dense(1, activation='sigmoid'),  # Output 0-1, we'll scale to 0-100
    ])

    # Custom training: map sigmoid [0,1] → recovery [0,100]
    model.compile(
        optimizer=keras.optimizers.Adam(learning_rate=1e-3),
        loss='mse',  # Mean squared error on scaled target
        metrics=['mae'],
    )
    return model


# ============================================================
# TRAINING PIPELINE
# ============================================================
def main():
    print("=" * 60)
    print("Recovery Score ML Model Training")
    print("=" * 60)

    # 1. Generate / load data
    print("\n[1/5] Generating synthetic training data (5000 samples)...")
    df = generate_synthetic_data(5000)
    print(f"   Generated {len(df)} samples")
    print(f"   Target stats: mean={df['recovery_score'].mean():.1f}, std={df['recovery_score'].std():.1f}")

    # 2. Prepare datasets
    print("\n[2/5] Preparing train/val/test splits...")
    datasets = prepare_datasets(df)
    print(f"   Train: {len(datasets['X_train'])} samples")
    print(f"   Val: {len(datasets['X_val'])} samples")
    print(f"   Test: {len(datasets['X_test'])} samples")

    # 3. Build model
    print("\n[3/5] Building TensorFlow model...")
    model = build_model(input_dim=len(FEATURE_NAMES))
    model.summary()

    # 4. Train with early stopping
    print("\n[4/5] Training model...")
    early_stop = keras.callbacks.EarlyStopping(
        monitor='val_loss',
        patience=PATIENCE,
        restore_best_weights=True,
        min_delta=0.01,
    )

    history = model.fit(
        datasets['X_train'], datasets['y_train'],
        validation_data=(datasets['X_val'], datasets['y_val']),
        epochs=MAX_EPOCHS,
        batch_size=BATCH_SIZE,
        callbacks=[early_stop],
        verbose=1,
    )

    # 5. Evaluate
    print("\n[5/5] Evaluating on test set...")
    test_loss, test_mae = model.evaluate(datasets['X_test'], datasets['y_test'], verbose=0)
    print(f"   Test MAE: {test_mae:.2f} recovery points")
    print(f"   Test Loss (MSE): {test_loss:.4f}")

    # Predictions vs actual
    y_pred = model.predict(datasets['X_test'], verbose=0).flatten()
    mae_raw = np.mean(np.abs(y_pred - datasets['y_test']))
    print(f"   Raw MAE (0-100 scale): {mae_raw:.2f}")

    # Correlation
    corr = np.corrcoef(y_pred, datasets['y_test'])[0, 1]
    print(f"   Pearson r: {corr:.3f}")

    # Save model
    model_dir = 'ml/model'
    os.makedirs(model_dir, exist_ok=True)

    # Save TensorFlow Keras model
    model_path = os.path.join(model_dir, 'recovery_model.h5')
    model.save(model_path)
    print(f"\n   Saved Keras model to: {model_path}")

    # Convert to TFLite
    print("\n   Converting to TensorFlow Lite (float16 quantization)...")
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    # Use float16 quantization - no representative dataset needed
    converter.target_spec.supported_types = [tf.float16]

    tflite_model = converter.convert()
    tflite_path = os.path.join(model_dir, 'recovery_model.tflite')
    with open(tflite_path, 'wb') as f:
        f.write(tflite_model)
    print(f"   Saved TFLite model to: {tflite_path}")
    print(f"   TFLite size: {len(tflite_model) / 1024:.1f} KB")

    # Save scaler info for isolate usage
    scaler_path = os.path.join(model_dir, 'scaler_info.json')
    with open(scaler_path, 'w') as f:
        json.dump(datasets['scaler_info'], f, indent=2)
    print(f"   Saved scaler info to: {scaler_path}")

    # Save feature names
    features_path = os.path.join(model_dir, 'feature_names.txt')
    with open(features_path, 'w') as f:
        for name in FEATURE_NAMES:
            f.write(f"{name}\n")
    print(f"   Saved feature names to: {features_path}")

    print("\n" + "=" * 60)
    print("Training complete! ✅")
    print("=" * 60)


if __name__ == '__main__':
    main()