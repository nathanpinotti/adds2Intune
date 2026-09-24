# 2_UnjoinDomain.ps1
# Remove a maquina do dominio AD, cria o JoinGuide na pasta Startup (VBS, sem janela),
# agenda as tasks (Step 3 AtStartup / Step 4 AtLogOn), configura o Legal Notice e o
# autologon do MigRecovery e reinicia.
# Compativel com Windows PowerShell 5.1.

#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [string]$ConfigPath = "$PSScriptRoot\MigrationConfig.json",
    [System.Management.Automation.PSCredential]$DomainCredential,
    [switch]$SkipUnjoin
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

function Invoke-DomainUnjoin {
    param([System.Management.Automation.PSCredential]$Credential)

    Write-Log "Tentativa 1: Remove-Computer..."
    try {
        if ($Credential) {
            Remove-Computer -UnjoinDomainCredential $Credential -WorkgroupName "WORKGROUP" -Force -ErrorAction Stop
        } else {
            Remove-Computer -WorkgroupName "WORKGROUP" -Force -ErrorAction Stop
        }
        Write-Log "Remove-Computer executado com sucesso."
        return $true
    }
    catch {
        Write-Log ("Remove-Computer falhou: {0}" -f $_.Exception.Message) "WARN"
    }

    Write-Log "Tentativa 2: CIM UnjoinDomainOrWorkgroup..."
    try {
        $cs      = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $cimArgs = @{ FUnjoinOptions = [uint32]0 }
        if ($Credential) {
            $cimArgs["UserName"] = $Credential.UserName
            $cimArgs["Password"] = $Credential.GetNetworkCredential().Password
        }
        $result = Invoke-CimMethod -InputObject $cs -MethodName UnjoinDomainOrWorkgroup -Arguments $cimArgs
        if ($result.ReturnValue -eq 0) {
            Write-Log "CIM UnjoinDomainOrWorkgroup executado com sucesso."
            return $true
        } else {
            Write-Log ("CIM retornou codigo: {0}" -f $result.ReturnValue) "WARN"
        }
    }
    catch {
        Write-Log ("CIM UnjoinDomainOrWorkgroup falhou: {0}" -f $_.Exception.Message) "WARN"
    }

    return $false
}

# --- INICIO ---

$config     = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$logDir     = $config.LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile    = "$logDir\UnjoinDomain_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
$scriptRoot = Split-Path -Parent (Resolve-Path $ConfigPath).Path

Write-Log "====== INICIO DO UNJOIN DO DOMINIO ======"
Write-Log ("Maquina: {0} | ScriptRoot: {1}" -f $env:COMPUTERNAME, $scriptRoot)

$migRegPath   = "HKLM:\SOFTWARE\MigrationTool"
$migReg       = Get-ItemProperty $migRegPath -ErrorAction SilentlyContinue
$expectedUPN  = $migReg.ExpectedUPN
$recoveryUser = $migReg.RecoveryUser

if (-not $expectedUPN) {
    Write-Log "ExpectedUPN ausente no registro. Execute os Steps 0 e 1 antes." "ERROR"
    exit 1
}

Set-ItemProperty -Path $migRegPath -Name "ScriptRoot" -Value $scriptRoot

# Caminho do PPKG (opcional) persistido para o Step 3
if ($config.PSObject.Properties["PPKGPath"] -and $config.PPKGPath) {
    $ppkgFull = if ([System.IO.Path]::IsPathRooted($config.PPKGPath)) { $config.PPKGPath }
                else { Join-Path $scriptRoot $config.PPKGPath }
    Set-ItemProperty -Path $migRegPath -Name "PPKGPath" -Value $ppkgFull
    Write-Log ("PPKGPath persistido: {0}" -f $ppkgFull)
}

