# 5_Cleanup.ps1
# Remove tasks, JoinGuide, MigRecovery, Legal Notice e autologon; ajusta grupos
# locais do usuario Entra; remove a pasta de scripts; envia a chave BitLocker ao
# Entra ID, suspende o BitLocker por 5 reboots, notifica e reinicia.
# Executado como SYSTEM (chamado pelo Step 4).
# Compativel com Windows PowerShell 5.1.

$ErrorActionPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp][$Level] $Message" -Encoding UTF8
}

function Get-GroupNameBySid {
    param([string]$Sid, [string]$Fallback)
    try {
        $s = New-Object System.Security.Principal.SecurityIdentifier($Sid)
        return ($s.Translate([System.Security.Principal.NTAccount]).Value -split "\\")[-1]
    } catch { return $Fallback }
}

function Send-UserNotification {
    param([string]$Text)
    try {
        $msgExe = Join-Path $env:WinDir "System32\msg.exe"
        if (Test-Path $msgExe) { & $msgExe * /TIME:60 $Text 2>&1 | Out-Null }
    } catch { }
}

$migRegPath = "HKLM:\SOFTWARE\MigrationTool"
$migReg     = Get-ItemProperty $migRegPath -ErrorAction SilentlyContinue
$logDir     = if ($migReg -and $migReg.LogPath) { $migReg.LogPath } else { Join-Path $env:SystemDrive "MigrationLogs" }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = "$logDir\Cleanup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$localAdminGroup = Get-GroupNameBySid -Sid "S-1-5-32-544" -Fallback "Administrators"
$localUsersGroup = Get-GroupNameBySid -Sid "S-1-5-32-545" -Fallback "Users"
Write-Log "====== INICIANDO CLEANUP FINAL ======"
Write-Log ("Grupos locais: admins='{0}' users='{1}'" -f $localAdminGroup, $localUsersGroup)

# 1) Tasks de migracao
@("MIG_Step3_EntraJoin","MIG_Step3_ValidateJoin","MIG_Step4_ProfileMigration") | ForEach-Object {
    Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue
    Write-Log ("Task '{0}' removida." -f $_)
}

# 2) JoinGuide
$startupVbs = if ($migReg.JoinGuideVbs) { $migReg.JoinGuideVbs }
              else { Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp\MIG_JoinGuide.vbs" }
if (Test-Path $startupVbs) {
    Remove-Item $startupVbs -Force -ErrorAction SilentlyContinue
    Write-Log ("JoinGuide removido: {0}" -f $startupVbs)
}

# 3) Enrollment Intune
$intuneEnrolled = $false
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Enrollments") {
    $enrollments = Get-ChildItem "HKLM:\SOFTWARE\Microsoft\Enrollments" -ErrorAction SilentlyContinue |
        Where-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            $p.EnrollmentType -eq 6 -or $p.DiscoveryServiceFullURL -like "*manage.microsoft.com*"
        }
    $intuneEnrolled = ($null -ne $enrollments -and @($enrollments).Count -gt 0)
}
$intuneStatus = if ($intuneEnrolled) { "YES" } else { "PENDING" }
Set-ItemProperty -Path $migRegPath -Name "IntuneEnrolled" -Value $intuneStatus
Write-Log ("Intune enrollment: {0}" -f $intuneStatus)

# 4) Relatorio
$reportPath = "$logDir\MigrationReport.txt"
@"
===================================================
  RELATORIO DE MIGRACAO - ADDS -> ENTRA ID + INTUNE
  Data     : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  Maquina  : $env:COMPUTERNAME
  Usuario  : $($migReg.DomainUser)
  SID AD   : $($migReg.DomainSID)
  UPN      : $($migReg.EntraUserUPN)
  SID Entra: $($migReg.EntraSID)
  DeviceId : $($migReg.EntraDeviceId)
  Metodo   : $($migReg.JoinMethod)
  Perfil   : $($migReg.ProfilePath)
  Intune   : $intuneStatus
  Estado   : $($migReg.MigrationState)
===================================================
"@ | Out-File $reportPath -Encoding UTF8 -Force
Write-Log ("Relatorio salvo em: {0}" -f $reportPath)

