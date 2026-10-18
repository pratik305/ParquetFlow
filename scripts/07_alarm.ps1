# Alarm when the Lambda reports any error in a 5-minute window
aws cloudwatch put-metric-alarm `
  --alarm-name parquetflow-lambda-errors `
  --namespace AWS/Lambda `
  --metric-name Errors `
  --dimensions Name=FunctionName,Value=parquetflow-csv-to-parquet `
  --statistic Sum `
  --period 300 `
  --evaluation-periods 1 `
  --threshold 1 `
  --comparison-operator GreaterThanOrEqualToThreshold `
  --treat-missing-data notBreaching
