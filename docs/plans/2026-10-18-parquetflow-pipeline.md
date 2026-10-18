# ParquetFlow Implementation Plan


**Goal:** Build a serverless pipeline (S3 raw CSV → Lambda → partitioned Parquet in S3 → Glue catalog → Athena) where every AWS resource is created with the AWS CLI, so the user learns the CLI.

**Architecture:** An S3 `ObjectCreated` event on `raw/*.csv` invokes a Python 3.12 Lambda using the AWS-managed AWSSDKPandas layer. It cleans the CSV with pandas and writes Parquet with awswrangler to `curated/`, partitioned by `date`. A Glue crawler registers the table and Athena queries both the CSV and the Parquet for a scan-size comparison.

**Tech Stack:** AWS CLI v2 (PowerShell), Python 3.12, pandas, awswrangler (layer), pytest, S3, Lambda, IAM, Glue, Athena, CloudWatch, optional SAM.

**Spec:** `PLAN.md` (the CLI-first design) and the project brief pasted in the session.

## Global Constraints

- Every resource is created with the CLI. The console is only for verification.
- Shell is PowerShell. Line continuation is a backtick. Policy JSON is passed with `file://`, zips with `fileb://`.
- Region `us-east-1`. Bucket `parquetflow-<account>-<region>`. Function `parquetflow-csv-to-parquet`. Lambda role `parquetflow-lambda-role`. Glue role `parquetflow-glue-role`. Glue database `parquetflow_db`. Crawler `parquetflow-crawler`. Athena workgroup `parquetflow`.
- Layer: `arn:aws:lambda:<region>:336392948345:layer:AWSSDKPandas-Python312:<latest>`.
- The trigger is filtered to prefix `raw/` and suffix `.csv`. Output goes only to `curated/`.
- The Lambda role gets read on `raw/*` and write only on `curated/*`. No wildcard actions or resources beyond that.
- Parquet write mode is `overwrite_partitions`, so re-uploads are idempotent.
- Each CLI task states the command, what each flag means, and a verification command.

## Review Focus

1. **Keys with spaces or `+`**: `my file.csv` arrives as `my+file.csv` in the event. Expect it to be read correctly via `unquote_plus`.
2. **Header-only or empty CSV**: expect a logged "0 rows" and no crash, with no Parquet written.
3. **Unparseable or null dates**: expect those rows dropped and counted in the log, not a crash.
4. **Same file uploaded twice**: expect identical row counts in Athena, with no duplicates.
5. **Event for a non-CSV or `curated/` key**: expect the handler to skip it and never recurse.

---

### Task 1: Environment and repo scaffold

**Files:**
- Create: `.gitignore`, `requirements-dev.txt`, `scripts/00_env.ps1`, `tests/__init__.py`, `src/__init__.py`

**Interfaces:**
- Produces: `scripts/00_env.ps1` sets `$REGION`, `$ACCOUNT`, `$BUCKET`. Every later script dot-sources it (`. .\scripts\00_env.ps1`).

- [ ] **Step 1: Verify the CLI and identity**

Run: `aws --version; aws sts get-caller-identity`
Expected: `aws-cli/2.x` and a JSON object with your Account and Arn. If it fails, run `aws configure` first.

- [ ] **Step 2: Create `scripts/00_env.ps1`**

It sets `$REGION="us-east-1"`, `$ACCOUNT` from `aws sts get-caller-identity --query Account --output text`, and `$BUCKET="parquetflow-$ACCOUNT-$REGION"`. It also sets `$env:AWS_DEFAULT_REGION=$REGION`.

- [ ] **Step 3: Create `.gitignore` and `requirements-dev.txt`**

`.gitignore` ignores `build/`, `data/`, `out.json`, `__pycache__/`, `.venv/`. `requirements-dev.txt` holds `pandas`, `pyarrow`, `pytest`.

- [ ] **Step 4: Set up the venv and verify**

Run: `python -m venv .venv; .\.venv\Scripts\pip install -r requirements-dev.txt; .\.venv\Scripts\pytest --version`
Expected: a pytest version prints.

- [ ] **Step 5: Place the dataset and commit**

Put a CSV with a date column in `data/sample.csv` (git-ignored).

```powershell
git init; git add .; git commit -m "chore: scaffold project"
```

---

### Task 2: S3 bucket

**Files:**
- Create: `scripts/01_s3.ps1`

