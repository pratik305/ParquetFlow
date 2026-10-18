SELECT pulocationid AS pickup_zone, count(*) AS trips, round(avg(trip_distance), 2) AS avg_miles
FROM parquetflow_db.curated
GROUP BY pulocationid
ORDER BY trips DESC
LIMIT 10