# 5) Legal Notice e autologon
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogonPath -Name "LegalNoticeCaption" -Value ""
Set-ItemProperty -Path $winlogonPath -Name "LegalNoticeText"    -Value ""
Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon"     -Value "0"
@("DefaultUserName","DefaultDomainName","DefaultPassword","AutoLogonCount") |
    ForEach-Object { Remove-ItemProperty -Path $winlogonPath -Name $_ -ErrorAction SilentlyContinue }
Write-Log "Legal Notice e autologon removidos."

# 6) MigRecovery e perfil residual
$recoveryUser = $migReg.RecoveryUser
if ($recoveryUser) {
    $recSid = $null
    try {
        $recSid = (New-Object System.Security.Principal.NTAccount($recoveryUser)).Translate([System.Security.Principal.SecurityIdentifier]).Value
    } catch { }

    Remove-LocalUser -Name $recoveryUser -ErrorAction SilentlyContinue
    Write-Log ("Usuario '{0}' removido." -f $recoveryUser)

    if ($recSid) {
        $recProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$recSid'" -ErrorAction SilentlyContinue
        if ($recProfile -and -not $recProfile.Loaded) {
            Remove-CimInstance -InputObject $recProfile -ErrorAction SilentlyContinue
            Write-Log "Perfil residual do MigRecovery removido."
        }
    }
}
@("RecoveryUser","RecoveryPassDPAPI") | ForEach-Object {
    Remove-ItemProperty -Path $migRegPath -Name $_ -ErrorAction SilentlyContinue
}
Write-Log "Segredos de recuperacao removidos do registro."

# 7) Usuario Entra como usuario padrao
$expectedUPN = $migReg.ExpectedUPN
if ($expectedUPN) {
    $entraUser = "AzureAD\$expectedUPN"
    Remove-LocalGroupMember -Group $localAdminGroup -Member $entraUser -ErrorAction SilentlyContinue
    Write-Log ("'{0}' removido de '{1}' (se existia)." -f $entraUser, $localAdminGroup)

    $inUsers = Get-LocalGroupMember -Group $localUsersGroup -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -eq $entraUser }
    if (-not $inUsers) {
        Add-LocalGroupMember -Group $localUsersGroup -Member $entraUser -ErrorAction SilentlyContinue
        Write-Log ("'{0}' adicionado a '{1}'." -f $entraUser, $localUsersGroup)
    }
} else {
    Write-Log "ExpectedUPN ausente. Grupos do usuario Entra nao ajustados." "WARN"
}

# 8) Pasta de scripts
$migrationRoot = $migReg.ScriptRoot
if ($migrationRoot -and (Test-Path $migrationRoot)) {
    Remove-Item $migrationRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Log ("Pasta de scripts removida: {0}" -f $migrationRoot)
}

# 9) BitLocker
try {
    Import-Module BitLocker -ErrorAction SilentlyContinue
    $osVol = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($osVol.ProtectionStatus -eq "On") {
        $recoveryProtectors = $osVol.KeyProtector | Where-Object { $_.KeyProtectorType -eq "RecoveryPassword" }
        foreach ($p in $recoveryProtectors) {
            try {
                BackupToAAD-BitLockerKeyProtector -MountPoint $env:SystemDrive -KeyProtectorId $p.KeyProtectorId -ErrorAction Stop | Out-Null
                Write-Log ("Chave de recuperacao {0} enviada ao Entra ID." -f $p.KeyProtectorId)
            } catch {
                Write-Log ("Falha ao enviar chave {0} ao Entra ID: {1}" -f $p.KeyProtectorId, $_.Exception.Message) "WARN"
            }
        }
        Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 5 -ErrorAction SilentlyContinue | Out-Null
        Write-Log "BitLocker suspenso por 5 reboots."
    } else {
        Write-Log "BitLocker desativado. Nenhuma acao necessaria."
    }
} catch {
    Write-Log ("Nao foi possivel inspecionar o BitLocker: {0}" -f $_.Exception.Message) "WARN"
}

Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "COMPLETED"
Write-Log "====== CLEANUP CONCLUIDO ======"

# 10) Notificacao e reboot
Send-UserNotification ("MIGRACAO CONCLUIDA: {0} migrado para Entra ID. O computador reiniciara em 30 segundos." -f $env:COMPUTERNAME)
Start-Sleep -Seconds 30
Restart-Computer -Force