**Interfaces:**
- Consumes: `$BUCKET`, `$REGION` from `00_env.ps1`.
- Produces: bucket with `raw/` and `curated/` placeholder keys.

- [ ] **Step 1: Write `scripts/01_s3.ps1` with these commands, in order**

1. `aws s3api create-bucket --bucket $BUCKET --region $REGION`
2. `aws s3api put-public-access-block --bucket $BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true`
3. `aws s3api put-object --bucket $BUCKET --key raw/` and the same for `curated/`

- [ ] **Step 2: Run and verify**

Run: `. .\scripts\00_env.ps1; .\scripts\01_s3.ps1; aws s3 ls s3://$BUCKET`
Expected: `PRE raw/` and `PRE curated/`.

- [ ] **Step 3: Verify the public-access block**

Run: `aws s3api get-public-access-block --bucket $BUCKET --query PublicAccessBlockConfiguration`
Expected: all four values `true`.

- [ ] **Step 4: Commit** (`git add scripts; git commit -m "feat: s3 bucket script"`)

---

### Task 3: Cleaning logic and handler (TDD, local)

**Files:**
- Create: `src/lambda_function.py`, `tests/test_clean.py`, `tests/event.json`

**Interfaces:**
- Produces:
  - `clean(df: pd.DataFrame, date_col: str) -> tuple[pd.DataFrame, dict]`. The returned frame has normalized lowercase `snake_case` columns and a string column `date` (`YYYY-MM-DD`). The dict has keys `rows_in`, `rows_out`, `dropped_null_date`, `dropped_duplicates`.
  - `is_processable(key: str) -> bool`. True only for keys that start with `raw/` and end with `.csv`.
  - `lambda_handler(event: dict, context) -> dict`. Reads the env var `DATE_COLUMN` (default `date`) and the awswrangler calls are the only AWS access.

- [ ] **Step 1: Write failing tests in `tests/test_clean.py`**

- `test_normalizes_column_names`: `" Pickup Date "` becomes `pickup_date`.
- `test_adds_date_partition_column`: input `"2024-03-05 14:22:00"` gives `date == "2024-03-05"`.
- `test_drops_null_and_unparseable_dates`: rows with `None` and `"garbage"` are dropped, and `stats["dropped_null_date"] == 2`.
- `test_dedupes_exact_duplicates`: two identical rows give one row, and `stats["dropped_duplicates"] == 1`.
- `test_header_only_returns_empty_frame`: `rows_out == 0`, no exception.
- `test_is_processable`: `raw/a.csv` is true. `raw/a.txt`, `curated/a.csv` and `a.csv` are false.

- [ ] **Step 2: Run to verify failure**

Run: `.\.venv\Scripts\pytest tests -v`
Expected: FAIL with `ImportError` (module not defined).

- [ ] **Step 3: Implement `clean` and `is_processable` in `src/lambda_function.py`**

Use `pd.to_datetime(..., errors="coerce")` for dates and `drop_duplicates()` after the date filter. `wr` is imported inside `lambda_handler`, so tests do not need awswrangler.

- [ ] **Step 4: Run to verify the tests pass**

Run: `.\.venv\Scripts\pytest tests -v`
Expected: 6 passed.

- [ ] **Step 5: Implement `lambda_handler`**

For each record:
1. Take the bucket and `key = urllib.parse.unquote_plus(...)`.
2. Skip with a log line if `not is_processable(key)`.
3. `wr.s3.read_csv(f"s3://{bucket}/{key}")`.
4. Call `clean`.
5. If `rows_out == 0`, log it and skip the write.
6. Otherwise `wr.s3.to_parquet(df, path=f"s3://{bucket}/curated/", dataset=True, partition_cols=["date"], mode="overwrite_partitions")`.
7. Log the stats dict as JSON and return `{"processed": n, "skipped": m}`.

- [ ] **Step 6: Create `tests/event.json`**

An S3 put event with bucket name `REPLACE_ME` and key `raw/sample.csv`.

- [ ] **Step 7: Commit** (`git add src tests; git commit -m "feat: csv cleaning and handler"`)

---

### Task 4: IAM role for Lambda

**Files:**
- Create: `infra/iam/trust-policy.json`, `infra/iam/lambda-policy.json`, `scripts/02_iam.ps1`

