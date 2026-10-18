import pandas as pd

from src.lambda_function import clean, is_processable


def test_normalizes_column_names():
    df = pd.DataFrame({" Pickup Date ": ["2024-03-05"], "Fare-Amount": [1.0]})
    out, _ = clean(df, "pickup_date")
    assert "pickup_date" in out.columns
    assert "fare_amount" in out.columns


def test_adds_date_partition_column():
    df = pd.DataFrame({"ts": ["2024-03-05 14:22:00"], "v": [1]})
    out, _ = clean(df, "ts")
    assert out["date"].tolist() == ["2024-03-05"]


def test_casts_date_column_to_millisecond_datetime():
    df = pd.DataFrame({"ts": ["2024-03-05 14:22:00"], "v": [1]})
    out, _ = clean(df, "ts")
    assert str(out["ts"].dtype) == "datetime64[ms]"


def test_casts_other_datetime_columns_without_dropping_rows():
    df = pd.DataFrame(
        {
            "pickup_datetime": ["2024-03-05 14:22:00", "2024-03-05 15:00:00"],
            "dropoff_datetime": ["2024-03-05 14:40:00", "garbage"],
        }
    )
    out, _ = clean(df, "pickup_datetime")
    assert len(out) == 2
    assert str(out["dropoff_datetime"].dtype) == "datetime64[ms]"
    assert out["dropoff_datetime"].isna().tolist() == [False, True]


def test_drops_null_and_unparseable_dates():
    df = pd.DataFrame({"ts": ["2024-03-05", None, "garbage"], "v": [1, 2, 3]})
    out, stats = clean(df, "ts")
    assert len(out) == 1
    assert stats["dropped_null_date"] == 2


def test_dedupes_exact_duplicates():
    df = pd.DataFrame({"ts": ["2024-03-05", "2024-03-05"], "v": [1, 1]})
    out, stats = clean(df, "ts")
    assert len(out) == 1
    assert stats["dropped_duplicates"] == 1


def test_header_only_returns_empty_frame():
    df = pd.DataFrame({"ts": [], "v": []})
    out, stats = clean(df, "ts")
    assert len(out) == 0
    assert stats["rows_out"] == 0


def test_is_processable():
    assert is_processable("raw/a.csv")
    assert not is_processable("raw/a.txt")
    assert not is_processable("curated/a.csv")
    assert not is_processable("a.csv")
