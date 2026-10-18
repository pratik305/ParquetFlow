SELECT hour(tpep_pickup_datetime) AS pickup_hour, count(*) AS trips
FROM parquetflow_db.curated
GROUP BY 1
ORDER BY 1