# 1) Conta MigRecovery e senha (DPAPI - mesma sessao do Pre-Flight)
$recoveryOk   = $false
$recoveryPass = $null
if ($recoveryUser) {
    $localUser = Get-LocalUser -Name $recoveryUser -ErrorAction SilentlyContinue
    if ($localUser -and $localUser.Enabled) {
        Write-Log ("Conta de recuperacao '{0}' existe e esta habilitada." -f $recoveryUser)
        $recoveryOk = $true
    } else {
        Write-Log ("ATENCAO: Conta '{0}' nao encontrada ou desabilitada!" -f $recoveryUser) "WARN"
    }

    if ($migReg.RecoveryPassDPAPI) {
        try {
            $secPass      = $migReg.RecoveryPassDPAPI | ConvertTo-SecureString
            $bstr         = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secPass)
            $recoveryPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            Write-Log "Senha do MigRecovery recuperada via DPAPI."
        } catch {
            Write-Log ("Falha ao decifrar senha DPAPI (sessao diferente do Pre-Flight?): {0}" -f $_.Exception.Message) "WARN"
        }
    }
} else {
    Write-Log "ATENCAO: RecoveryUser nao encontrado no registro." "WARN"
}
if (-not $recoveryOk) {
    Write-Log "Conta de recuperacao indisponivel. Prosseguindo com risco de lockout." "WARN"
}

# 2) Legal Notice
$winlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
Set-ItemProperty -Path $winlogonPath -Name "LegalNoticeCaption" -Value "MIGRACAO EM ANDAMENTO"
Set-ItemProperty -Path $winlogonPath -Name "LegalNoticeText" `
    -Value ("Esta maquina esta em processo de migracao para Entra ID.`n`nAPENAS o usuario '{0}' deve realizar o login apos a migracao concluir.`n`nSe voce nao e esse usuario, NAO faca login e contate o suporte de TI." -f $expectedUPN)
Write-Log ("Legal Notice configurado. Usuario esperado: {0}" -f $expectedUPN)

# 3) Renomear (opcional)
if ($config.RenameComputer -and $config.NewComputerNamePrefix) {
    $suffix  = -join ((65..90) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
    $newName = "{0}{1}" -f $config.NewComputerNamePrefix, $suffix
    Write-Log ("Renomeando maquina para: {0}" -f $newName)
    Rename-Computer -NewName $newName -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $migRegPath -Name "NewComputerName" -Value $newName
}

# 4) JoinGuide na pasta Startup (fallback manual)
Write-Log "Criando JoinGuide na pasta Startup..."

$guidePs1Path  = "$logDir\JoinGuide.ps1"
$startupFolder = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\StartUp"
$guideVbsPath  = Join-Path $startupFolder "MIG_JoinGuide.vbs"
Set-ItemProperty -Path $migRegPath -Name "JoinGuideVbs" -Value $guideVbsPath

$guidePs1Content = @"
Add-Type -AssemblyName System.Windows.Forms

`$dsreg  = dsregcmd /status 2>&1
`$joined = `$dsreg | Where-Object { `$_ -match "AzureAdJoined\s*:\s*YES" }
if (`$joined) { exit 0 }

`$upn = '$expectedUPN'

`$msg  = "MIGRACAO ENTRA ID - ACAO NECESSARIA``r``n``r``n"
`$msg += "Esta maquina esta pronta para ingressar no Entra ID.``r``n``r``n"
`$msg += "SIGA OS PASSOS ABAIXO:``r``n``r``n"
`$msg += "1. Clique em OK nesta janela.``r``n``r``n"
`$msg += "2. A tela 'Acessar trabalho ou escola' sera aberta.``r``n``r``n"
`$msg += "3. Clique em 'Conectar'.``r``n``r``n"
`$msg += "4. Clique em 'Ingressar este dispositivo no Microsoft Entra ID'.``r``n``r``n"
`$msg += "5. Entre com a conta:``r``n"
`$msg += "   `$upn``r``n``r``n"
`$msg += "6. Siga as instrucoes na tela.``r``n``r``n"
`$msg += "7. O computador reiniciara automaticamente ao concluir."

