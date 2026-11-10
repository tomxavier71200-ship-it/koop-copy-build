#!/usr/bin/env python3
"""
Simplified Recovery Score Model - Ridge Regression + Tiny NN
Uses only the most predictive features to avoid overfitting on small dataset.
"""

import sqlite3
import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler
from sklearn.linear_model import RidgeCV
from sklearn.metrics import mean_absolute_error, r2_score
import tensorflow as tf
from tensorflow import keras
from tensorflow.keras import layers
import joblib
import os
import sys
import io
import json

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

DB_PATH = r'C:\Users\tomxa\Downloads\openstrap_export_1794052707860.db'
OUTPUT_DIR = r'C:\Users\tomxa\koop-copy-build\assets\ml'
os.makedirs(OUTPUT_DIR, exist_ok=True)

def extract_features():
    conn = sqlite3.connect(DB_PATH)

    day_query = """
    SELECT day_id, rhr, rmssd, readiness, skipped
    FROM day_result
    WHERE skipped = 0 AND rhr IS NOT NULL AND rmssd IS NOT NULL
    ORDER BY day_id
    """
    day_df = pd.read_sql_query(day_query, conn)
    day_df['day_id'] = pd.to_datetime(day_df['day_id'])

    metric_query = """
    SELECT date, key, value
    FROM metric_series
    WHERE key IN ('sleep_perf', 'sleep_consistency', 'strain', 'stress', 'steps', 'skin_temp_z', 'nocturnal_rmssd', 'cvhr')
    """
    metric_df = pd.read_sql_query(metric_query, conn)
    metric_df['date'] = pd.to_datetime(metric_df['date'])

    metric_pivot = metric_df.pivot_table(index='date', columns='key', values='value', aggfunc='first').reset_index()
    df = day_df.merge(metric_pivot, left_on='day_id', right_on='date', how='left')
    conn.close()

    print(f"Total days: {len(df)}")
    return df

def engineer_features(df):
    df = df.copy().sort_values('day_id').reset_index(drop=True)
    df['target_recovery'] = df['readiness'].shift(-1)

    # Only 7-day rolling on core features
    df['rhr_mean_7d'] = df['rhr'].rolling(7, min_periods=1).mean()
    df['rmssd_mean_7d'] = df['rmssd'].rolling(7, min_periods=1).mean()
    df['lnrmssd_mean_7d'] = np.log(df['rmssd_mean_7d'].clip(lower=1))

    # Sleep
    for col in ['sleep_perf', 'sleep_consistency']:
        if col in df.columns:
            df[f'{col}_mean_7d'] = df[col].rolling(7, min_periods=1).mean()

    # Strain/stress
    if 'strain' in df.columns:
        df['strain_mean_7d'] = df['strain'].rolling(7, min_periods=1).mean()
        df['strain_prior'] = df['strain'].shift(1)

    if 'stress' in df.columns:
        df['stress_mean_7d'] = df['stress'].rolling(7, min_periods=1).mean()

    # Skin temp
    if 'skin_temp_z' in df.columns:
        df['skin_temp_z_mean_7d'] = df['skin_temp_z'].rolling(7, min_periods=1).mean()

    # Nocturnal HRV & CVHR
    for col in ['nocturnal_rmssd', 'cvhr']:
        if col in df.columns:
            df[f'{col}_mean_7d'] = df[col].rolling(7, min_periods=1).mean()

    df = df.dropna(subset=['target_recovery'])

    # Core features only (15 features)
    feature_cols = [
        'rhr', 'rmssd', 'lnrmssd_mean_7d', 'rhr_mean_7d',
        'sleep_perf_mean_7d', 'sleep_consistency_mean_7d',
        'strain_prior', 'strain_mean_7d', 'stress_mean_7d',
        'skin_temp_z_mean_7d', 'nocturnal_rmssd_mean_7d', 'cvhr_mean_7d'
    ]

    # Filter existing
    feature_cols = [c for c in feature_cols if c in df.columns]
    df[feature_cols] = df[feature_cols].fillna(df[feature_cols].mean())

    return df, feature_cols

def train_ridge(df, feature_cols):
    """Train Ridge regression as baseline."""
    X = df[feature_cols].values
    y = df['target_recovery'].values

    split_idx = int(len(X) * 0.8)
    X_train, X_test = X[:split_idx], X[split_idx:]
    y_train, y_test = y[:split_idx], y[split_idx:]

    scaler = StandardScaler()
    X_train_s = scaler.fit_transform(X_train)
    X_test_s = scaler.transform(X_test)

    # Ridge with cross-validated alpha
    ridge = RidgeCV(alphas=[0.01, 0.1, 1.0, 10.0, 100.0], cv=5)
    ridge.fit(X_train_s, y_train)

    y_pred = ridge.predict(X_test_s)
    mae = mean_absolute_error(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)

    print(f"Ridge: MAE={mae:.2f}, R²={r2:.3f}, alpha={ridge.alpha_}")
    return ridge, scaler, mae, r2

