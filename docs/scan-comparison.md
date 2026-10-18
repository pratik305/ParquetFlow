# CSV vs Parquet: data scanned in Athena

Dataset: NYC yellow taxi trips, February 2025, first 400,000 rows (43.7 MB as CSV, about 8 MB as Parquet).
Parquet is partitioned by pickup date (6 partitions) and compressed with Snappy.

| Query | Table | Data scanned | vs CSV |
|---|---|---|---|
| `payment_type` count and average tip | `raw_csv` | 43.73 MB (45,853,740 B) | 1× |
| `payment_type` count and average tip | `curated` (Parquet) | 0.64 MB (667,977 B) | ~69× less |
| same, filtered to `date = '2025-02-03'` | `curated` (Parquet) | 0.13 MB (141,339 B) | ~324× less |
| top 10 pickup zones | `curated` (Parquet) | 0.99 MB (1,034,253 B) | n/a |
| trips per pickup hour | `curated` (Parquet) | 2.12 MB (2,221,904 B) | n/a |

## Why

- **Columnar:** the aggregate needs 2 of 20 columns. Parquet reads only those. CSV is row-oriented, so Athena must read every byte of every row.
- **Compression:** similar values stored together compress well, so the files are about 5× smaller on disk.
- **Partition pruning:** a filter on the partition column lets Athena skip whole folders. The CSV table has no such option.

## Caveats

- Athena bills a minimum of 10 MB per query, so at this size the cost is the same for every query. The scan sizes still show how the savings grow with data volume.
- The CSV table stores every column as `string` and casts at query time. Parquet stores real types.
- Results should match between CSV and Parquet. Check this before publishing the numbers.
