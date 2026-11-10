#!/usr/bin/env python3
import sqlite3
import json
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

db_path = r'C:\Users\tomxa\Downloads\openstrap_export_1794052707860.db'
conn = sqlite3.connect(db_path)
cursor = conn.cursor()

print("=== day_result columns ===")
cursor.execute("PRAGMA table_info(day_result)")
for col in cursor.fetchall():
    print(f"  {col[1]}: {col[2]}")

print("\n=== day_result sample (last 10) ===")
cursor.execute("SELECT day_id, algo_version, rhr, rmssd, readiness, skipped, partial FROM day_result ORDER BY day_id DESC LIMIT 10")
for row in cursor.fetchall():
    print(f"  {row}")

print("\n=== metric_series (last 20) ===")
cursor.execute("SELECT date, key, value FROM metric_series ORDER BY date DESC LIMIT 20")
for row in cursor.fetchall():
    print(f"  {row}")

print("\n=== baselines ===")
cursor.execute("SELECT * FROM baselines")
for row in cursor.fetchall():
    print(f"  {row}")

print("\n=== baselines columns ===")
cursor.execute("PRAGMA table_info(baselines)")
for col in cursor.fetchall():
    print(f"  {col[1]}: {col[2]}")

print("\n=== device ===")
cursor.execute("SELECT * FROM device")
for row in cursor.fetchall():
    print(f"  {row}")

print("\n=== sleep_session_candidates ===")
cursor.execute("SELECT * FROM sleep_session_candidates LIMIT 5")
for row in cursor.fetchall():
    vals = list(row)
    print(f"  {len(vals)} cols: {vals[:5]}...")

print("\n=== wake_day_features ===")
cursor.execute("SELECT * FROM wake_day_features LIMIT 3")
for row in cursor.fetchall():
    vals = list(row)
    print(f"  {len(vals)} cols: {vals[:5]}...")

print("\n=== sessions ===")
cursor.execute("SELECT * FROM sessions LIMIT 5")
for row in cursor.fetchall():
    vals = list(row)
    print(f"  {len(vals)} cols: {vals[:5]}...")

conn.close()