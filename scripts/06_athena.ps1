# Dot-source: . .\scripts\06_athena.ps1
# Usage: Invoke-Athena (Get-Content sql\parquet_hourly.sql -Raw)
function Invoke-Athena {
    param(
        [Parameter(Mandatory)][string]$Sql,
        [string]$WorkGroup = 'parquetflow',
        [string]$Database = 'parquetflow_db'
    )

    # Windows PowerShell 5.1 strips double quotes from native args, so escape them
    $flat = ($Sql -replace '\s+', ' ').Trim().Replace('"', '\"')

    $qid = aws athena start-query-execution `
        --work-group $WorkGroup `
        --query-execution-context Database=$Database `
        --query-string $flat `
        --query QueryExecutionId --output text

    do {
        Start-Sleep -Seconds 2
        $state = aws athena get-query-execution --query-execution-id $qid `
            --query QueryExecution.Status.State --output text
    } while ($state -in 'QUEUED', 'RUNNING')

    if ($state -ne 'SUCCEEDED') {
        aws athena get-query-execution --query-execution-id $qid `
            --query QueryExecution.Status.StateChangeReason --output text
    }

    $scanned = [long](aws athena get-query-execution --query-execution-id $qid `
        --query QueryExecution.Statistics.DataScannedInBytes --output text)

    [pscustomobject]@{
        QueryId      = $qid
        State        = $state
        ScannedBytes = $scanned
        ScannedMB    = [math]::Round($scanned / 1MB, 2)
    }
}
