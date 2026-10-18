# Requires: . .\scripts\00_env.ps1
aws s3api create-bucket --bucket $BUCKET --region $REGION

aws s3api put-public-access-block --bucket $BUCKET `
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-object --bucket $BUCKET --key raw/
aws s3api put-object --bucket $BUCKET --key curated/
