# 1_BackupProfile.ps1
# Captura o SID do usuario de dominio, salva mapeamento e ACLs do perfil.
# Compativel com Windows PowerShell 5.1.
# Execute como: Administrador Local.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\MigrationConfig.json"
)

$ErrorActionPreference = "Stop"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line      = "[$timestamp][$Level] $Message"
    $color     = "Cyan"
    if ($Level -eq "ERROR") { $color = "Red" }
    elseif ($Level -eq "WARN") { $color = "Yellow" }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $logFile -Value $line -Encoding UTF8
}

$config    = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$logDir    = $config.LogPath
$backupDir = $config.ProfileBackupPath
foreach ($d in @($logDir, $backupDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$logFile = "$logDir\BackupProfile_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

Write-Log "====== INICIO DO BACKUP DE PERFIL ======"

# 1) Usuario alvo
$loggedUserFile = "$logDir\loggeduser.txt"
$domainUser = if (Test-Path $loggedUserFile) {
    (Get-Content $loggedUserFile -Raw).Trim()
} else {
    (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
}
if (-not $domainUser) {
    Write-Log "Nenhum usuario identificado para mapeamento." "ERROR"
    exit 1
}
Write-Log ("Usuario alvo: {0}" -f $domainUser)

# 2) SID do usuario de dominio
try {
    $splitUser = $domainUser -split "\\"
    $domain    = $splitUser[0]
    $username  = $splitUser[1]
    $objUser   = New-Object System.Security.Principal.NTAccount($domain, $username)
    $sidObject = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
    $domainSID = $sidObject.Value
    Write-Log ("SID do usuario de dominio: {0}" -f $domainSID)
} catch {
    Write-Log ("Falha ao resolver SID do usuario '{0}': {1}" -f $domainUser, $_.Exception.Message) "ERROR"
    exit 1
}

# 3) Caminho do perfil (fonte de verdade: ProfileList por SID)
$regProfiles = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
$profileKey  = Get-ChildItem $regProfiles | Where-Object { $_.PSChildName -eq $domainSID }
if ($profileKey) {
    $profilePath = (Get-ItemProperty $profileKey.PSPath).ProfileImagePath
    Write-Log ("Perfil encontrado via ProfileList: {0}" -f $profilePath)
} else {
    $profilePath = Join-Path (Split-Path $env:PUBLIC -Parent) $username
    if (Test-Path $profilePath) {
        Write-Log ("Perfil assumido por convencao: {0}" -f $profilePath) "WARN"
    } else {
        Write-Log ("Perfil nao encontrado para SID {0}" -f $domainSID) "ERROR"
        exit 1
    }
}

# 4) Mapeamento em JSON
$mappingFile = "$backupDir\ProfileMapping.json"
@{
    Timestamp      = (Get-Date -Format "o")
    DomainUser     = $domainUser
    DomainSID      = $domainSID
    ProfilePath    = $profilePath
    ComputerName   = $env:COMPUTERNAME
    MigrationState = "BACKUP_DONE"
} | ConvertTo-Json -Depth 5 | Out-File $mappingFile -Encoding UTF8 -Force
Write-Log ("Mapeamento salvo em: {0}" -f $mappingFile)

# 5) ACLs do perfil
try {
    icacls "$profilePath" /save "$backupDir\ProfileACL.bin" /T /C 2>&1 | Out-Null
    Write-Log ("ACLs exportadas em: {0}" -f "$backupDir\ProfileACL.bin")
} catch {
    Write-Log ("Aviso: nao foi possivel exportar ACLs: {0}" -f $_.Exception.Message) "WARN"
}

# 6) ExpectedUPN
# Prioridade: (1) valor ja gravado pelo orquestrador, (2) UPN do AD, (3) EntraUPNSuffix do config.
$migRegPath = "HKLM:\SOFTWARE\MigrationTool"
if (-not (Test-Path $migRegPath)) { New-Item -Path $migRegPath -Force | Out-Null }
$existingExpectedUPN = (Get-ItemProperty $migRegPath -ErrorAction SilentlyContinue).ExpectedUPN

if ($existingExpectedUPN -and $existingExpectedUPN -like "*@*.*") {
    $expectedUPN = $existingExpectedUPN
    Write-Log ("ExpectedUPN definido pelo orquestrador: {0}" -f $expectedUPN)
} else {
    $adUPN = $null
    try {
        $adUser = ([adsisearcher]"(sAMAccountName=$username)").FindOne()
        if ($adUser -and $adUser.Properties["userprincipalname"].Count -gt 0) {
            $adUPN = [string]$adUser.Properties["userprincipalname"][0]
        }
    } catch { }

    if ($adUPN) {
        $expectedUPN = $adUPN
        Write-Log ("ExpectedUPN obtido do AD: {0}" -f $expectedUPN)
    } elseif ($config.PSObject.Properties["EntraUPNSuffix"] -and $config.EntraUPNSuffix) {
        $expectedUPN = "$username@$($config.EntraUPNSuffix)"
        Write-Log ("ExpectedUPN montado com EntraUPNSuffix: {0}" -f $expectedUPN) "WARN"
    } else {
        Write-Log "ExpectedUPN indeterminado. Informe o UPN pelo orquestrador ou configure EntraUPNSuffix." "ERROR"
        exit 1
    }
}

Set-ItemProperty -Path $migRegPath -Name "DomainSID"   -Value $domainSID
Set-ItemProperty -Path $migRegPath -Name "DomainUser"  -Value $domainUser
Set-ItemProperty -Path $migRegPath -Name "ProfilePath" -Value $profilePath
Set-ItemProperty -Path $migRegPath -Name "MappingFile" -Value $mappingFile
Set-ItemProperty -Path $migRegPath -Name "ScriptRoot"  -Value $PSScriptRoot
Set-ItemProperty -Path $migRegPath -Name "ExpectedUPN" -Value $expectedUPN
Set-ItemProperty -Path $migRegPath -Name "LogPath"     -Value $logDir

Write-Log "====== BACKUP DE PERFIL CONCLUIDO ======"
exit 0
