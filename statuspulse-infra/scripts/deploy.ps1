<#
.SYNOPSIS
    Deploys StatusPulse CloudFormation stacks locally using the AWS CLI.

.DESCRIPTION
    Calls "aws cloudformation deploy" for one or all stacks in dependency order.
    Reads parameter files from cloudformation/parameters/<environment>/.

    Stack deployment order (respects cross-stack dependencies):
      dynamodb → sns → sqs-fifo → api-gateway

.PARAMETER Environment
    Target environment: dev, qa, or prod. Defaults to dev.

.PARAMETER Stack
    Specific stack to deploy: dynamodb, sns, sqs-fifo, api-gateway.
    Omit (or pass blank string) to deploy all stacks in order.

.PARAMETER Region
    AWS region. Defaults to us-east-1.

.EXAMPLE
    # Deploy all dev stacks
    pwsh scripts/deploy.ps1 -Environment dev

    # Deploy only the DynamoDB stack to qa
    pwsh scripts/deploy.ps1 -Environment qa -Stack dynamodb

    # Deploy to prod (requires AWS credentials for the prod role)
    pwsh scripts/deploy.ps1 -Environment prod
#>

param(
    [ValidateSet("dev", "qa", "prod")]
    [string]$Environment = "dev",

    [ValidateSet("", "dynamodb", "sns", "sqs-fifo", "api-gateway")]
    [string]$Stack = "",

    [string]$Region = "us-east-1"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve paths relative to this script's location
$scriptDir    = $PSScriptRoot
$projectRoot  = Split-Path $scriptDir -Parent
$templatesDir = Join-Path $projectRoot "cloudformation" "templates"
$paramsDir    = Join-Path $projectRoot "cloudformation" "parameters" $Environment

# Verify aws CLI is available
if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
    Write-Error "aws CLI not found. Install from https://aws.amazon.com/cli/"
    exit 1
}

# Stack definitions in deployment order
$allStacks = @(
    @{ Name = "dynamodb";    Template = "dynamodb.yml";    Params = "dynamodb.json" }
    @{ Name = "sns";         Template = "sns.yml";         Params = "sns.json"      }
    @{ Name = "sqs-fifo";    Template = "sqs-fifo.yml";    Params = "sqs-fifo.json" }
    @{ Name = "api-gateway"; Template = "api-gateway.yml"; Params = "api-gateway.json" }
)

# Filter to a single stack if requested
$stacksToDeploy = if ($Stack -ne "") {
    $allStacks | Where-Object { $_.Name -eq $Stack }
} else {
    $allStacks
}

if ($stacksToDeploy.Count -eq 0) {
    Write-Error "Unknown stack: '$Stack'"
    exit 1
}

Write-Host "`n=== StatusPulse Deploy ==="
Write-Host "  Environment : $Environment"
Write-Host "  Region      : $Region"
Write-Host "  Stacks      : $($stacksToDeploy.Name -join ', ')"
Write-Host ""

foreach ($s in $stacksToDeploy) {
    $stackName    = "statuspulse-$Environment-$($s.Name)"
    $templateFile = Join-Path $templatesDir $s.Template
    $paramsFile   = Join-Path $paramsDir    $s.Params

    if (-not (Test-Path $templateFile)) {
        Write-Error "Template not found: $templateFile"
        exit 1
    }
    if (-not (Test-Path $paramsFile)) {
        Write-Error "Parameter file not found: $paramsFile"
        exit 1
    }

    Write-Host "--- Deploying $stackName ---"

    aws cloudformation deploy `
        --stack-name      $stackName `
        --template-file   $templateFile `
        --parameter-overrides "file://$paramsFile" `
        --capabilities    CAPABILITY_NAMED_IAM `
        --no-fail-on-empty-changeset `
        --region          $Region

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Deploy failed for stack: $stackName"
        exit 1
    }

    Write-Host "  $stackName deployed successfully."

    # Show outputs for the deployed stack
    Write-Host "  Outputs:"
    aws cloudformation describe-stacks `
        --stack-name $stackName `
        --region $Region `
        --query "Stacks[0].Outputs" `
        --output table 2>$null | ForEach-Object { "    $_" }

    Write-Host ""
}

Write-Host "=== All stacks deployed successfully ==="
