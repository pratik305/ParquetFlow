SELECT payment_type, count(*) AS trips, round(avg(CAST(tip_amount AS double)), 2) AS avg_tip
FROM parquetflow_db.raw_csv
GROUP BY payment_type
ORDER BY trips DESC