**Interfaces:**
- Consumes: `$BUCKET`, `$ACCOUNT`.
- Produces: role `parquetflow-lambda-role` with inline policy `parquetflow-inline`.

- [ ] **Step 1: Write `trust-policy.json`**

Principal `lambda.amazonaws.com`, action `sts:AssumeRole`.

- [ ] **Step 2: Write `lambda-policy.json`**

- Statement 1: `s3:GetObject` on `arn:aws:s3:::BUCKET/raw/*`.
- Statement 2: `s3:PutObject` and `s3:DeleteObject` on `arn:aws:s3:::BUCKET/curated/*`.
- Statement 3: `s3:ListBucket` on `arn:aws:s3:::BUCKET` with condition `StringLike s3:prefix: ["curated/*", "raw/*"]`.
- Statement 4: `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents` on `arn:aws:logs:us-east-1:ACCOUNT:log-group:/aws/lambda/parquetflow-*:*`.

`02_iam.ps1` replaces `BUCKET` and `ACCOUNT` in the policy text before upload (write the substituted copy to `build/`).

- [ ] **Step 3: Write `02_iam.ps1`**

Run `aws iam create-role --role-name parquetflow-lambda-role --assume-role-policy-document file://infra/iam/trust-policy.json`, then `aws iam put-role-policy --role-name parquetflow-lambda-role --policy-name parquetflow-inline --policy-document file://build/lambda-policy.json`.

- [ ] **Step 4: Run and verify**

Run: `.\scripts\02_iam.ps1; aws iam get-role-policy --role-name parquetflow-lambda-role --policy-name parquetflow-inline`
Expected: the policy JSON with your real bucket name.

- [ ] **Step 5: Prove least privilege**

Run: `aws iam simulate-principal-policy --policy-source-arn arn:aws:iam::${ACCOUNT}:role/parquetflow-lambda-role --action-names s3:PutObject --resource-arns arn:aws:s3:::$BUCKET/raw/x.csv --query "EvaluationResults[0].EvalDecision"`
Expected: `"implicitDeny"`. The same call against `curated/x.parquet` should return `"allowed"`.

- [ ] **Step 6: Commit** (`git add infra scripts; git commit -m "feat: lambda iam role"`)

---

### Task 5: Deploy Lambda and wire the S3 trigger

**Files:**
- Create: `scripts/03_lambda.ps1`, `infra/notification.json`

**Interfaces:**
- Consumes: role from Task 4, handler from Task 3.
- Produces: function `parquetflow-csv-to-parquet` and bucket notification.

- [ ] **Step 1: Look up the latest layer version**

Run: `aws lambda list-layer-versions --layer-name arn:aws:lambda:${REGION}:336392948345:layer:AWSSDKPandas-Python312 --query "LayerVersions[0].LayerVersionArn" --output text`
Expected: an ARN ending in `:<number>`. Store it in `$LAYER`.

- [ ] **Step 2: Package**

Run: `New-Item -ItemType Directory -Force build; Compress-Archive src/lambda_function.py build/function.zip -Force`
Expected: `build/function.zip` exists. It holds only the handler file, since the layer supplies pandas and awswrangler.

- [ ] **Step 3: Create the function**

`aws lambda create-function --function-name parquetflow-csv-to-parquet --runtime python3.12 --handler lambda_function.lambda_handler --role arn:aws:iam::${ACCOUNT}:role/parquetflow-lambda-role --zip-file fileb://build/function.zip --layers $LAYER --timeout 120 --memory-size 1024 --environment "Variables={DATE_COLUMN=<your_date_column>}"`

If it fails with an invalid role error, wait 10 seconds and retry (IAM propagation).

- [ ] **Step 4: Manual invoke before wiring the trigger**

Upload the CSV, then run `aws s3 cp data/sample.csv s3://$BUCKET/raw/sample.csv`. Then run `aws lambda invoke --function-name parquetflow-csv-to-parquet --payload fileb://tests/event.json out.json; Get-Content out.json`
Expected: `{"processed": 1, "skipped": 0}`. `tests/event.json` must have the real bucket name first.

- [ ] **Step 5: Grant S3 permission to invoke**

`aws lambda add-permission --function-name parquetflow-csv-to-parquet --statement-id s3-invoke --action lambda:InvokeFunction --principal s3.amazonaws.com --source-arn arn:aws:s3:::$BUCKET --source-account $ACCOUNT`

