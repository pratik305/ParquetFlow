# ParquetFlow: Serverless CSV → Parquet pipeline (AWS CLI learning plan)

Flow: `raw/*.csv` in S3 → S3 event → Lambda (awswrangler) → `curated/` partitioned Parquet → Glue Crawler → Athena

**Rule of this project:** every resource is created with the CLI, never the console. The console is only for checking your work. Each step shows the command, what each part means, and how to verify it.

Shell: PowerShell on Windows. Use a backtick `` ` `` for line continuation. Policy JSON goes in files and is passed with `file://` to avoid quoting problems.

---

## Phase 0: Setup (10 min)

| Step | Command | What you learn |
|---|---|---|
| Install AWS CLI v2 | `aws --version` | CLI v2 is the one to use |
| Create a least-privilege admin user or use SSO | `aws configure` / `aws configure sso` | Profiles, credentials, `~/.aws/` |
| Confirm identity | `aws sts get-caller-identity` | Which account and user you act as. Run this before anything destructive. |
| Set variables | `$REGION="us-east-1"; $ACCOUNT=(aws sts get-caller-identity --query Account --output text); $BUCKET="parquetflow-$ACCOUNT-$REGION"` | `--query` (JMESPath) and `--output text` |

Concepts: global flags (`--region`, `--profile`, `--output json/table/text`, `--query`), and `aws <service> help`.

Pick a dataset with a date column (NYC taxi sample or a Kaggle sales CSV). Save it as `data/sample.csv`. Keep it under about 50 MB.

## Phase 1: S3 (5 min)

```powershell
aws s3api create-bucket --bucket $BUCKET --region $REGION
aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-object --bucket $BUCKET --key raw/
aws s3api put-object --bucket $BUCKET --key curated/
aws s3 ls s3://$BUCKET
```

- `create-bucket` outside us-east-1 needs `--create-bucket-configuration LocationConstraint=$REGION`.
- Concepts: `s3` (high-level: cp, sync, ls) vs `s3api` (low-level, 1:1 with the API). Prefixes are not real folders.

## Phase 2: IAM least-privilege role for Lambda (10 min)

Files to write in `infra/iam/`:
- `trust-policy.json`: allows `lambda.amazonaws.com` to `sts:AssumeRole`.
- `lambda-policy.json` allows only:
  - `s3:GetObject` on `arn:aws:s3:::BUCKET/raw/*`
  - `s3:PutObject`, `s3:DeleteObject` and `s3:ListBucket` on `curated/*` (`ListBucket` is on the bucket ARN with a prefix condition). `awswrangler` needs these for `overwrite_partitions`.
  - `logs:CreateLogGroup`, `logs:CreateLogStream` and `logs:PutLogEvents` on `/aws/lambda/parquetflow-*`

```powershell
aws iam create-role --role-name parquetflow-lambda-role --assume-role-policy-document file://infra/iam/trust-policy.json
aws iam put-role-policy --role-name parquetflow-lambda-role --policy-name parquetflow-inline --policy-document file://infra/iam/lambda-policy.json
aws iam get-role --role-name parquetflow-lambda-role
```

Concepts: trust policy vs permissions policy, inline vs managed, ARNs, and why `*` is bad.

## Phase 3: Lambda (25 min)

`src/lambda_function.py`. Behaviour:
1. Read the bucket and key from the S3 event. URL-decode the key with `urllib.parse.unquote_plus`.
2. `wr.s3.read_csv(path)`.
3. Clean:
   - normalize column names
   - cast types
   - parse the date column with `pd.to_datetime`
   - drop rows with a null date or key
   - `drop_duplicates()`
4. Add a partition column `date` (`YYYY-MM-DD`).
5. `wr.s3.to_parquet(df, path=f"s3://{bucket}/curated/", dataset=True, partition_cols=["date"], mode="overwrite_partitions")`. This makes re-uploads idempotent.
6. Log row counts in and out.

Deploy:
```powershell
Compress-Archive src/lambda_function.py build/function.zip -Force
aws lambda list-layer-versions --layer-name arn:aws:lambda:${REGION}:336392948345:layer:AWSSDKPandas-Python312 --query "LayerVersions[0].LayerVersionArn" --output text
aws lambda create-function --function-name parquetflow-csv-to-parquet --runtime python3.12 --handler lambda_function.lambda_handler --role arn:aws:iam::${ACCOUNT}:role/parquetflow-lambda-role --zip-file fileb://build/function.zip --layers <LAYER_ARN> --timeout 120 --memory-size 1024
```

