import json
import os
import re
import urllib.parse

import pandas as pd


def is_processable(key: str) -> bool:
    return key.startswith("raw/") and key.endswith(".csv")


def _normalize(name: str) -> str:
    return re.sub(r"[^0-9a-z]+", "_", name.strip().lower()).strip("_")


def clean(df: pd.DataFrame, date_col: str) -> tuple[pd.DataFrame, dict]:
    df = df.copy()
    df.columns = [_normalize(c) for c in df.columns]
    stats = {"rows_in": len(df)}

    parsed = pd.to_datetime(df[date_col], errors="coerce")
    keep = parsed.notna()
    stats["dropped_null_date"] = int((~keep).sum())
    df = df[keep].copy()
    # millisecond precision: Athena cannot read pandas' default nanosecond timestamps
    df[date_col] = parsed[keep].astype("datetime64[ms]")
    for col in df.columns:
        if col.endswith("_datetime") and col != date_col:
            df[col] = pd.to_datetime(df[col], errors="coerce").astype("datetime64[ms]")
    df["date"] = parsed[keep].dt.strftime("%Y-%m-%d")

    before = len(df)
    df = df.drop_duplicates()
    stats["dropped_duplicates"] = before - len(df)
    stats["rows_out"] = len(df)
    return df.reset_index(drop=True), stats


def lambda_handler(event, context):
    import awswrangler as wr

    date_col = os.environ.get("DATE_COLUMN", "date")
    processed = skipped = 0

    for record in event["Records"]:
        bucket = record["s3"]["bucket"]["name"]
        key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        if not is_processable(key):
            print(f"skip: {key}")
            skipped += 1
            continue

        df = wr.s3.read_csv(f"s3://{bucket}/{key}")
        df, stats = clean(df, date_col)
        print(json.dumps({"key": key, **stats}))

        if stats["rows_out"] == 0:
            skipped += 1
            continue

        wr.s3.to_parquet(
            df,
            path=f"s3://{bucket}/curated/",
            dataset=True,
            partition_cols=["date"],
            mode="overwrite_partitions",
        )
        processed += 1

    return {"processed": processed, "skipped": skipped}
