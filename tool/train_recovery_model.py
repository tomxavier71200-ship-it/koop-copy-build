#!/usr/bin/env python3
"""
Recovery Score ML Model Training Pipeline

Extracts features from the OpenStrap database and trains a TensorFlow Lite model
to predict 0-100 recovery score based on:
- 7-day rolling HRV (RMSSD, lnRMSSD)
- 7-day rolling RHR
- Sleep consistency/efficiency
- Prior day strain
- Skin temperature trend
"""

import sqlite3
import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler
from sklearn.model_selection import train_test_split
from sklearn.metrics import mean_absolute_error, r2_score
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
import joblib
import os
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

DB_PATH = r'C:\Users\tomxa\Downloads\openstrap_export_1794052707860.db'
OUTPUT_DIR = r'C:\Users\tomxa\koop-copy-build\assets\ml'
os.makedirs(OUTPUT_DIR, exist_ok=True)

def extract_features():
    """Extract and engineer features from database."""
    conn = sqlite3.connect(DB_PATH)

    # Get day_result with key metrics
    day_query = """
    SELECT
        day_id,
        rhr,
        rmssd,
        readiness,
        skipped,
        partial
    FROM day_result
    WHERE skipped = 0 AND rhr IS NOT NULL AND rmssd IS NOT NULL
    ORDER BY day_id
    """
    day_df = pd.read_sql_query(day_query, conn)
    day_df['day_id'] = pd.to_datetime(day_df['day_id'])
    day_df = day_df.sort_values('day_id').reset_index(drop=True)

    # Get metric_series for additional features
    metric_query = """
    SELECT date, key, value
    FROM metric_series
    WHERE key IN (
        'sleep_perf', 'sleep_onset_sec', 'sleep_need_min', 'sleep_consistency',
        'strain', 'stress', 'steps', 'skin_temp_z', 'sdnn', 'worn_min', 'tst_min',
        'sol_min', 'cvhr', 'nocturnal_rmssd', 'hrv_cv', 'recovery_hr'
    )
    """
    metric_df = pd.read_sql_query(metric_query, conn)
    metric_df['date'] = pd.to_datetime(metric_df['date'])

    # Pivot metric series
    metric_pivot = metric_df.pivot_table(
        index='date', columns='key', values='value', aggfunc='first'
    ).reset_index()

    # Merge
    df = day_df.merge(metric_pivot, left_on='day_id', right_on='date', how='left')

    conn.close()

    print(f"Total days: {len(df)}")
    print(f"Date range: {df['day_id'].min()} to {df['day_id'].max()}")
    print(f"Columns: {list(df.columns)}")

    return df

def engineer_features(df):
    """Create rolling window features for ML."""
    df = df.copy()
    df = df.sort_values('day_id').reset_index(drop=True)

    # Target: next day's readiness (or composite recovery score)
    # Use readiness as proxy for recovery, shifted by -1 to predict tomorrow
    df['target_recovery'] = df['readiness'].shift(-1)

    # Rolling 7-day features
    windows = [3, 7, 14]
    for w in windows:
        df[f'rhr_mean_{w}d'] = df['rhr'].rolling(w, min_periods=1).mean()
        df[f'rhr_std_{w}d'] = df['rhr'].rolling(w, min_periods=1).std()
        df[f'rmssd_mean_{w}d'] = df['rmssd'].rolling(w, min_periods=1).mean()
        df[f'rmssd_std_{w}d'] = df['rmssd'].rolling(w, min_periods=1).std()
        df[f'lnrmssd_mean_{w}d'] = np.log(df['rmssd'].rolling(w, min_periods=1).mean().clip(lower=1))

    # Sleep features (7-day rolling)
    sleep_cols = ['sleep_perf', 'sleep_onset_sec', 'sleep_need_min', 'sleep_consistency', 'tst_min']
    for col in sleep_cols:
        if col in df.columns:
            df[f'{col}_mean_7d'] = df[col].rolling(7, min_periods=1).mean()
            df[f'{col}_std_7d'] = df[col].rolling(7, min_periods=1).std()

    # Strain/stress features
    if 'strain' in df.columns:
        df['strain_mean_7d'] = df['strain'].rolling(7, min_periods=1).mean()
        df['strain_prior_day'] = df['strain'].shift(1)

    if 'stress' in df.columns:
        df['stress_mean_7d'] = df['stress'].rolling(7, min_periods=1).mean()

    # Skin temperature
    if 'skin_temp_z' in df.columns:
        df['skin_temp_z_mean_7d'] = df['skin_temp_z'].rolling(7, min_periods=1).mean()
        df['skin_temp_z_trend_7d'] = df['skin_temp_z'].rolling(7, min_periods=1).apply(
            lambda x: np.polyfit(range(len(x)), x, 1)[0] if len(x) == 7 else 0, raw=True
        )

    # Steps
    if 'steps' in df.columns:
        df['steps_mean_7d'] = df['steps'].rolling(7, min_periods=1).mean()

    # HRV coefficient of variation
    if 'hrv_cv' in df.columns:
        df['hrv_cv_mean_7d'] = df['hrv_cv'].rolling(7, min_periods=1).mean()

    # Drop rows where target is NaN (last row)
    df = df.dropna(subset=['target_recovery'])

    # Fill remaining NaN with column means
    feature_cols = [c for c in df.columns if c not in ['day_id', 'date', 'target_recovery', 'skipped', 'partial', 'readiness', 'payload_json', 'window_json', 'computed_at', 'algo_version']]
    df[feature_cols] = df[feature_cols].fillna(df[feature_cols].mean())

    return df, feature_cols