Trigger. The two permission pieces are separate, and that is the key lesson:
```powershell
# 1. Allow S3 to invoke the function (resource-based policy)
aws lambda add-permission --function-name parquetflow-csv-to-parquet --statement-id s3-invoke --action lambda:InvokeFunction --principal s3.amazonaws.com --source-arn arn:aws:s3:::$BUCKET --source-account $ACCOUNT
# 2. Tell the bucket to send events (notification-configuration.json: ObjectCreated:*, prefix raw/, suffix .csv)
aws s3api put-bucket-notification-configuration --bucket $BUCKET --notification-configuration file://infra/notification.json
```

- The `raw/` prefix filter prevents an infinite loop. Output goes to `curated/`.
- Update code later with `aws lambda update-function-code --function-name ... --zip-file fileb://build/function.zip`.
- Test manually first: `aws lambda invoke --function-name ... --payload fileb://tests/event.json out.json`.

Concepts: execution role vs resource policy, layers, `fileb://` vs `file://`, and the event JSON shape.

## Phase 4: Run it and check logs (10 min)

```powershell
aws s3 cp data/sample.csv s3://$BUCKET/raw/sample.csv
aws logs tail /aws/lambda/parquetflow-csv-to-parquet --follow
aws s3 ls s3://$BUCKET/curated/ --recursive --human-readable
```

Also try `aws logs filter-log-events --log-group-name ... --filter-pattern ERROR`.
If nothing runs, debug in this order: notification config → lambda permission → role permissions → logs.

## Phase 5: Glue Crawler and Catalog (10 min)

Needs a second role, `parquetflow-glue-role`, with trust for `glue.amazonaws.com`, the managed `AWSGlueServiceRole` policy, and read on `curated/*`.

```powershell
aws glue create-database --database-input Name=parquetflow_db
aws glue create-crawler --name parquetflow-crawler --role parquetflow-glue-role --database-name parquetflow_db --targets "S3Targets=[{Path=s3://$BUCKET/curated/}]"
aws glue start-crawler --name parquetflow-crawler
aws glue get-crawler --name parquetflow-crawler --query Crawler.State
aws glue get-tables --database-name parquetflow_db --query "TableList[].Name"
```

Concepts: Data Catalog is metadata only, and a crawler infers the schema and partitions. Poll `get-crawler` until it is `READY`.

## Phase 6: Athena and the CSV vs Parquet comparison (15 min)

```powershell
aws athena create-work-group --name parquetflow --configuration "ResultConfiguration={OutputLocation=s3://$BUCKET/athena-results/}"
$qid = aws athena start-query-execution --work-group parquetflow --query-execution-context Database=parquetflow_db --query-string "SELECT ..." --query QueryExecutionId --output text
aws athena get-query-execution --query-execution-id $qid --query "QueryExecution.[Status.State,Statistics.DataScannedInBytes]"
aws athena get-query-results --query-execution-id $qid
```

1. Run 2–3 Parquet queries: an aggregate, a top-N, and a filter on the partition column.
2. Create a CSV table over `raw/` with `CREATE EXTERNAL TABLE ... ROW FORMAT DELIMITED ... LOCATION 's3://$BUCKET/raw/'`.
3. Run the same query on both tables. Record `DataScannedInBytes` for each in a table in the README.
4. Add a query that filters on the partition column to show pruning.

Concepts: Athena is async (start → poll → fetch), workgroups, results land in S3, and you pay per byte scanned.

## Phase 7: Polish (15 min)

- `README.md`: architecture diagram (Mermaid or draw.io PNG), the scan-size table, and screenshots of the Athena results.
- Put all CLI commands in `scripts/01_setup.ps1` … `scripts/99_cleanup.ps1`.
- Add a CloudWatch alarm on Lambda errors: `aws cloudwatch put-metric-alarm`.
- Check the role in the IAM Access Analyzer / policy simulator: `aws iam simulate-principal-policy`.
- Push to GitHub. Add `.gitignore` for `build/`, `data/` and `out.json`.

## Phase 8 (optional): Infrastructure as code with SAM (20 min)

Rewrite phases 1–3 as `template.yaml` and deploy with `sam build && sam deploy --guided`. Compare it with what you did by hand. `aws cloudformation describe-stack-events` shows what it is creating.

## Cleanup (always do this)

```powershell
aws s3 rm s3://$BUCKET --recursive; aws s3api delete-bucket --bucket $BUCKET
aws lambda delete-function --function-name parquetflow-csv-to-parquet
aws glue delete-crawler --name parquetflow-crawler; aws glue delete-database --name parquetflow_db
aws athena delete-work-group --work-group parquetflow --recursive-delete-work-group
aws iam delete-role-policy --role-name parquetflow-lambda-role --policy-name parquetflow-inline; aws iam delete-role --role-name parquetflow-lambda-role
```

Cost: all of this stays within pennies or the free tier on a small dataset. Crawler runs are billed per minute, so run it only a few times.

## Suggested order of work together

Build in this sequence and verify each step before moving on: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8. I can write the Lambda code, the JSON files and the scripts, and explain each command as you run it.
