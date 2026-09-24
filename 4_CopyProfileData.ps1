# 4_CopyProfileData.ps1
# Executado como SYSTEM (task AtLogOn), sem interface grafica.
# Valida que o usuario Entra logado corresponde ao ExpectedUPN registrado no
# inicio do processo, copia os dados do perfil antigo e chama o 5_Cleanup.ps1.
# Notificacoes ao usuario via msg.exe (best-effort).
# Compativel com Windows PowerShell 5.1.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$migRegPath = "HKLM:\SOFTWARE\MigrationTool"
$migReg     = Get-ItemProperty $migRegPath -ErrorAction SilentlyContinue
$logDir     = if ($migReg -and $migReg.LogPath) { $migReg.LogPath } else { Join-Path $env:SystemDrive "MigrationLogs" }
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = "$logDir\CopyProfile_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param([string]$Message,[string]$Level="INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -Path $script:logFile -Value "[$timestamp][$Level] $Message" -Encoding UTF8
}

function Send-UserNotification {
    # msg.exe entrega a mensagem na sessao interativa a partir do contexto SYSTEM.
    param([string]$Text)
    try {
        $msgExe = Join-Path $env:WinDir "System32\msg.exe"
        if (Test-Path $msgExe) { & $msgExe * /TIME:60 $Text 2>&1 | Out-Null }
    } catch { }
}

function Get-UpnFromSid {
    # Resolve o UPN de um usuario Entra a partir do SID (IdentityStore cache).
    param([string]$Sid)
    $cacheBase = "HKLM:\SOFTWARE\Microsoft\IdentityStore\Cache"
    $key = Get-ChildItem $cacheBase -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -eq $Sid } |
        Select-Object -First 1
    if ($key) {
        $props = Get-ItemProperty $key.PSPath -ErrorAction SilentlyContinue
        foreach ($candidate in @("UserName","SAMName","Identity")) {
            if ($props.PSObject.Properties[$candidate] -and $props.$candidate -like "*@*") {
                return [string]$props.$candidate
            }
        }
    }
    return $null
}

Write-Log "====== INICIO: COPIA DE DADOS DE PERFIL ======"

# 1) Usuario interativo
try {
    $interactiveUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
} catch {
    Write-Log ("Erro ao ler usuario interativo: {0}" -f $_.Exception.Message) "ERROR"
    exit 1
}
Write-Log ("Usuario interativo: {0}" -f $interactiveUser)

if (-not $interactiveUser) {
    Write-Log "Nenhum usuario interativo detectado. Aguardando proximo logon." "WARN"
    exit 0
}
if ($interactiveUser -notlike "AzureAD\*") {
    Write-Log ("Usuario '{0}' nao e Entra ID. Aguardando logon do usuario Entra." -f $interactiveUser)
    exit 0
}

# 2) Dados da migracao
if (-not $migReg) {
    Write-Log "Chave HKLM:\SOFTWARE\MigrationTool ausente." "ERROR"
    Send-UserNotification "MIGRACAO: dados de migracao ausentes. Contate o suporte de TI."
    exit 1
}

$oldProfile  = $migReg.ProfilePath
$scriptRoot  = if ($migReg.ScriptRoot) { $migReg.ScriptRoot } else { $PSScriptRoot }
$expectedUPN = $migReg.ExpectedUPN

if (-not $oldProfile -or -not (Test-Path $oldProfile)) {
    Write-Log ("Perfil antigo invalido ou inexistente: {0}" -f $oldProfile) "ERROR"
    Send-UserNotification "MIGRACAO: perfil de origem nao encontrado. Contate o suporte de TI."
    exit 1
}

# 3) SID do usuario Entra
try {
    $account = New-Object System.Security.Principal.NTAccount($interactiveUser)
    $userSID = $account.Translate([System.Security.Principal.SecurityIdentifier]).Value
    Write-Log ("SID do usuario Entra: {0}" -f $userSID)
} catch {
    Write-Log ("Falha ao traduzir '{0}' para SID: {1}" -f $interactiveUser, $_.Exception.Message) "ERROR"
    exit 1
}

# 4) Validacao de identidade: UPN do usuario logado x ExpectedUPN
if (-not $expectedUPN -or $expectedUPN -notlike "*@*") {
    Write-Log "ExpectedUPN invalido ou ausente. Copia abortada." "ERROR"
    Send-UserNotification "MIGRACAO: usuario esperado nao configurado. Contate o suporte de TI."
    exit 1
}

$loggedUPN = Get-UpnFromSid -Sid $userSID
Write-Log ("UPN do usuario logado: {0} | ExpectedUPN: {1}" -f $loggedUPN, $expectedUPN)

if (-not $loggedUPN) {
    Write-Log "UPN do usuario logado nao resolvido via IdentityStore. Copia abortada." "ERROR"
    Send-UserNotification ("MIGRACAO: nao foi possivel verificar sua identidade. Logon esperado: {0}. Contate o suporte de TI." -f $expectedUPN)
    exit 1
}