def prepare_data(df, feature_cols):
    """Prepare train/test split."""
    X = df[feature_cols].values
    y = df['target_recovery'].values

    # Scale features
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    # Time-series split (no random shuffle)
    split_idx = int(len(X_scaled) * 0.8)
    X_train, X_test = X_scaled[:split_idx], X_scaled[split_idx:]
    y_train, y_test = y[:split_idx], y[split_idx:]

    print(f"Train: {X_train.shape}, Test: {X_test.shape}")
    print(f"Train target range: {y_train.min():.1f}-{y_train.max():.1f}")
    print(f"Test target range: {y_test.min():.1f}-{y_test.max():.1f}")

    return X_train, X_test, y_train, y_test, scaler

def build_model(input_dim):
    """Build a lightweight neural network for TFLite conversion."""
    model = keras.Sequential([
        layers.Input(shape=(input_dim,)),
        layers.Dense(64, activation='relu'),
        layers.BatchNormalization(),
        layers.Dropout(0.2),
        layers.Dense(32, activation='relu'),
        layers.BatchNormalization(),
        layers.Dropout(0.1),
        layers.Dense(16, activation='relu'),
        layers.Dense(1, activation='linear')  # Output: 0-100 recovery score
    ])

    model.compile(
        optimizer=keras.optimizers.Adam(learning_rate=0.001),
        loss='mse',
        metrics=['mae']
    )

    return model

def train_and_convert():
    """Main training pipeline."""
    print("=" * 60)
    print("RECOVERY SCORE ML MODEL TRAINING")
    print("=" * 60)

    # Extract data
    print("\n1. Extracting features from database...")
    df = extract_features()

    # Engineer features
    print("\n2. Engineering features...")
    df, feature_cols = engineer_features(df)

    print(f"\nFeature columns ({len(feature_cols)}):")
    for c in feature_cols:
        print(f"  {c}")

    # Prepare data
    print("\n3. Preparing train/test split...")
    X_train, X_test, y_train, y_test, scaler = prepare_data(df, feature_cols)

    # Build model
    print("\n4. Building model...")
    model = build_model(X_train.shape[1])
    model.summary()

    # Train
    print("\n5. Training model...")
    callbacks = [
        keras.callbacks.EarlyStopping(patience=15, restore_best_weights=True, monitor='val_mae'),
        keras.callbacks.ReduceLROnPlateau(patience=8, factor=0.5, min_lr=1e-6)
    ]

    history = model.fit(
        X_train, y_train,
        validation_data=(X_test, y_test),
        epochs=100,
        batch_size=16,
        callbacks=callbacks,
        verbose=1
    )

    # Evaluate
    print("\n6. Evaluating model...")
    y_pred = model.predict(X_test, verbose=0).flatten()
    mae = mean_absolute_error(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)

    print(f"Test MAE: {mae:.2f}")
    print(f"Test R²: {r2:.3f}")
    print(f"Target: MAE < 8, R² > 0.75")

    # Save scaler
    scaler_path = os.path.join(OUTPUT_DIR, 'recovery_scaler.joblib')
    joblib.dump(scaler, scaler_path)
    print(f"\nScaler saved to: {scaler_path}")

    # Save feature columns
    feature_path = os.path.join(OUTPUT_DIR, 'recovery_features.json')
    with open(feature_path, 'w') as f:
        json.dump(feature_cols, f)
    print(f"Feature columns saved to: {feature_path}")

    # Convert to TFLite
    print("\n7. Converting to TensorFlow Lite...")
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    converter.target_spec.supported_types = [tf.float16]  # Use float16 for smaller model

    tflite_model = converter.convert()

    tflite_path = os.path.join(OUTPUT_DIR, 'recovery_model.tflite')
    with open(tflite_path, 'wb') as f:
        f.write(tflite_model)

    print(f"TFLite model saved to: {tflite_path}")
    print(f"Model size: {len(tflite_model) / 1024:.1f} KB")

    # Verify TFLite model
    print("\n8. Verifying TFLite model...")
    interpreter = tf.lite.Interpreter(model_path=tflite_path)
    interpreter.allocate_tensors()

    input_details = interpreter.get_input_details()
    output_details = interpreter.get_output_details()

    print(f"Input: {input_details[0]['shape']} {input_details[0]['dtype']}")
    print(f"Output: {output_details[0]['shape']} {output_details[0]['dtype']}")

    # Test inference
    test_input = X_test[:1].astype(np.float32)
    interpreter.set_tensor(input_details[0]['index'], test_input)
    interpreter.invoke()
    tflite_pred = interpreter.get_tensor(output_details[0]['index'])
    print(f"TFLite prediction: {tflite_pred[0][0]:.1f} (Keras: {y_pred[0]:.1f}, Actual: {y_test[0]:.1f})")

    # Save training history plot data
    history_path = os.path.join(OUTPUT_DIR, 'training_history.json')
    with open(history_path, 'w') as f:
        json.dump({k: [float(v) for v in vals] for k, vals in history.history.items()}, f)

    print("\n" + "=" * 60)
    print("TRAINING COMPLETE!")
    print("=" * 60)
    print(f"Assets saved to: {OUTPUT_DIR}")
    print(f"  - recovery_model.tflite ({len(tflite_model)/1024:.1f} KB)")
    print(f"  - recovery_scaler.joblib")
    print(f"  - recovery_features.json")
    print(f"  - training_history.json")

    return model, scaler, feature_cols, mae, r2

if __name__ == '__main__':
    import json
    train_and_convert()