[System.Windows.Forms.MessageBox]::Show(
    `$msg,
    "MIGRACAO - ACAO NECESSARIA",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
) | Out-Null

Start-Process "ms-settings:workplace"
"@

$guidePs1Content | Out-File $guidePs1Path -Encoding UTF8 -Force

$guideVbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File """ & "$guidePs1Path" & """", 0, False
"@
$guideVbsContent | Out-File $guideVbsPath -Encoding ASCII -Force

Write-Log ("JoinGuide.ps1: {0}" -f $guidePs1Path)
Write-Log ("JoinGuide.vbs: {0}" -f $guideVbsPath)

# 5) Scheduled tasks (SYSTEM)
# Step 3 AtStartup: o join roda antes de qualquer logon, sem depender do autologon.
$action3   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"{0}`"" -f (Join-Path $scriptRoot "3_EntraJoin.ps1"))
$trigger3  = New-ScheduledTaskTrigger -AtStartup
$settings3 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 1)
$princ3    = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "MIG_Step3_EntraJoin" -Action $action3 `
    -Trigger $trigger3 -Settings $settings3 -Principal $princ3 `
    -Description "Migration Step 3: Entra ID join (PPKG) + prep" -Force | Out-Null
Write-Log "Task MIG_Step3_EntraJoin registrada (AtStartup / SYSTEM)."

$action4   = New-ScheduledTaskAction -Execute "powershell.exe" `
    -Argument ("-ExecutionPolicy Bypass -NonInteractive -WindowStyle Hidden -File `"{0}`"" -f (Join-Path $scriptRoot "4_CopyProfileData.ps1"))
$trigger4  = New-ScheduledTaskTrigger -AtLogOn
$settings4 = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
$princ4    = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

Register-ScheduledTask -TaskName "MIG_Step4_ProfileMigration" -Action $action4 `
    -Trigger $trigger4 -Settings $settings4 -Principal $princ4 `
    -Description "Migration Step 4: Copy Profile Data" -Force | Out-Null
Write-Log "Task MIG_Step4_ProfileMigration registrada (AtLogOn / SYSTEM)."

# 6) Saida do dominio
if (-not $SkipUnjoin) {
    Write-Log "Iniciando saida do dominio ADDS..."
    $unjoinOk = Invoke-DomainUnjoin -Credential $DomainCredential
    if (-not $unjoinOk) {
        Write-Log "ERRO CRITICO: Nao foi possivel sair do dominio. Abortando." "ERROR"
        Unregister-ScheduledTask -TaskName "MIG_Step3_EntraJoin"        -Confirm:$false -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName "MIG_Step4_ProfileMigration" -Confirm:$false -ErrorAction SilentlyContinue
        Remove-Item $guideVbsPath -Force -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Log "Maquina removida do dominio com sucesso."
} else {
    Write-Log "UNJOIN PULADO (-SkipUnjoin)." "WARN"
}

Set-ItemProperty -Path $migRegPath -Name "MigrationState" -Value "UNJOINED_PENDING_REBOOT1"

# 7) Autologon do MigRecovery (Reboot 1)
if ($recoveryPass) {
    Write-Log "Configurando autologon do MigRecovery para o Reboot 1..."
    Set-ItemProperty -Path $winlogonPath -Name "AutoAdminLogon"    -Value "1"
    Set-ItemProperty -Path $winlogonPath -Name "DefaultUserName"   -Value $recoveryUser
    Set-ItemProperty -Path $winlogonPath -Name "DefaultPassword"   -Value $recoveryPass
    Set-ItemProperty -Path $winlogonPath -Name "DefaultDomainName" -Value "."
    Set-ItemProperty -Path $winlogonPath -Name "AutoLogonCount"    -Value 1 -Type DWord
    Write-Log "Autologon configurado (1 logon)."
} else {
    Write-Log "Senha do MigRecovery indisponivel. Autologon NAO configurado; use a credencial exibida no Pre-Flight." "WARN"
}

# 8) Reboot
Write-Log ("Reiniciando em {0} segundos..." -f $config.RebootDelaySeconds)
Start-Sleep -Seconds $config.RebootDelaySeconds
Restart-Computer -Force
exit 0
