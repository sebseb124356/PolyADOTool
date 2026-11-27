<#
.SYNOPSIS
    Interactive tool to delete an Azure DevOps test run (incl. its linked
    test results/outcomes) or to list all test runs and save them to a file.

.DESCRIPTION
    Running the script without parameters starts an interactive menu:

      [1] Delete a test run  - asks for the Run ID, shows the run and its
          linked results/outcomes, asks for confirmation, deletes the run
          (which cascades to results/attachments), then verifies both the
          run and its results are gone (404).
      [2] List test runs    - fetches all test runs (paged) and saves them
          as a timestamped CSV in the current directory (or to -OutputPath).
      [Q] Quit.

    Authentication uses a Personal Access Token (PAT) read from the
    environment variable AZURE_DEVOPS_PAT (or AZDO_PAT as fallback).
    The PAT needs the "Test (read & write)" scope.

.EXAMPLE
    $env:AZURE_DEVOPS_PAT = "<your PAT>"
    .\Ado-TestRunTool.ps1 -Organization myorg -Project myproject

    # Pre-filled launcher (edit Example-Run.ps1 once, then just run it)
    .\Example-Run.ps1

    # Non-interactive: delete a run directly
    .\Ado-TestRunTool.ps1 -Organization myorg -Project myproject -RunId 1234

    # Non-interactive: export run list
    .\Ado-TestRunTool.ps1 -Organization myorg -Project myproject -ListRuns

.NOTES
    Based on:
      - Test Runs - Delete:       DELETE https://dev.azure.com/{org}/{project}/_apis/test/runs/{runId}?api-version=7.1
      - Test Runs - List:         GET    https://dev.azure.com/{org}/{project}/_apis/test/runs?api-version=7.1
      - Test Runs - List results: GET    https://dev.azure.com/{org}/{project}/_apis/test/runs/{runId}/results?api-version=7.1
    Run deletion removes the results server-side; there is no modern
    per-result delete API, hence the delete-run-then-verify approach.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)]
    [string]$Organization,

    [Parameter(Mandatory = $true)]
    [string]$Project,

    # Non-interactive: delete this run (skips the menu)
    [int]$RunId,

    # Non-interactive: export run list (skips the menu)
    [switch]$ListRuns,

    # Where to save the run list export (default: current directory)
    [string]$OutputPath,

    # Skip the interactive confirmation before deleting
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ApiVersion = '7.1'

# --- PAT from environment ---------------------------------------------------
$pat = $env:AZURE_DEVOPS_PAT
if (-not $pat) { $pat = $env:AZDO_PAT }
if (-not $pat) {
    throw "No PAT found. Set the environment variable AZURE_DEVOPS_PAT (scope: Test read & write), e.g. `$env:AZURE_DEVOPS_PAT = '<token>'."
}

$ProjectUri = "https://dev.azure.com/$Organization/$Project/_apis/test"
$headers = @{
    Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
}

