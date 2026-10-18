SELECT payment_type, count(*) AS trips, round(avg(tip_amount), 2) AS avg_tip
FROM parquetflow_db.curated
WHERE "date" = '2025-02-03'
GROUP BY payment_type
ORDER BY trips DESC