- [ ] **Step 6: Configure the bucket notification**

`infra/notification.json` has one `LambdaFunctionConfigurations` entry: the function ARN, event `s3:ObjectCreated:*`, and a `Filter` with key rules `prefix=raw/` and `suffix=.csv`. Apply it with `aws s3api put-bucket-notification-configuration --bucket $BUCKET --notification-configuration file://build/notification.json`.

- [ ] **Step 7: Verify**

Run: `aws s3api get-bucket-notification-configuration --bucket $BUCKET`
Expected: your function ARN and both filter rules.

- [ ] **Step 8: Commit** (`git add scripts infra; git commit -m "feat: deploy lambda and trigger"`)

---

### Task 6: End-to-end run and log check

**Files:**
- Create: `scripts/04_test_pipeline.ps1`

- [ ] **Step 1: Upload to trigger the pipeline**

Run: `aws s3 cp data/sample.csv s3://$BUCKET/raw/sample2.csv`

- [ ] **Step 2: Watch the logs**

Run: `aws logs tail /aws/lambda/parquetflow-csv-to-parquet --since 5m`
Expected: a JSON stats line with `rows_in`, `rows_out` and no `ERROR`.

- [ ] **Step 3: Verify the partitioned output**

Run: `aws s3 ls s3://$BUCKET/curated/ --recursive --human-readable`
Expected: keys like `curated/date=2024-03-05/<uuid>.snappy.parquet`.

- [ ] **Step 4: Verify idempotency**

Upload the same file again and re-run step 3. Expected: the same number of partitions, and no growth in total object count.

- [ ] **Step 5: Verify error search**

Run: `aws logs filter-log-events --log-group-name /aws/lambda/parquetflow-csv-to-parquet --filter-pattern ERROR`
Expected: empty `events`.

- [ ] **Step 6: Commit** (`git add scripts; git commit -m "test: e2e pipeline script"`)

---

### Task 7: Glue database and crawler

**Files:**
- Create: `infra/iam/glue-trust.json`, `infra/iam/glue-s3-policy.json`, `scripts/05_glue.ps1`

**Interfaces:**
- Produces: database `parquetflow_db` with a table for `curated/` that has partition key `date`.

- [ ] **Step 1: Create the Glue role**

Trust principal `glue.amazonaws.com`. Create it with `aws iam create-role --role-name parquetflow-glue-role ...`. Attach `arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole` with `aws iam attach-role-policy`. Add an inline policy that allows `s3:GetObject` and `s3:ListBucket` on `curated/*` only.

- [ ] **Step 2: Create the database and crawler**

`aws glue create-database --database-input Name=parquetflow_db`
`aws glue create-crawler --name parquetflow-crawler --role parquetflow-glue-role --database-name parquetflow_db --targets "S3Targets=[{Path=s3://$BUCKET/curated/}]"`

- [ ] **Step 3: Run the crawler and wait**

`aws glue start-crawler --name parquetflow-crawler`
Poll: `aws glue get-crawler --name parquetflow-crawler --query Crawler.State --output text`
Expected: `RUNNING` then `READY`, which takes about 1–2 minutes.

- [ ] **Step 4: Verify the table**

Run: `aws glue get-table --database-name parquetflow_db --name curated --query "Table.[Name,PartitionKeys[].Name]"`
Expected: `["curated", ["date"]]`. If the table has a different name, use the name from `aws glue get-tables`.

- [ ] **Step 5: Commit** (`git add infra scripts; git commit -m "feat: glue catalog"`)

---

### Task 8: Athena queries and CSV vs Parquet comparison

**Files:**
- Create: `scripts/06_athena.ps1`, `sql/parquet_aggregate.sql`, `sql/parquet_topn.sql`, `sql/csv_table.sql`, `sql/csv_aggregate.sql`, `docs/scan-comparison.md`

**Interfaces:**
- Produces: PowerShell function `Invoke-Athena -Sql <string> -> hashtable(State, DataScannedBytes)`. It starts the query, polls `get-query-execution` until `SUCCEEDED` or `FAILED`, then returns the state and `Statistics.DataScannedInBytes`.

- [ ] **Step 1: Create the workgroup**

`aws athena create-work-group --name parquetflow --configuration "ResultConfiguration={OutputLocation=s3://$BUCKET/athena-results/}"`

- [ ] **Step 2: Implement `Invoke-Athena` and a smoke query**