if ($loggedUPN -ne $expectedUPN) {
    Write-Log ("USUARIO DIVERGENTE. Logado: '{0}' | Esperado: '{1}'. Copia NAO executada." -f $loggedUPN, $expectedUPN) "ERROR"
    Send-UserNotification ("MIGRACAO: este computador esta reservado para {0}. Faca logoff e contate o suporte de TI." -f $expectedUPN)
    exit 1
}
Write-Log "Validacao de identidade OK."

# 5) Perfil novo
$newProfileKey = Join-Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList" $userSID
if (-not (Test-Path $newProfileKey)) {
    Write-Log ("ProfileList nao contem entrada para SID {0}" -f $userSID) "ERROR"
    exit 1
}
$newProfile = (Get-ItemProperty $newProfileKey -ErrorAction Stop).ProfileImagePath

# 6) Protecoes
if ($newProfile -match "\\TEMP$") {
    Write-Log ("Perfil TEMP detectado: {0}. Copia abortada." -f $newProfile) "ERROR"
    Send-UserNotification "MIGRACAO: seu perfil atual e temporario. A copia foi adiada. Contate o suporte de TI."
    exit 1
}
if (-not $newProfile -or -not (Test-Path $newProfile)) {
    Write-Log ("Perfil novo invalido: {0}" -f $newProfile) "ERROR"
    exit 1
}

Write-Log ("Perfil antigo (AD)   : {0}" -f $oldProfile)
Write-Log ("Perfil novo  (Entra) : {0}" -f $newProfile)

if ($oldProfile.TrimEnd('\') -ieq $newProfile.TrimEnd('\')) {
    Write-Log "Caminhos antigo e novo sao iguais. Nada a copiar." "WARN"
    Unregister-ScheduledTask -TaskName "MIG_Step4_ProfileMigration" -Confirm:$false -ErrorAction SilentlyContinue
    exit 0
}

Set-ItemProperty -Path $migRegPath -Name "EntraSID"     -Value $userSID
Set-ItemProperty -Path $migRegPath -Name "EntraUserUPN" -Value $loggedUPN

Send-UserNotification "MIGRACAO: copiando seus arquivos para o novo perfil. Nao desligue o computador."

# 7) Copia (robocopy)
$folders = @("Desktop","Documents","Downloads","Favorites","Pictures","Videos","Music","Links")

$roboLog  = "$logDir\Robocopy_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$copiados = 0
$falhas   = 0
$index    = 0

foreach ($f in $folders) {
    $index++
    $src = Join-Path $oldProfile $f
    $dst = Join-Path $newProfile $f

    if (-not (Test-Path $src)) {
        Write-Log ("[{0}/{1}] Pasta nao encontrada (ignorada): {2}" -f $index, $folders.Count, $src)
        continue
    }

    Write-Log ("[{0}/{1}] Copiando {2} -> {3}" -f $index, $folders.Count, $src, $dst)
    if (-not (Test-Path $dst)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }

    robocopy "$src" "$dst" /E /XJ /COPY:DAT /R:1 /W:1 /NP "/LOG+:$roboLog" | Out-Null
    $rc = $LASTEXITCODE

    if ($rc -ge 8) {
        Write-Log ("FALHA robocopy em '{0}' (exit code {1})." -f $f, $rc) "ERROR"
        $falhas++
    } else {
        Write-Log ("OK: '{0}' (robocopy exit code {1})." -f $f, $rc)
        $copiados++
    }
}

Write-Log ("Copia concluida. {0} pasta(s) copiada(s), {1} com falha." -f $copiados, $falhas)

if ($falhas -gt 0) {
    Write-Log "Falhas de copia. Cleanup NAO executado; perfil antigo preservado." "ERROR"
    Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "COPY_FAILED"
    Send-UserNotification ("MIGRACAO: {0} pasta(s) copiada(s), {1} com falha. Seus dados antigos estao preservados. Contate o suporte de TI." -f $copiados, $falhas)
    exit 1
}

Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "COPY_DONE"
Unregister-ScheduledTask -TaskName "MIG_Step4_ProfileMigration" -Confirm:$false -ErrorAction SilentlyContinue
Write-Log "Task MIG_Step4_ProfileMigration removida."

# 8) Cleanup
$cleanupScript = Join-Path $scriptRoot "5_Cleanup.ps1"
if (Test-Path $cleanupScript) {
    Write-Log ("Iniciando cleanup: {0}" -f $cleanupScript)
    & $cleanupScript
} else {
    Write-Log ("Script de cleanup nao encontrado: {0}" -f $cleanupScript) "WARN"
}

Write-Log "====== COPIA DE DADOS CONCLUIDA ======"
exit 0
