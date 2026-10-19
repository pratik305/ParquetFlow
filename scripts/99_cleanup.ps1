# Delete the ParquetFlow resources.
#   .\scripts\99_cleanup.ps1 -Target cli -DryRun     show what would be deleted
#   .\scripts\99_cleanup.ps1 -Target cli -Force      delete the CLI-built stack
#   .\scripts\99_cleanup.ps1 -Target sam -Force      delete the SAM (CloudFormation) stack
#   .\scripts\99_cleanup.ps1 -Target all -Force      both
param(
    [Parameter(Mandatory)][ValidateSet('cli', 'sam', 'all')][string]$Target,
    [switch]$DryRun,
    [switch]$Force
)

. "$PSScriptRoot\00_env.ps1" | Out-Null

if (-not $DryRun -and -not $Force) {
    $answer = Read-Host "Delete '$Target' resources in account $ACCOUNT ($REGION)? Type 'delete' to continue"
    if ($answer -ne 'delete') { Write-Host 'Cancelled.'; return }
}

function Step {
    param([string]$Description, [scriptblock]$Action)
    if ($DryRun) { Write-Host "[dry run] $Description" }
    else { Write-Host "==> $Description"; & $Action }
}

function Remove-CliStack {
    $fn = 'parquetflow-csv-to-parquet'

    Step "Empty and delete bucket $BUCKET" {
        aws s3 rm "s3://$BUCKET" --recursive --only-show-errors
        aws s3api delete-bucket --bucket $BUCKET
    }
    Step "Delete Lambda $fn" { aws lambda delete-function --function-name $fn }
    # Lambda log groups outlive the function, so delete them explicitly
    Step "Delete log group for $fn" { aws logs delete-log-group --log-group-name "/aws/lambda/$fn" }
    # The crawler must be idle (READY) to be deleted, and goes before its database
    Step 'Delete Glue crawler' { aws glue delete-crawler --name parquetflow-crawler }
    Step 'Delete Glue database (and its tables)' { aws glue delete-database --name parquetflow_db }
    Step 'Delete Athena workgroup' { aws athena delete-work-group --work-group parquetflow --recursive-delete-option }
    Step 'Delete alarm' { aws cloudwatch delete-alarms --alarm-names parquetflow-lambda-errors }

    # A role can only be deleted once every policy is removed from it
    Step 'Delete Lambda role' {
        aws iam delete-role-policy --role-name parquetflow-lambda-role --policy-name parquetflow-inline
        aws iam delete-role --role-name parquetflow-lambda-role
    }
    Step 'Delete Glue role' {
        aws iam detach-role-policy --role-name parquetflow-glue-role --policy-arn arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole
        aws iam delete-role-policy --role-name parquetflow-glue-role --policy-name parquetflow-glue-s3
        aws iam delete-role --role-name parquetflow-glue-role
    }
}

function Remove-SamStack {
    $bucket = "parquetflow-sam-$ACCOUNT-$REGION"
    $fn = 'parquetflow-sam-csv-to-parquet'

    # CloudFormation cannot delete a bucket that still holds objects
    Step "Empty bucket $bucket" { aws s3 rm "s3://$bucket" --recursive --only-show-errors }
    Step 'Delete CloudFormation stack parquetflow-sam (waits until finished)' {
        aws cloudformation delete-stack --stack-name parquetflow-sam
        aws cloudformation wait stack-delete-complete --stack-name parquetflow-sam
    }
    Step "Delete log group for $fn" { aws logs delete-log-group --log-group-name "/aws/lambda/$fn" }
}

if ($Target -in 'cli', 'all') { Remove-CliStack }
if ($Target -in 'sam', 'all') { Remove-SamStack }

if (-not $DryRun) {
    Write-Host "`n==> Anything named parquetflow that is left (should be empty):"
    aws s3 ls | Select-String parquetflow
    aws lambda list-functions --query "Functions[?starts_with(FunctionName,'parquetflow')].FunctionName" --output text
    aws glue get-databases --query "DatabaseList[?starts_with(Name,'parquetflow')].Name" --output text
    aws athena list-work-groups --query "WorkGroups[?starts_with(Name,'parquetflow')].Name" --output text
    aws cloudwatch describe-alarms --alarm-name-prefix parquetflow --query "MetricAlarms[].AlarmName" --output text
    aws iam list-roles --query "Roles[?starts_with(RoleName,'parquetflow')].RoleName" --output text
    aws logs describe-log-groups --log-group-name-prefix /aws/lambda/parquetflow --query "logGroups[].logGroupName" --output text
}
