# 3_EntraJoin.ps1
# Executado como SYSTEM (AtStartup) apos o Reboot 1, antes de qualquer logon.
# Caminho primario: bulk enrollment via Provisioning Package (Entra join + Intune).
# Fallback: JoinGuide (pasta Startup) + ValidateJoin (task SYSTEM).
# Compativel com Windows PowerShell 5.1.

$ErrorActionPreference = "SilentlyContinue"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp][$Level] $Message" -Encoding UTF8
}

function Remove-AutoLogon {
    $wlPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $wlPath -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
    @("DefaultPassword","AutoLogonCount","DefaultDomainName","DefaultUserName") | ForEach-Object {
        Remove-ItemProperty -Path $wlPath -Name $_ -ErrorAction SilentlyContinue
    }
}

function Test-TcpPort {
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok    = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) { return $true }
        return $false
    } catch { return $false } finally { $client.Close() }
}

function Test-EntraJoined {
    $dsregLines = dsregcmd /status 2>&1
    return [bool]($dsregLines | Where-Object { $_ -match "AzureAdJoined\s*:\s*YES" })
}

function Get-EntraDeviceId {
    $dsregLines = dsregcmd /status 2>&1
    $line = $dsregLines | Where-Object { $_ -match "^\s*DeviceId\s*:" } | Select-Object -First 1
    if ($line) { return ($line -replace ".*DeviceId\s*:\s*", "").Trim() }
    return ""
}

function Complete-JoinSuccess {
    param([string]$Method)
    $deviceId = Get-EntraDeviceId
    Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "ENTRA_JOINED_PENDING_REBOOT2"
    Set-ItemProperty -Path $migRegPath -Name "EntraDeviceId"  -Value $deviceId
    Set-ItemProperty -Path $migRegPath -Name "JoinMethod"     -Value $Method

    if (Test-Path $startupVbs) {
        Remove-Item $startupVbs -Force -ErrorAction SilentlyContinue
        Write-Log "JoinGuide removido da Startup."
    }

    # Dispara o enrollment MDM (sem efeito se o PPKG ja realizou o enrollment)
    $enrollTask = Get-ScheduledTask -TaskName "Schedule #3 created by enrollment client" -ErrorAction SilentlyContinue
    if ($enrollTask) {
        $enrollTask | Start-ScheduledTask -ErrorAction SilentlyContinue
    } else {
        $enrollerPath = Join-Path $env:WinDir "System32\DeviceEnroller.exe"
        if (Test-Path $enrollerPath) {
            Start-Process $enrollerPath -ArgumentList "/o /c /h /x" -Wait -ErrorAction SilentlyContinue
        }
    }

    Unregister-ScheduledTask -TaskName "MIG_Step3_EntraJoin" -Confirm:$false -ErrorAction SilentlyContinue

    Write-Log "Removendo autologon do MigRecovery antes do Reboot 2..."
    Remove-AutoLogon

    Write-Log ("====== JOIN CONCLUIDO ({0}). Reiniciando (REBOOT 2)... ======" -f $Method)
    Start-Sleep -Seconds 30
    Restart-Computer -Force
}

# --- INICIO ---

$migRegPath = "HKLM:\SOFTWARE\MigrationTool"
$migReg     = Get-ItemProperty $migRegPath -ErrorAction SilentlyContinue
$logDir     = if ($migReg.LogPath) { $migReg.LogPath } else { Join-Path $env:SystemDrive "MigrationLogs" }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }

$logFile     = "$logDir\EntraJoin_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$expectedUPN = $migReg.ExpectedUPN
$ppkgPath    = $migReg.PPKGPath
$startupVbs  = if ($migReg.JoinGuideVbs) { $migReg.JoinGuideVbs }
               else { Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp\MIG_JoinGuide.vbs" }

Write-Log "====== INICIO: ENTRA ID JOIN (POS-REBOOT 1, AtStartup/SYSTEM) ======"
Write-Log ("Estado: {0} | UPN: {1} | PPKG: {2}" -f $migReg.MigrationState, $expectedUPN, $ppkgPath)

# Idempotencia
if (Test-EntraJoined) {
    Write-Log "Maquina ja esta AzureAdJoined. Finalizando etapa."
    Complete-JoinSuccess -Method "AlreadyJoined"
    return
}

# 1) Rede
Write-Log "Aguardando rede..."
$maxWait = 180
$waited  = 0
while (-not (Test-TcpPort -HostName "login.microsoftonline.com" -Port 443) -and $waited -lt $maxWait) {
    Start-Sleep -Seconds 5
    $waited += 5
    Write-Log ("Aguardando rede... ({0}/{1} s)" -f $waited, $maxWait)
}
if ($waited -ge $maxWait) {
    Write-Log "Timeout aguardando rede. A task sera executada novamente no proximo boot." "ERROR"
    exit 1
}
Write-Log "Rede disponivel."

# 2) Artefatos de join anterior
Write-Log "Limpando artefatos de join anterior..."
@(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CDJ",
    "HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo"
) | ForEach-Object {
    if (Test-Path $_) {
        Remove-Item $_ -Recurse -Force -ErrorAction SilentlyContinue
        Write-Log ("Removido: {0}" -f $_)
    }
}

# Somente certificados emitidos pela infraestrutura de device registration.
Get-ChildItem "Cert:\LocalMachine\My" -ErrorAction SilentlyContinue | Where-Object {
    $_.Issuer -like "*MS-Organization-Access*" -or
    $_.Issuer -like "*MS-Organization-P2P-Access*"
} | ForEach-Object {
    Write-Log ("Removendo certificado: Subject='{0}' Issuer='{1}'" -f $_.Subject, $_.Issuer)
    Remove-Item $_.PSPath -Force -ErrorAction SilentlyContinue
}

# 3) Servicos de MDM
@("dmwappushservice","DeviceManagementEnterpriseService") | ForEach-Object {
    $s = Get-Service -Name $_ -ErrorAction SilentlyContinue
    if ($s -and $s.Status -ne "Running") {
        Set-Service -Name $_ -StartupType Automatic
        Start-Service -Name $_ -ErrorAction SilentlyContinue
        Write-Log ("Servico '{0}' iniciado." -f $_)
    }
}

# 4) Caminho primario: Provisioning Package
if ($ppkgPath -and (Test-Path $ppkgPath)) {
    Write-Log ("Instalando Provisioning Package: {0}" -f $ppkgPath)
    try {
        Import-Module Provisioning -ErrorAction Stop
        $ppkgResult = Install-ProvisioningPackage -PackagePath $ppkgPath -QuietInstall -ForceInstall -ErrorAction Stop
        Write-Log ("Install-ProvisioningPackage: {0}" -f ($ppkgResult | Out-String).Trim())
    } catch {
        Write-Log ("Falha ao instalar PPKG: {0}" -f $_.Exception.Message) "ERROR"
    }

    Write-Log "Aguardando confirmacao do join via PPKG (ate 300 s)..."
    $ppkgWait = 0
    while (-not (Test-EntraJoined) -and $ppkgWait -lt 300) {
        Start-Sleep -Seconds 15
        $ppkgWait += 15
        Write-Log ("Aguardando join PPKG... ({0}/300 s)" -f $ppkgWait)
    }

    if (Test-EntraJoined) {
        Write-Log "Entra ID join via PPKG CONFIRMADO."
        Complete-JoinSuccess -Method "PPKG"
        return
    }
    Write-Log "PPKG nao concluiu o join no tempo esperado. Seguindo para o fluxo manual." "WARN"
} else {
    Write-Log "PPKG nao configurado/encontrado. Seguindo para o fluxo manual (JoinGuide)." "WARN"
}

# 5) Fallback: join conduzido pelo usuario
Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "ENTRA_JOIN_PENDING_USER_ACTION"
Set-ItemProperty -Path $migRegPath -Name "JoinMethod"     -Value "UserDriven"

# 6) ValidateJoin: monitora o join e reinicia ao confirmar
$validateScriptPath = "$logDir\ValidateJoin.ps1"

$validateContent = @'
$migRegPath = "HKLM:\SOFTWARE\MigrationTool"
$migReg     = Get-ItemProperty $migRegPath -ErrorAction SilentlyContinue
$logDir     = if ($migReg.LogPath) { $migReg.LogPath } else { Join-Path $env:SystemDrive "MigrationLogs" }
$logFile    = "$logDir\ValidateJoin_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$startupVbs = if ($migReg.JoinGuideVbs) { $migReg.JoinGuideVbs }
              else { Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp\MIG_JoinGuide.vbs" }

function Write-Log {
    param([string]$Message,[string]$Level="INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $logFile -Value "[$timestamp][$Level] $Message" -Encoding UTF8
}

function Remove-AutoLogon {
    $wlPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
    Set-ItemProperty -Path $wlPath -Name "AutoAdminLogon" -Value "0" -ErrorAction SilentlyContinue
    @("DefaultPassword","AutoLogonCount","DefaultDomainName","DefaultUserName") | ForEach-Object {
        Remove-ItemProperty -Path $wlPath -Name $_ -ErrorAction SilentlyContinue
    }
}

Write-Log "====== VALIDANDO JOIN POS ACAO DO USUARIO ======"
Remove-AutoLogon
Write-Log "Autologon removido."

$maxAttempts = 30
$attempts    = 0
$joined      = $false

while (-not $joined -and $attempts -lt $maxAttempts) {
    $attempts++
    Start-Sleep -Seconds 30

    $dsregLines    = dsregcmd /status 2>&1
    $azureAdJoined = $dsregLines | Where-Object { $_ -match "AzureAdJoined\s*:\s*YES" }

    if ($azureAdJoined) {
        Write-Log "AzureAdJoined: YES confirmado."
        $deviceId = ($dsregLines | Where-Object { $_ -match "^\s*DeviceId\s*:" } | Select-Object -First 1) `
                    -replace ".*DeviceId\s*:\s*", ""

        Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "ENTRA_JOINED_PENDING_REBOOT2"
        Set-ItemProperty -Path $migRegPath -Name "EntraDeviceId"  -Value ([string]$deviceId).Trim()

        if (Test-Path $startupVbs) {
            Remove-Item $startupVbs -Force -ErrorAction SilentlyContinue
            Write-Log "JoinGuide removido da Startup."
        }

        @("MIG_Step3_EntraJoin","MIG_Step3_ValidateJoin") | ForEach-Object {
            Unregister-ScheduledTask -TaskName $_ -Confirm:$false -ErrorAction SilentlyContinue
        }

        Write-Log "Reiniciando (REBOOT 2)..."
        Start-Sleep -Seconds 15
        Restart-Computer -Force
        $joined = $true
    } else {
        Write-Log ("Aguardando join... tentativa {0}/{1}" -f $attempts, $maxAttempts)
    }
}

if (-not $joined) {
    Write-Log "Timeout: join nao concluido em 15 minutos. A task sera executada novamente no proximo logon." "ERROR"
    Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "ENTRA_JOIN_TIMEOUT"
}
'@

$validateContent | Out-File $validateScriptPath -Encoding UTF8 -Force

$valAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"{0}`"" -f $validateScriptPath)
$valTrigger   = New-ScheduledTaskTrigger -AtLogOn
$valSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$valPrincipal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "MIG_Step3_ValidateJoin" -Action $valAction `
    -Trigger $valTrigger -Settings $valSettings -Principal $valPrincipal `
    -Description "Migration: validate Entra join every 30s" -Force | Out-Null
Write-Log "Task MIG_Step3_ValidateJoin registrada (AtLogOn / SYSTEM)."

Start-ScheduledTask -TaskName "MIG_Step3_ValidateJoin" -ErrorAction SilentlyContinue
Write-Log "Task MIG_Step3_ValidateJoin iniciada."

Unregister-ScheduledTask -TaskName "MIG_Step3_EntraJoin" -Confirm:$false -ErrorAction SilentlyContinue
Write-Log "====== AMBIENTE PREPARADO. JoinGuide via Startup; ValidateJoin em execucao. ======"
