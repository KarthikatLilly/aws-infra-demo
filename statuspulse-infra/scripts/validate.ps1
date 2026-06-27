<#
.SYNOPSIS
    Validates all StatusPulse CloudFormation templates locally.

.DESCRIPTION
    Runs three validation passes against cloudformation/templates/*.yml:
      1. aws cloudformation validate-template (requires configured AWS credentials)
      2. cfn-lint (Python; pip install cfn-lint)
      3. cfn-nag (Ruby; gem install cfn-nag)

    Call this before pushing to avoid a failed PR check.

.EXAMPLE
    pwsh scripts/validate.ps1
    pwsh scripts/validate.ps1 -Region eu-west-1
#>

param(
    [string]$Region = "us-east-1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve the templates directory relative to this script's location
$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$templatesDir = Join-Path $projectRoot "cloudformation" "templates"

$templates = Get-ChildItem -Path $templatesDir -Filter "*.yml" | Sort-Object Name

if ($templates.Count -eq 0) {
    Write-Error "No .yml templates found in $templatesDir"
    exit 1
}

Write-Host "`n=== Templates to validate ==="
$templates | ForEach-Object { Write-Host "  $($_.Name)" }

# ---------------------------------------------------------------------------
# Pass 1 — aws cloudformation validate-template
# ---------------------------------------------------------------------------
Write-Host "`n=== Pass 1: aws cloudformation validate-template ==="

$awsAvailable = $null -ne (Get-Command aws -ErrorAction SilentlyContinue)
if (-not $awsAvailable) {
    Write-Warning "aws CLI not found — skipping aws cloudformation validate-template"
} else {
    $pass1Failed = @()
    foreach ($tpl in $templates) {
        Write-Host "  --> $($tpl.Name)"
        $result = aws cloudformation validate-template `
            --template-body "file://$($tpl.FullName)" `
            --region $Region 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "    FAILED: $result"
            $pass1Failed += $tpl.Name
        } else {
            Write-Host "    OK"
        }
    }
    if ($pass1Failed.Count -gt 0) {
        Write-Warning "Pass 1 failures: $($pass1Failed -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Pass 2 — cfn-lint
# ---------------------------------------------------------------------------
Write-Host "`n=== Pass 2: cfn-lint ==="

$cfnLintAvailable = $null -ne (Get-Command cfn-lint -ErrorAction SilentlyContinue)
if (-not $cfnLintAvailable) {
    Write-Warning "cfn-lint not found — install with: pip install cfn-lint"
} else {
    $templatePaths = $templates | ForEach-Object { $_.FullName }
    cfn-lint @templatePaths
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  cfn-lint: all templates passed"
    } else {
        Write-Warning "  cfn-lint reported issues (exit code $LASTEXITCODE)"
    }
}

# ---------------------------------------------------------------------------
# Pass 3 — cfn-nag
# ---------------------------------------------------------------------------
Write-Host "`n=== Pass 3: cfn-nag ==="

$cfnNagAvailable = $null -ne (Get-Command cfn_nag_scan -ErrorAction SilentlyContinue)
if (-not $cfnNagAvailable) {
    Write-Warning "cfn-nag not found — install with: gem install cfn-nag"
} else {
    cfn_nag_scan --input-path $templatesDir --template-pattern ".*.yml"
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  cfn-nag: all templates passed"
    } else {
        Write-Warning "  cfn-nag reported issues (exit code $LASTEXITCODE)"
    }
}

Write-Host "`n=== Validation complete ==="
