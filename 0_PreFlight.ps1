# 0_PreFlight.ps1
# Valida pre-requisitos, suspende BitLocker em C: e cria o usuario de
# recuperacao MigRecovery com SENHA RANDOMICA POR MAQUINA, exibida UMA VEZ.
# Compativel com Windows PowerShell 5.1.
# Execute como: Administrador Local (mesma sessao do orquestrador).

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

function Test-TcpPort {
    # Substitui Test-NetConnection: timeout controlado, sem ICMP/DNS extra.
    param([string]$HostName, [int]$Port = 443, [int]$TimeoutMs = 3000)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $client.BeginConnect($HostName, $Port, $null, $null)
        $ok    = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $client.Connected) { return $true }
        return $false
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-IntuneEnrollment {
    $intuneRegPath = "HKLM:\SOFTWARE\Microsoft\Enrollments"
    if (Test-Path $intuneRegPath) {
        $enrollments = Get-ChildItem $intuneRegPath -ErrorAction SilentlyContinue |
            Where-Object {
                $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                $props.EnrollmentType -eq 6 -or
                $props.DiscoveryServiceFullURL -like "*manage.microsoft.com*"
            }
        return ($null -ne $enrollments -and @($enrollments).Count -gt 0)
    }
    return $false
}

function Get-DSRegStatus {
    $dsreg  = dsregcmd /status 2>&1
    $status = @{}
    foreach ($line in $dsreg) {
        if ($line -match "^\s+(\w[\w\s]+?)\s*:\s*(.+)$") {
            $status[$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $status
}

function Get-LocalAdminGroupName {
    # Resolucao por SID well-known: independe do idioma do SO.
    try {
        $sid = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        return ($sid.Translate([System.Security.Principal.NTAccount]).Value -split "\\")[-1]
    } catch { return "Administrators" }
}

function New-RandomPassword {
    param([int]$Length = 16)
    # RNG criptografico, garantindo as 4 classes de caracteres.
    $lower   = "abcdefghijkmnopqrstuvwxyz"
    $upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ"
    $digits  = "23456789"
    $symbols = "!@#$%*-_=+"
    $all     = $lower + $upper + $digits + $symbols

    $rng   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 4

    function Get-RandomChar([string]$set) {
        $rng.GetBytes($bytes)
        $idx = [BitConverter]::ToUInt32($bytes, 0) % $set.Length
        return $set[$idx]
    }

    $chars = @(
        (Get-RandomChar $lower),
        (Get-RandomChar $upper),
        (Get-RandomChar $digits),
        (Get-RandomChar $symbols)
    )
    for ($i = $chars.Count; $i -lt $Length; $i++) {
        $chars += (Get-RandomChar $all)
    }
    $shuffled = $chars | Sort-Object { $rng.GetBytes($bytes); [BitConverter]::ToUInt32($bytes, 0) }
    $rng.Dispose()
    return (-join $shuffled)
}

$config  = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$logDir  = $config.LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = "$logDir\PreFlight_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

$localAdminGroup = Get-LocalAdminGroupName
Write-Log "====== INICIANDO PRE-FLIGHT CHECK ======"
Write-Log ("Maquina: {0} | Usuario logado: {1}" -f $env:COMPUTERNAME, $env:USERNAME)
Write-Log ("Grupo de administradores detectado: {0}" -f $localAdminGroup)

$results   = @{}
$allPassed = $true

# 1) SO
Write-Log "Verificando versao do SO..."
$os          = Get-CimInstance Win32_OperatingSystem
$buildNumber = [int]($os.BuildNumber)
if ($buildNumber -ge 19041) {
    Write-Log ("SO OK: {0} - Build {1}" -f $os.Caption, $buildNumber)
    $results["OS"] = "PASS"
} else {
    Write-Log "SO incompativel. Minimo: Windows 10 20H1 (Build 19041)" "ERROR"
    $results["OS"] = "FAIL"
    $allPassed     = $false
}

# 2) AD / Entra
Write-Log "Verificando estado de dominio/Entra..."
$dsreg = Get-DSRegStatus
if ($dsreg["DomainJoined"] -eq "YES") {
    Write-Log ("OK: Maquina ingressada no dominio: {0}" -f $dsreg["DomainName"])
    $results["DomainJoined"] = "PASS"
} else {
    Write-Log "AVISO: Maquina NAO esta ingressada em dominio ADDS." "WARN"
    $results["DomainJoined"] = "WARN"
}
if ($dsreg["AzureAdJoined"] -eq "YES") {
    Write-Log "ATENCAO: Maquina JA esta AzureAdJoined (Entra). Abortando fluxo ADDS->Entra." "ERROR"
    $results["AzureAdJoined"] = "FAIL - JA ENTRA"
    $allPassed = $false
} else {
    $results["AzureAdJoined"] = "PASS"
}

# 3) Intune
Write-Log "Verificando enrollment no Intune..."
if (Test-IntuneEnrollment) {
    Write-Log "ATENCAO: Esta maquina JA ESTA ENROLLADA no Intune!" "WARN"
    $results["IntuneAlreadyEnrolled"] = "WARN - JA ENROLLADA"
} else {
    Write-Log "OK: Maquina nao esta enrollada no Intune (esperado)."
    $results["IntuneAlreadyEnrolled"] = "PASS"
}

# 4) Conectividade
Write-Log "Testando conectividade com servicos Microsoft..."
$endpoints = @(
    "login.microsoftonline.com",
    "device.login.microsoftonline.com",
    "enrollment.manage.microsoft.com",
    "enterpriseregistration.windows.net"
)
$connFail = $false
foreach ($ep in $endpoints) {
    if (Test-TcpPort -HostName $ep -Port 443) {
        Write-Log ("  CONECTADO: {0}:443" -f $ep)
    } else {
        Write-Log ("  FALHA: {0}:443" -f $ep) "ERROR"
        $connFail = $true
    }
}
$results["Connectivity"] = if ($connFail) { $allPassed = $false; "FAIL" } else { "PASS" }

# 5) Disco
Write-Log "Verificando espaco em disco..."
$disk   = Get-PSDrive -Name C
$freeGB = [math]::Round($disk.Free / 1GB, 2)
if ($freeGB -ge 2) {
    Write-Log ("OK: Espaco livre em C: {0} GB" -f $freeGB)
    $results["DiskSpace"] = "PASS"
} else {
    Write-Log ("FALHA: Espaco insuficiente ({0} GB). Minimo: 2 GB" -f $freeGB) "ERROR"
    $results["DiskSpace"] = "FAIL"
    $allPassed = $false
}

# 6) Usuario logado
Write-Log "Identificando usuario ativo..."
$loggedUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ($loggedUser) {
    Write-Log ("OK: Usuario logado: {0}" -f $loggedUser)
    $results["LoggedUser"] = "PASS - $loggedUser"
    $loggedUser | Out-File "$logDir\loggeduser.txt" -Force
} else {
    Write-Log "AVISO: Nenhum usuario interativo detectado" "WARN"
    $results["LoggedUser"] = "WARN"
}

# 7) TPM
Write-Log "Verificando TPM..."
try {
    $tpm = Get-Tpm
    if ($tpm.TpmPresent -and $tpm.TpmReady) {
        Write-Log "OK: TPM presente e pronto."
        $results["TPM"] = "PASS"
    } else {
        Write-Log "AVISO: TPM nao esta pronto." "WARN"
        $results["TPM"] = "WARN"
    }
} catch {
    Write-Log "AVISO: Nao foi possivel verificar TPM." "WARN"
    $results["TPM"] = "WARN"
}

# 8) PPKG (bulk enrollment)
if ($config.PSObject.Properties["PPKGPath"] -and $config.PPKGPath) {
    $ppkgFull = if ([System.IO.Path]::IsPathRooted($config.PPKGPath)) { $config.PPKGPath }
                else { Join-Path $PSScriptRoot $config.PPKGPath }
    if (Test-Path $ppkgFull) {
        Write-Log ("OK: PPKG de bulk enrollment encontrado: {0}" -f $ppkgFull)
        $results["PPKG"] = "PASS"
    } else {
        Write-Log ("AVISO: PPKGPath configurado mas arquivo nao encontrado: {0}. Join usara o fluxo manual." -f $ppkgFull) "WARN"
        $results["PPKG"] = "WARN - Arquivo ausente"
    }
} else {
    Write-Log "PPKG nao configurado. Join usara o fluxo manual (JoinGuide)." "WARN"
    $results["PPKG"] = "WARN - Nao configurado"
}

# 9) BitLocker - suspende C: por 5 reboots
Write-Log "Verificando BitLocker no volume C:..."
try {
    Import-Module BitLocker -ErrorAction SilentlyContinue
    $vols  = Get-BitLockerVolume -ErrorAction Stop
    $osVol = $vols | Where-Object { $_.VolumeType -eq "OperatingSystem" -or $_.MountPoint -eq "C:" } | Select-Object -First 1

    if ($osVol) {
        Write-Log ("BitLocker - Volume: {0} | ProtectionStatus: {1}" -f $osVol.MountPoint, $osVol.ProtectionStatus)
        if ($osVol.ProtectionStatus -eq "On") {
            Write-Log "Suspendendo BitLocker em C: por 5 reboots..."
            Suspend-BitLocker -MountPoint $osVol.MountPoint -RebootCount 5 -ErrorAction Stop | Out-Null
            Write-Log "BitLocker suspenso (5 reboots)."
            $results["BitLocker"] = "PASS - Suspenso 5 reboots"
        } else {
            Write-Log "BitLocker DESATIVADO em C:. Nada a fazer."
            $results["BitLocker"] = "PASS - Off"
        }
    } else {
        Write-Log "Nenhum volume de SO identificado no BitLocker." "WARN"
        $results["BitLocker"] = "WARN - Sem volume SO"
    }
} catch {
    Write-Log ("Aviso: nao foi possivel consultar/suspender BitLocker: {0}" -f $_.Exception.Message) "WARN"
    $results["BitLocker"] = "WARN - Erro ao consultar"
}

# 10) MigRecovery com senha randomica (exibida uma vez, nunca registrada em log)
Write-Log "Criando usuario de recuperacao 'MigRecovery' com senha randomica..."
try {
    $recoveryUser = "MigRecovery"
    $recoveryPass = New-RandomPassword -Length 16
    $secPass      = ConvertTo-SecureString $recoveryPass -AsPlainText -Force

    $existingUser = Get-LocalUser -Name $recoveryUser -ErrorAction SilentlyContinue
    if (-not $existingUser) {
        New-LocalUser -Name $recoveryUser `
                      -Password $secPass `
                      -FullName "Migration Recovery" `
                      -Description "Conta local temporaria para recuperacao da migracao." `
                      -PasswordNeverExpires `
                      -UserMayNotChangePassword | Out-Null
        Write-Log ("Usuario '{0}' criado." -f $recoveryUser)
    } else {
        Set-LocalUser    -Name $recoveryUser -Password $secPass -PasswordNeverExpires $true -ErrorAction SilentlyContinue
        Enable-LocalUser -Name $recoveryUser -ErrorAction SilentlyContinue
        Write-Log ("Usuario '{0}' ja existia. Senha rotacionada." -f $recoveryUser)
    }

    Add-LocalGroupMember -Group $localAdminGroup -Member $recoveryUser -ErrorAction SilentlyContinue
    Write-Log ("Usuario '{0}' garantido no grupo '{1}'." -f $recoveryUser, $localAdminGroup)

    # Persistida com DPAPI (escopo do usuario atual) para uso no Step 2 (autologon).
    $migRegPath = "HKLM:\SOFTWARE\MigrationTool"
    if (-not (Test-Path $migRegPath)) { New-Item -Path $migRegPath -Force | Out-Null }
    $protected = $secPass | ConvertFrom-SecureString
    Set-ItemProperty -Path $migRegPath -Name "RecoveryUser"      -Value $recoveryUser
    Set-ItemProperty -Path $migRegPath -Name "RecoveryPassDPAPI" -Value $protected

    Write-Host ""
    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host "   CREDENCIAL DE RECUPERACAO - ANOTE AGORA (EXIBIDA UMA UNICA VEZ)" -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host ("   Usuario : {0}" -f $recoveryUser) -ForegroundColor Yellow
    Write-Host ("   Senha   : {0}" -f $recoveryPass) -ForegroundColor Yellow
    Write-Host "------------------------------------------------------------------" -ForegroundColor Yellow
    Write-Host "   Use apenas se o logon apos o Reboot 1 falhar."                   -ForegroundColor Yellow
    Write-Host "   Senha unica desta maquina; a conta e removida no cleanup."       -ForegroundColor Yellow
    Write-Host "==================================================================" -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Pressione ENTER apos anotar a credencial para continuar" | Out-Null

    $results["MigRecovery"] = "PASS - Criado com senha randomica"
} catch {
    Write-Log ("ERRO ao criar/configurar MigRecovery: {0}" -f $_.Exception.Message) "ERROR"
    $results["MigRecovery"] = "FAIL"
    $allPassed = $false
}

# Resultado
Write-Log ""
Write-Log "====== RESULTADO DO PRE-FLIGHT ======"
foreach ($item in $results.GetEnumerator()) {
    $val   = $item.Value
    $key   = $item.Key
    $color = "Green"
    if ($val -like "FAIL*") { $color = "Red" }
    elseif ($val -like "WARN*") { $color = "Yellow" }
    Write-Host ("  {0} : {1}" -f $key.PadRight(30), $val) -ForegroundColor $color
    Add-Content -Path $logFile -Value ("{0} : {1}" -f $key, $val) -Encoding UTF8
}

if ($allPassed) {
    Write-Log "====== PRE-FLIGHT APROVADO. ======"
    exit 0
} else {
    Write-Log "====== PRE-FLIGHT COM FALHAS CRITICAS. Corrija antes de continuar. ======" "ERROR"
    exit 1
}
