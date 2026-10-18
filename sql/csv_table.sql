CREATE EXTERNAL TABLE IF NOT EXISTS parquetflow_db.raw_csv (
  vendorid string,
  tpep_pickup_datetime string,
  tpep_dropoff_datetime string,
  passenger_count string,
  trip_distance string,
  ratecodeid string,
  store_and_fwd_flag string,
  pulocationid string,
  dolocationid string,
  payment_type string,
  fare_amount string,
  extra string,
  mta_tax string,
  tip_amount string,
  tolls_amount string,
  improvement_surcharge string,
  total_amount string,
  congestion_surcharge string,
  airport_fee string,
  cbd_congestion_fee string
)
ROW FORMAT SERDE 'org.apache.hadoop.hive.serde2.OpenCSVSerde'
LOCATION 's3://BUCKET/raw/'
TBLPROPERTIES ('skip.header.line.count' = '1')
