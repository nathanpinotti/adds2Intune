# Run-FullMigration.ps1
# Orquestrador da migracao ADDS -> Entra ID (copia de perfil).
# Executa: (0) Pre-Flight, (1) Backup de perfil, (2) Unjoin + agendamentos + reboot.
# Os Steps 3, 4 e 5 sao executados automaticamente apos os reboots.
# Compativel com Windows PowerShell 5.1.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\MigrationConfig.json",
    [string]$TargetUPN,
    [System.Management.Automation.PSCredential]$DomainCredential,
    [switch]$PromptDomainCredential
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

function Invoke-Step {
    # Execucao no mesmo processo: necessario para o DPAPI (Step 0 -> Step 2)
    # e para repassar objetos PSCredential.
    param([string]$ScriptPath, [hashtable]$Params = @{})
    Write-Host ""
    Write-Host ("[ORCHESTRATOR] Executando: {0}" -f $ScriptPath) -ForegroundColor Magenta

    $global:LASTEXITCODE = 0
    & $ScriptPath @Params
    $code = $LASTEXITCODE

    if ($code -ne 0) {
        Write-Host ("[ORCHESTRATOR] FALHA em {0} (ExitCode: {1})" -f $ScriptPath, $code) -ForegroundColor Red
        exit $code
    }
    Write-Host ("[ORCHESTRATOR] OK: {0}" -f $ScriptPath) -ForegroundColor Green
}

Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "   ADDS -> ENTRA ID MIGRATION (COPY PROFILE)      " -ForegroundColor Cyan
Write-Host "==================================================" -ForegroundColor Cyan

$ConfigPath = (Resolve-Path $ConfigPath).Path
$config     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$migRegPath = "HKLM:\SOFTWARE\MigrationTool"
if (-not (Test-Path $migRegPath)) { New-Item -Path $migRegPath -Force | Out-Null }
Set-ItemProperty -Path $migRegPath -Name "LogPath"    -Value $config.LogPath
Set-ItemProperty -Path $migRegPath -Name "ScriptRoot" -Value $scriptRoot

if (-not $DomainCredential -and $PromptDomainCredential) {
    $DomainCredential = Get-Credential -Message "Credencial de dominio para o unjoin (DOMINIO\usuario)"
}

# STEP 0: Pre-Flight
Invoke-Step -ScriptPath (Join-Path $scriptRoot "0_PreFlight.ps1") -Params @{ ConfigPath = $ConfigPath }

$loggedPath = Join-Path $config.LogPath "loggeduser.txt"
$sourceUser = if (Test-Path $loggedPath) { (Get-Content $loggedPath -Raw).Trim() }
              else { (Get-CimInstance -ClassName Win32_ComputerSystem).UserName }
Write-Host ""
Write-Host ("Usuario de ORIGEM: {0}" -f $sourceUser) -ForegroundColor Cyan

# STEP 0.5: UPN de destino
if (-not $TargetUPN) {
    $TargetUPN = Read-Host "UPN Entra ID de destino (ex: usuario@contoso.com)"
}
if ([string]::IsNullOrWhiteSpace($TargetUPN) -or ($TargetUPN -notlike "*@*.*")) {
    Write-Host "UPN invalido. Abortando." -ForegroundColor Red
    exit 1
}
$TargetUPN = $TargetUPN.Trim()
Set-ItemProperty -Path $migRegPath -Name "ExpectedUPN" -Value $TargetUPN
Write-Host ("UPN de DESTINO : {0}" -f $TargetUPN) -ForegroundColor Cyan

# STEP 1: Backup de perfil
Invoke-Step -ScriptPath (Join-Path $scriptRoot "1_BackupProfile.ps1") -Params @{ ConfigPath = $ConfigPath }

# STEP 2: Unjoin + reboot
$unjoinParams = @{ ConfigPath = $ConfigPath }
if ($DomainCredential) { $unjoinParams["DomainCredential"] = $DomainCredential }

Write-Host ""
Write-Host "[ORCHESTRATOR] Proximo passo: saida do dominio e reboot. Os Steps 3-5 seguem automaticamente." -ForegroundColor Yellow
Invoke-Step -ScriptPath (Join-Path $scriptRoot "2_UnjoinDomain.ps1") -Params $unjoinParams