def train_tiny_nn(df, feature_cols):
    """Train a tiny neural network."""
    X = df[feature_cols].values
    y = df['target_recovery'].values

    split_idx = int(len(X) * 0.8)
    X_train, X_test = X[:split_idx], X[split_idx:]
    y_train, y_test = y[:split_idx], y[split_idx:]

    scaler = StandardScaler()
    X_train_s = scaler.fit_transform(X_train)
    X_test_s = scaler.transform(X_test)

    # Very small model
    model = keras.Sequential([
        layers.Input(shape=(len(feature_cols),)),
        layers.Dense(16, activation='relu'),
        layers.Dense(8, activation='relu'),
        layers.Dense(1, activation='linear')
    ])

    model.compile(optimizer=keras.optimizers.Adam(0.01), loss='mse', metrics=['mae'])

    history = model.fit(
        X_train_s, y_train,
        validation_data=(X_test_s, y_test),
        epochs=200, batch_size=8,
        callbacks=[keras.callbacks.EarlyStopping(patience=20, restore_best_weights=True)],
        verbose=0
    )

    y_pred = model.predict(X_test_s, verbose=0).flatten()
    mae = mean_absolute_error(y_test, y_pred)
    r2 = r2_score(y_test, y_pred)

    print(f"Tiny NN: MAE={mae:.2f}, R²={r2:.3f}")
    return model, scaler, mae, r2

def convert_to_tflite(model, scaler, feature_cols, name):
    """Convert to TFLite with quantization."""
    converter = tf.lite.TFLiteConverter.from_keras_model(model)
    converter.optimizations = [tf.lite.Optimize.DEFAULT]
    tflite_model = converter.convert()

    path = os.path.join(OUTPUT_DIR, f'recovery_{name}.tflite')
    with open(path, 'wb') as f:
        f.write(tflite_model)
    print(f"{name} TFLite: {len(tflite_model)/1024:.1f} KB -> {path}")
    return path

def main():
    print("=" * 60)
    print("SIMPLIFIED RECOVERY MODEL TRAINING")
    print("=" * 60)

    df = extract_features()
    df, feature_cols = engineer_features(df)
    print(f"\nFeatures ({len(feature_cols)}): {feature_cols}")

    # Train Ridge
    print("\n--- Ridge Regression ---")
    ridge, scaler_ridge, mae_r, r2_r = train_ridge(df, feature_cols)

    # Train Tiny NN
    print("\n--- Tiny Neural Network ---")
    nn_model, scaler_nn, mae_n, r2_n = train_tiny_nn(df, feature_cols)

    # Choose better model
    if mae_r < mae_n:
        print(f"\n>> Ridge wins (MAE {mae_r:.1f} vs {mae_n:.1f})")
        best_model, best_scaler, best_name = ridge, scaler_ridge, 'ridge'
        best_mae, best_r2 = mae_r, r2_r
    else:
        print(f"\n>> Tiny NN wins (MAE {mae_n:.1f} vs {mae_r:.1f})")
        best_model, best_scaler, best_name = nn_model, scaler_nn, 'nn'
        best_mae, best_r2 = mae_n, r2_n

    # Save scaler and features
    joblib.dump(best_scaler, os.path.join(OUTPUT_DIR, 'recovery_scaler.joblib'))
    with open(os.path.join(OUTPUT_DIR, 'recovery_features.json'), 'w') as f:
        json.dump(feature_cols, f)

    # Convert best to TFLite
    if best_name == 'nn':
        convert_to_tflite(best_model, best_scaler, feature_cols, 'model')
    else:
        # For Ridge, create a tiny Keras wrapper
        wrapper = keras.Sequential([
            layers.Input(shape=(len(feature_cols),)),
            layers.Dense(1, use_bias=True, kernel_initializer=keras.initializers.Constant(best_model.coef_.reshape(-1, 1)),
                         bias_initializer=keras.initializers.Constant(best_model.intercept_))
        ])
        wrapper.layers[0].trainable = False
        convert_to_tflite(wrapper, best_scaler, feature_cols, 'model')

    print(f"\n✅ Best model: {best_name.upper()} (MAE={best_mae:.1f}, R²={best_r2:.3f})")
    print(f"Assets in: {OUTPUT_DIR}")

if __name__ == '__main__':
    main()