Run: `Invoke-Athena "SELECT count(*) FROM parquetflow_db.curated"`
Expected: `State = SUCCEEDED`.

- [ ] **Step 3: Write the Parquet queries**

`parquet_aggregate.sql` is a `GROUP BY` aggregate on a numeric column. `parquet_topn.sql` is a top-N with `ORDER BY ... LIMIT 10`. Add a third query filtered with `WHERE "date" = '<one real date>'` to show partition pruning.

- [ ] **Step 4: Create the CSV table and equivalent query**

`csv_table.sql` is `CREATE EXTERNAL TABLE parquetflow_db.raw_csv (...) ROW FORMAT DELIMITED FIELDS TERMINATED BY ',' LOCATION 's3://BUCKET/raw/' TBLPROPERTIES ('skip.header.line.count'='1')`, with all columns as `string`. `csv_aggregate.sql` is the same aggregate as the Parquet one, with the cast made explicit.

- [ ] **Step 5: Record the scan sizes**

Run each query through `Invoke-Athena` and write the CSV and Parquet `DataScannedBytes` into `docs/scan-comparison.md` as a table with a ratio column.
Expected: Parquet scans noticeably fewer bytes. The partition-filtered query scans the least.

- [ ] **Step 6: Fetch results from the CLI**

Run: `aws athena get-query-results --query-execution-id $qid --max-items 5`
Expected: a `ResultSet` with rows.

- [ ] **Step 7: Take screenshots** of the Athena console results for the README, then commit (`git add sql scripts docs; git commit -m "feat: athena queries and scan comparison"`).

---

### Task 9: Monitoring, README, diagram

**Files:**
- Create: `scripts/07_alarm.ps1`, `README.md`, `docs/architecture.md` (Mermaid diagram)

- [ ] **Step 1: Create the error alarm**

`aws cloudwatch put-metric-alarm --alarm-name parquetflow-lambda-errors --namespace AWS/Lambda --metric-name Errors --dimensions Name=FunctionName,Value=parquetflow-csv-to-parquet --statistic Sum --period 300 --evaluation-periods 1 --threshold 1 --comparison-operator GreaterThanOrEqualToThreshold`
Verify: `aws cloudwatch describe-alarms --alarm-names parquetflow-lambda-errors --query "MetricAlarms[0].StateValue"`. Expected: `OK` or `INSUFFICIENT_DATA`.

- [ ] **Step 2: Write the Mermaid architecture diagram** in `docs/architecture.md`: S3 raw → Lambda → S3 curated → Glue crawler/catalog → Athena.

- [ ] **Step 3: Write `README.md`**

Sections: what it is, diagram, how to run (`scripts/00`–`07` in order), the scan comparison table, screenshots, IAM least-privilege notes, and cleanup.

- [ ] **Step 4: Commit and push** (`git add .; git commit -m "docs: readme and alarm"`; then create the GitHub repo and push).

---

### Task 10 (optional): SAM template

**Files:**
- Create: `template.yaml`, `samconfig.toml`

- [ ] **Step 1:** Express the bucket, function, layer, role policy and S3 event in `template.yaml` with the same names and permissions as Global Constraints. Use a different stack and bucket name (`parquetflow-sam-...`) so it does not clash.
- [ ] **Step 2: Deploy and verify**

Run: `sam build; sam deploy --guided`
Then: `aws cloudformation describe-stack-events --stack-name <stack> --max-items 10`
Expected: `CREATE_COMPLETE`. Upload a CSV and check that `curated/` fills.

- [ ] **Step 3: Commit** (`git add template.yaml samconfig.toml; git commit -m "feat: sam template"`).

---

### Task 11: Cleanup script

**Files:**
- Create: `scripts/99_cleanup.ps1`

- [ ] **Step 1:** Write the delete commands in dependency order: empty and delete the bucket (including the notification), delete the Lambda, Glue crawler and database, Athena workgroup (`--recursive-delete-work-group`), the CloudWatch alarm, the inline and attached role policies, then the two roles.
- [ ] **Step 2: Run and verify**

Run: `aws s3 ls | Select-String parquetflow; aws lambda list-functions --query "Functions[].FunctionName"`
Expected: nothing named `parquetflow` remains.

- [ ] **Step 3: Commit** (`git add scripts; git commit -m "chore: cleanup script"`).
