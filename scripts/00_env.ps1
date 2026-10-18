# Dot-source this file: . .\scripts\00_env.ps1
$REGION  = "us-east-1"
$ACCOUNT = aws sts get-caller-identity --query Account --output text
$BUCKET  = "parquetflow-$ACCOUNT-$REGION"
$env:AWS_DEFAULT_REGION = $REGION

Write-Host "REGION=$REGION ACCOUNT=$ACCOUNT BUCKET=$BUCKET"