function Invoke-AdoRest {
    param([string]$Method, [string]$Uri)
    try {
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    catch {
        $resp = $_.Exception.Response
        $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
        # Throw structured info so callers can distinguish 404 from real errors
        throw [pscustomobject]@{ StatusCode = $code; Message = $_.ErrorDetails.Message }
    }
}

function Test-Gone {
    param([string]$Uri)
    try { Invoke-AdoRest -Method Get -Uri $Uri | Out-Null; return $false }
    catch {
        $t = $_.TargetObject
        if ($t -and $t.PSObject.Properties['StatusCode'] -and [int]$t.StatusCode -eq 404) { return $true }
        return $false
    }
}

# ============================================================================
# Action: delete a test run (cascades to its linked results/outcomes)
# ============================================================================
function Remove-TestRun {
    param([int]$TargetRunId)

    $runUri = "$ProjectUri/runs/$TargetRunId"
    try {
        # --- 1. Fetch the run ------------------------------------------------
        $run = Invoke-AdoRest -Method Get -Uri "$runUri`?api-version=$ApiVersion"
        Write-Host ""
        Write-Host "Run:   #$($run.id) '$($run.name)' (state: $($run.state))"
        if ($run.webAccessUrl) { Write-Host "URL:   $($run.webAccessUrl)" }

        # --- 2. Fetch linked results (paged) ---------------------------------
        $results = New-Object System.Collections.Generic.List[object]
        $skip = 0; $top = 1000
        while ($true) {
            $page = Invoke-AdoRest -Method Get -Uri "$runUri/results?api-version=$ApiVersion&`$top=$top&`$skip=$skip"
            if (-not $page.value) { break }
            $results.AddRange($page.value)
            if ($page.value.Count -lt $top) { break }
            $skip += $top
        }
        Write-Host "Linked test results/outcomes: $($results.Count)"
        if ($results.Count -gt 0) {
            $results | Group-Object outcome | ForEach-Object {
                Write-Host ("  {0,-20} {1}" -f $_.Name, $_.Count)
            }
        }

        # --- 3. Confirm and delete the run ------------------------------------
        $target = "test run #$TargetRunId with $($results.Count) linked result(s)"
        if ($Force -or $PSCmdlet.ShouldProcess($target, 'Delete')) {
            $null = Invoke-AdoRest -Method Delete -Uri "$runUri`?api-version=$ApiVersion"
            Write-Host "Delete request sent." -ForegroundColor Green

            # --- 4. Verify nothing is left dangling -----------------------------
            if (Test-Gone "$runUri`?api-version=$ApiVersion") {
                Write-Host "Verified: run #$TargetRunId no longer exists (404)." -ForegroundColor Green
            } else {
                Write-Warning "Run still resolvable after delete; it may be marked for deletion and disappear shortly."
            }
            if (Test-Gone "$runUri/results?api-version=$ApiVersion") {
                Write-Host "Verified: no resolvable results remain (404)." -ForegroundColor Green
            } else {
                Write-Warning "Results endpoint still resolvable after delete; re-check in a moment."
            }
        }
        else {
            if ($WhatIfPreference) { Write-Host "WhatIf: nothing was deleted." }
            else { Write-Host "Cancelled. Nothing was deleted." -ForegroundColor Yellow }
        }
    }
    catch {
        $t = $_.TargetObject
        if ($t -and $t.PSObject.Properties['StatusCode']) {
            $code = [int]$t.StatusCode
            if ($code -eq 404) { Write-Error "Run #$TargetRunId not found (404) in $Organization/$Project." }
            elseif ($code -eq 401) { Write-Error "Unauthorized (401). Check the PAT and its Test (read & write) scope." }
            elseif ($code -eq 403) { Write-Error "Forbidden (403). The PAT lacks access: check the Test (read & write) scope and your permissions on $Organization/$Project." }
            elseif ($code -eq 0) { Write-Error "No HTTP response from Azure DevOps (connectivity/DNS/TLS). $($t.Message)" }
            else { Write-Error "Azure DevOps returned HTTP $code. $($t.Message)" }
        }
        else { Write-Error $_ }
    }
}

# ============================================================================
# Action: list all test runs and save them to a CSV file
# ============================================================================
function Export-TestRuns {
    $allRuns = New-Object System.Collections.Generic.List[object]
    $skip = 0; $top = 1000
    while ($true) {
        $page = Invoke-AdoRest -Method Get -Uri "$ProjectUri/runs?api-version=$ApiVersion&`$top=$top&`$skip=$skip"
        if (-not $page.value) { break }
        $allRuns.AddRange($page.value)
        if ($page.value.Count -lt $top) { break }
        $skip += $top
    }

    Write-Host ""
    Write-Host "Found $($allRuns.Count) test run(s) in $Organization/$Project."

    if ($allRuns.Count -eq 0) { return }

    # CSV export with the useful columns
    $csv = $allRuns | Select-Object `
        id, name, state, outcome, planId, isAutomated,
        @{n = 'startedDate'; e = { $_.startedDate } },
        @{n = 'completedDate'; e = { $_.completedDate } },
        @{n = 'createdDate'; e = { $_.createdDate } },
        @{n = 'totalTests'; e = { $_.totalTests } },
        @{n = 'passedTests'; e = { $_.passedTests } },
        @{n = 'failedTests'; e = { $_.failedTests } },
        @{n = 'webAccessUrl'; e = { $_.webAccessUrl } }

    if (-not $OutputPath) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $OutputPath = Join-Path (Get-Location) "testruns-$stamp.csv"
    }
    $csv | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
    Write-Host "Saved run list to: $OutputPath" -ForegroundColor Green

    # Short console preview
    Write-Host ""
    Write-Host "Preview (latest first):"
    $csv | Sort-Object id -Descending |
        Select-Object -First 10 @{n = 'Run'; e = { "  #$($_.id) $($_.name) [$($_.state)]" }} |
        ForEach-Object { Write-Host $_.Run }
}

# ============================================================================
# Non-interactive mode
# ============================================================================
if ($RunId -gt 0) {
    Remove-TestRun -TargetRunId $RunId
    return
}
if ($ListRuns) {
    Export-TestRuns
    return
}

# ============================================================================
# Interactive menu
# ============================================================================
Write-Host "=========================================="
Write-Host " Azure DevOps Test Run Tool"
Write-Host "   Organization: $Organization"
Write-Host "   Project:      $Project"
Write-Host "=========================================="
:menu while ($true) {
    Write-Host ""
    Write-Host "  [1] Delete a test run (incl. linked outcomes)"
    Write-Host "  [2] List all test runs and save to file"
    Write-Host "  [Q] Quit"
    $choice = (Read-Host "Choose an action").Trim()

    switch ($choice.ToUpper()) {
        '1' {
            $input = (Read-Host "Enter the test run ID to delete").Trim()
            $targetId = 0
            if (-not [int]::TryParse($input, [ref]$targetId)) {
                Write-Host "'$input' is not a valid run ID." -ForegroundColor Red
                continue
            }
            Remove-TestRun -TargetRunId $targetId
        }
        '2' { Export-TestRuns }
        'Q' { break menu }
        default { Write-Host "Invalid choice." -ForegroundColor Red }
    }
}
Write-Host "Bye."
