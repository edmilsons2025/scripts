#Requires -Version 3.0
<#
.SYNOPSIS
  Coleta de diagnostico de campo - hardware, sistema, logs e bateria/BMS.
  Menu por tipo de coleta + opcao de coleta COMPLETA.
  Feita para rodar online (direto do GitHub) sem instalar nada.

.DESCRIPTION
  O script se adapta ao ambiente onde roda:

  - Windows ATIVO (caso normal): le o registro ao vivo, usa WMI e os event
    logs do proprio sistema em execucao.
  - Particao INATIVA / WinPE: detecta a instalacao do Windows que nao esta
    rodando, monta os hives de registro offline (reg load) e copia os logs
    de la.

  Coletas disponiveis (individuais ou todas de uma vez):
    * Event Logs (winevt)
    * Panther (logs de setup do Windows)
    * Boot logs + eventos criticos de desligamento/bugcheck
    * Dumps (minidump, MEMORY.DMP, LiveKernelReports, WER)
    * Registro (versao do Windows, servicos, ultimo shutdown)
    * Inventario de Hardware (BIOS, placa, CPU, RAM, discos+SMART, GPU,
      rede, TPM, Secure Boot, dispositivos com erro)
    * Bateria/BMS (capacidade projeto x cheia = desgaste, ciclos, quimica,
      status, powercfg battery-report, eventos de energia)
    * Drivers (DriverStore + driverquery no modo ao vivo)

  Ao final gera resumos em Markdown e um .zip da coleta.

.PARAMETER Destino
  Pasta onde a coleta sera gravada. Use SEMPRE um disco que persiste.
  Sem isso, ele usa a pasta atual - em WinPE costuma ser X:\ (disco RAM),
  que some no reboot.

.PARAMETER Tarefas
  Executa direto, sem menu, as coletas informadas. Aceita:
    Completa (ou Tudo), EventLogs, Panther, Boot, Dumps, Registro,
    Hardware, Bateria, Drivers
  Ex: -Tarefas Hardware,Bateria   |   -Tarefas Completa

.PARAMETER Auto
  Roda a coleta COMPLETA sem menu e sem perguntar nada. Atalho para
  -Tarefas Completa.

.PARAMETER SemZip
  Nao gera o .zip no final.

.NOTES
  --- EXECUCAO ONLINE, direto do GitHub (recomendado) ---
  Como precisa de MENU interativo, use o padrao scriptblock (NAO use
  "irm ... | iex", que consome o stdin do menu). ATENCAO: precisa do ';'
  (ou de uma quebra de linha) entre a atribuicao e o '&':

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $u = 'https://raw.githubusercontent.com/USUARIO/REPO/main/Coleta-Diagnostico.ps1'
    & ([scriptblock]::Create((irm $u)))

  Sem -Destino, o script escolhe sozinho o melhor disco (ignora o X:\ da
  RAM do WinPE). Se quiser forcar um destino:

    & ([scriptblock]::Create((irm $u))) -Destino 'E:\Coleta'

  Coleta completa, sem menu, direto:

    & ([scriptblock]::Create((irm $u))) -Auto

  --- EXECUCAO LOCAL (arquivo baixado) ---
    powershell -ExecutionPolicy Bypass -NoProfile -File .\Coleta-Diagnostico.ps1
#>

[CmdletBinding()]
param(
    [string]$Destino,
    [string[]]$Tarefas,
    [switch]$Auto,
    [switch]$SemZip
)

$ErrorActionPreference = 'Continue'
$DestinoFoiInformado = $PSBoundParameters.ContainsKey('Destino')
# Quando o script roda via irm/iex (sem arquivo em disco), MyCommand.Path e
# nulo - por isso so chamamos Split-Path se houver caminho, evitando o erro.
$ScriptRoot = $null
$ScriptPath = $MyInvocation.MyCommand.Path
if ($ScriptPath) { $ScriptRoot = Split-Path -Parent $ScriptPath }
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Se -Destino nao foi informado, ele e escolhido automaticamente mais adiante
# (funcao Selecionar-DestinoAuto), ja que em WinPE o ScriptRoot costuma ser
# X:\ (disco RAM, que some no reboot).

# Guarda o que ja foi coletado (para o resumo geral e o nome do zip).
$script:Dados      = [ordered]@{}
$script:Executadas = New-Object System.Collections.ArrayList
function Marcar {
    param([string]$Nome)
    if (-not $script:Executadas.Contains($Nome)) { [void]$script:Executadas.Add($Nome) }
}

# ============================================================
#  Helpers de saida / arquivos
# ============================================================
$script:LogFile = $null
$script:LogEnc  = New-Object System.Text.UTF8Encoding($false)

function Log {
    param([string]$Msg, [string]$Cor = 'Gray')
    $linha = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $linha -ForegroundColor $Cor
    if ($script:LogFile) {
        try { [System.IO.File]::AppendAllText($script:LogFile, ($linha + "`r`n"), $script:LogEnc) } catch {}
    }
}

# Wrapper seguro: roda um bloco, nunca derruba o script inteiro se falhar.
function Executar {
    param(
        [Parameter(Mandatory)][string]$Nome,
        [Parameter(Mandatory)][scriptblock]$Bloco,
        [switch]$Silencioso
    )
    try {
        $resultado = & $Bloco
        if (-not $Silencioso) { Log "[OK] $Nome" 'Green' }
        return $resultado
    } catch {
        Log "[FALHOU] $Nome -> $($_.Exception.Message)" 'Yellow'
        return $null
    }
}

function Salvar-Json {
    param($Objeto, [string]$Caminho)
    if ($null -eq $Objeto) { return }
    try { $Objeto | ConvertTo-Json -Depth 6 | Out-File -FilePath $Caminho -Encoding UTF8 } catch {}
}

function Salvar-Csv {
    param($Objeto, [string]$Caminho)
    if ($null -eq $Objeto) { return }
    try { $Objeto | Export-Csv -Path $Caminho -NoTypeInformation -Encoding UTF8 } catch {}
}

function Escrever-TabelaMd {
    param([Parameter(Mandatory)]$Campos, [string]$Titulo)
    $sb = New-Object System.Text.StringBuilder
    if ($Titulo) { [void]$sb.AppendLine("## $Titulo`n") }
    [void]$sb.AppendLine("| Campo | Valor |")
    [void]$sb.AppendLine("| --- | --- |")
    foreach ($k in $Campos.Keys) {
        $v = $Campos[$k]
        if ($null -eq $v -or $v -eq '') { $v = '-' }
        [void]$sb.AppendLine("| $k | $v |")
    }
    return $sb.ToString()
}

# ============================================================
#  Pastas e ambiente (inicializados sob demanda, uma vez so)
# ============================================================
$script:Pastas    = $null
$script:WinDrive  = $null
$script:IsWinPE   = $false
$script:ModoAoVivo= $false
$script:AmbienteOk= $false

# Escolhe automaticamente o melhor disco para gravar quando -Destino nao foi
# informado. Ignora X: (RAM do WinPE), testa gravacao de verdade e prefere
# midia removivel (pendrive) e depois o maior espaco livre.
function Selecionar-DestinoAuto {
    $cands = @()
    try {
        # DriveType: 2 = removivel (USB), 3 = disco fixo local
        $vols = Get-CimInstance Win32_LogicalDisk -ErrorAction Stop | Where-Object { $_.DriveType -eq 2 -or $_.DriveType -eq 3 }
        foreach ($v in $vols) {
            if ($v.DeviceID -eq 'X:') { continue }
            if (-not $v.FreeSpace) { continue }
            $cands += [PSCustomObject]@{ Letra = $v.DeviceID; Livre = [int64]$v.FreeSpace; Tipo = [int]$v.DriveType }
        }
    } catch {}

    # Ordena: removivel (USB) primeiro; depois maior espaco livre.
    $cands = $cands | Sort-Object @{ Expression = { if ($_.Tipo -eq 2) { 0 } else { 1 } } }, @{ Expression = { $_.Livre }; Descending = $true }

    foreach ($c in $cands) {
        # Precisa de pelo menos ~200 MB livres para valer a pena.
        if ($c.Livre -lt 200MB) { continue }
        $teste = Join-Path ($c.Letra + '\') ('._coleta_test_' + $Timestamp)
        try {
            New-Item -ItemType Directory -Path $teste -Force -ErrorAction Stop | Out-Null
            Remove-Item $teste -Recurse -Force -ErrorAction SilentlyContinue
            $gb = [math]::Round($c.Livre / 1GB, 1)
            $tipoTxt = if ($c.Tipo -eq 2) { 'USB/removivel' } else { 'disco local' }
            Log "Destino automatico: $($c.Letra) ($tipoTxt, $gb GB livres)" 'Green'
            return $c.Letra
        } catch { continue }
    }
    return $null
}

function Inicializar-Destino {
    if ($script:Pastas) { return }

    # Aviso se for gravar no disco RAM do WinPE (X:) sem -Destino explicito.
    $DriveDestino = $null
    try { $DriveDestino = (Split-Path -Qualifier $Destino -ErrorAction Stop) } catch {}
    if (-not $DestinoFoiInformado -and $DriveDestino -eq 'X:') {
        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "  ATENCAO: salvando em X:\ (disco RAM do WinPE)." -ForegroundColor Red
        Write-Host "  Isso SOME quando a maquina reiniciar ou desligar." -ForegroundColor Red
        Write-Host "  Use a opcao [D] do menu para escolher um disco que persiste (ex: D:\Coleta)." -ForegroundColor Red
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host ""
    }

    $script:Pastas = [ordered]@{
        Resumo    = Join-Path $Destino '00_Resumo'
        EventLogs = Join-Path $Destino '01_EventLogs'
        Panther   = Join-Path $Destino '02_Panther'
        Dumps     = Join-Path $Destino '03_Dumps_e_WER'
        Boot      = Join-Path $Destino '04_Boot'
        Registro  = Join-Path $Destino '05_Registro'
        Hardware  = Join-Path $Destino '06_Hardware'
        Bateria   = Join-Path $Destino '07_Bateria_BMS'
        Drivers   = Join-Path $Destino '08_Drivers'
        Bruto     = Join-Path $Destino '09_Dados_Brutos'
    }
    foreach ($p in $script:Pastas.Values) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    $script:LogFile = Join-Path $Destino 'coleta.log'
    Log "Destino: $Destino" 'Cyan'
}

function Detectar-Ambiente {
    if ($script:AmbienteOk) { return }
    Inicializar-Destino

    $RunningDrive = $env:SystemDrive   # 'C:' num Windows normal, 'X:' em WinPE
    $script:IsWinPE = $false
    try {
        $script:IsWinPE = ($RunningDrive -eq 'X:') -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')
    } catch {}

    Log "Detectando particao do Windows..." 'Cyan'
    $script:WinDrive = $null
    foreach ($letra in 67..90 | ForEach-Object { [char]$_ }) {
        $candidato = "$letra`:\Windows\System32\config\SYSTEM"
        if (Test-Path $candidato) { $script:WinDrive = "$letra`:"; break }
    }

    $script:ModoAoVivo = (-not $script:IsWinPE) -and $script:WinDrive -and ($script:WinDrive -eq $RunningDrive)

    if (-not $script:WinDrive) {
        Log "[ERRO] Particao do Windows nao encontrada. So o inventario de hardware/bateria funcionara." 'Red'
    } elseif ($script:ModoAoVivo) {
        Log "Windows em execucao detectado em $($script:WinDrive) (modo ao vivo)" 'Green'
    } else {
        Log "Windows encontrado em $($script:WinDrive) (modo offline / particao inativa)" 'Green'
    }
    $script:AmbienteOk = $true
}

# ============================================================
#  COLETAS (uma funcao por tipo)
# ============================================================

function Coletar-EventLogs {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[PULADO] Event Logs - Windows nao encontrado" 'Yellow'; return }
    Log ">> Coletando Event Logs..." 'Cyan'
    Executar "Copiar Event Logs (winevt)" {
        Copy-Item "$($script:WinDrive)\Windows\System32\winevt\Logs\*" $script:Pastas.EventLogs -Recurse -Force -ErrorAction Stop
    }
    Marcar 'EventLogs'
}

function Coletar-Panther {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[PULADO] Panther - Windows nao encontrado" 'Yellow'; return }
    Log ">> Coletando Panther (setup)..." 'Cyan'
    Executar "Copiar logs do Panther (setup)" {
        if (Test-Path "$($script:WinDrive)\Windows\Panther") {
            Copy-Item "$($script:WinDrive)\Windows\Panther\*" $script:Pastas.Panther -Recurse -Force -ErrorAction Stop
        }
    }
    Executar "Copiar UnattendGC" {
        if (Test-Path "$($script:WinDrive)\Windows\Panther\UnattendGC") {
            Copy-Item "$($script:WinDrive)\Windows\Panther\UnattendGC" (Join-Path $script:Pastas.Panther 'UnattendGC') -Recurse -Force -ErrorAction Stop
        }
    }
    Marcar 'Panther'
}

function Coletar-Boot {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[PULADO] Boot - Windows nao encontrado" 'Yellow'; return }
    Log ">> Coletando boot log + eventos criticos..." 'Cyan'
    Executar "Copiar ntbtlog.txt (boot log)" {
        if (Test-Path "$($script:WinDrive)\Windows\ntbtlog.txt") {
            Copy-Item "$($script:WinDrive)\Windows\ntbtlog.txt" $script:Pastas.Boot -Force -ErrorAction Stop
        }
    }
    Executar "Copiar SrtTrail.txt (reparo de inicializacao)" {
        $srt = "$($script:WinDrive)\Windows\System32\LogFiles\Srt\SrtTrail.txt"
        if (Test-Path $srt) { Copy-Item $srt $script:Pastas.Boot -Force -ErrorAction Stop }
    }

    # Minera eventos criticos do System.evtx (se ja foi copiado).
    $SystemEvtx = Join-Path $script:Pastas.EventLogs 'System.evtx'
    if (Test-Path $SystemEvtx) {
        $ev = Executar "Eventos de desligamento/bugcheck (41,1001,6008)" {
            Get-WinEvent -FilterHashtable @{ Path = $SystemEvtx; Id = 41,1001,6008 } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Sort-Object TimeCreated -Descending
        }
        if ($ev) {
            Salvar-Csv $ev (Join-Path $script:Pastas.Boot 'eventos_criticos_desligamento.csv')
            $script:Dados['nCriticos'] = ($ev | Measure-Object).Count
        }
    } else {
        Log "[INFO] System.evtx ainda nao copiado - rode 'Event Logs' antes para minerar eventos criticos." 'DarkGray'
    }
    Marcar 'Boot'
}

function Coletar-Dumps {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[PULADO] Dumps - Windows nao encontrado" 'Yellow'; return }
    Log ">> Coletando dumps e WER..." 'Cyan'
    Executar "Copiar Minidumps" {
        if (Test-Path "$($script:WinDrive)\Windows\Minidump") {
            Copy-Item "$($script:WinDrive)\Windows\Minidump\*" $script:Pastas.Dumps -Recurse -Force -ErrorAction Stop
        }
    }
    Executar "Copiar MEMORY.DMP (pode ser grande)" {
        if (Test-Path "$($script:WinDrive)\Windows\MEMORY.DMP") {
            Copy-Item "$($script:WinDrive)\Windows\MEMORY.DMP" $script:Pastas.Dumps -Force -ErrorAction Stop
        }
    }
    Executar "Copiar LiveKernelReports" {
        if (Test-Path "$($script:WinDrive)\Windows\LiveKernelReports") {
            Copy-Item "$($script:WinDrive)\Windows\LiveKernelReports" (Join-Path $script:Pastas.Dumps 'LiveKernelReports') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Executar "Copiar relatorios do WER (crashes de app/sistema)" {
        $werPaths = @(
            "$($script:WinDrive)\ProgramData\Microsoft\Windows\WER\ReportArchive",
            "$($script:WinDrive)\ProgramData\Microsoft\Windows\WER\ReportQueue"
        )
        foreach ($wp in $werPaths) {
            if (Test-Path $wp) {
                $destWer = Join-Path $script:Pastas.Dumps ("WER_" + (Split-Path $wp -Leaf))
                Copy-Item $wp $destWer -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Marcar 'Dumps'
}

function Coletar-Registro {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[PULADO] Registro - Windows nao encontrado" 'Yellow'; return }
    Log ">> Coletando registro (versao, servicos, shutdown)..." 'Cyan'

    $InfoWindowsInstalado = [ordered]@{}

    # Le versao/nome/shutdown/crash a partir de uma raiz de registro (ao vivo ou offline).
    $lerInfo = {
        param([string]$RaizSoftware, [string]$RaizSystemCS)
        try {
            $cv = Get-ItemProperty "$RaizSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            $InfoWindowsInstalado['Produto'] = $cv.ProductName
            $InfoWindowsInstalado['Versao'] = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
            $InfoWindowsInstalado['Build'] = "$($cv.CurrentBuild).$($cv.UBR)"
            $InfoWindowsInstalado['Instalado em'] = if ($cv.InstallDate) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$cv.InstallDate).LocalDateTime } else { '-' }
            $InfoWindowsInstalado['Dono registrado'] = $cv.RegisteredOwner
            Log "[OK] Ler versao do Windows" 'Green'
        } catch { Log "[FALHOU] Ler versao do Windows -> $($_.Exception.Message)" 'Yellow' }

        try {
            $cn = Get-ItemProperty "$RaizSystemCS\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue
            if ($cn) { $InfoWindowsInstalado['Nome do computador'] = $cn.ComputerName }
            $win = Get-ItemProperty "$RaizSystemCS\Control\Windows" -ErrorAction SilentlyContinue
            if ($win -and $win.ShutdownTime) {
                try {
                    $filetime = [BitConverter]::ToInt64([byte[]]$win.ShutdownTime, 0)
                    $InfoWindowsInstalado['Ultimo desligamento registrado'] = [DateTime]::FromFileTime($filetime)
                } catch {}
            }
            $cc = Get-ItemProperty "$RaizSystemCS\Control\CrashControl" -ErrorAction SilentlyContinue
            if ($cc) {
                $InfoWindowsInstalado['Dump de memoria habilitado'] = [bool]$cc.CrashDumpEnabled
                $InfoWindowsInstalado['Reinicio automatico apos crash'] = [bool]$cc.AutoReboot
            }
            Log "[OK] Ler nome do computador / ultimo shutdown / crash config" 'Green'
        } catch { Log "[FALHOU] Ler nome/shutdown/crash -> $($_.Exception.Message)" 'Yellow' }
    }

    if ($script:ModoAoVivo) {
        & $lerInfo 'HKLM:\SOFTWARE' 'HKLM:\SYSTEM\CurrentControlSet'
        Executar "Exportar servicos (Win32_Service)" {
            Get-CimInstance Win32_Service -ErrorAction Stop |
                Select-Object Name, DisplayName, State, StartMode, StartName, PathName |
                Export-Csv (Join-Path $script:Pastas.Registro 'servicos.csv') -NoTypeInformation -Encoding UTF8
        }
    } else {
        Log "Montando hives de registro offline..." 'Cyan'
        $hives = [ordered]@{
            'HKLM\VC_SYSTEM'   = "$($script:WinDrive)\Windows\System32\config\SYSTEM"
            'HKLM\VC_SOFTWARE' = "$($script:WinDrive)\Windows\System32\config\SOFTWARE"
        }
        $hivesMontados = @()
        foreach ($chave in $hives.Keys) {
            $arq = $hives[$chave]
            $ok = Executar "Montar $chave" {
                $saida = & reg load $chave $arq 2>&1
                if ($LASTEXITCODE -ne 0) { throw "reg load retornou $LASTEXITCODE ($saida)" }
                $true
            }
            if ($ok) { $hivesMontados += $chave }
        }

        $cs = 'ControlSet001'
        try {
            $sel = Get-ItemProperty 'HKLM:\VC_SYSTEM\Select' -ErrorAction Stop
            $cs = 'ControlSet{0:D3}' -f $sel.Current
        } catch {}
        $InfoWindowsInstalado['ControlSet atual'] = $cs

        & $lerInfo 'HKLM:\VC_SOFTWARE' "HKLM:\VC_SYSTEM\$cs"

        Executar "Exportar servicos (registro offline)" {
            Get-ChildItem "HKLM:\VC_SYSTEM\$cs\Services" -ErrorAction Stop |
                ForEach-Object {
                    $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
                    [PSCustomObject]@{
                        Servico   = $_.PSChildName
                        Start     = $p.Start
                        Tipo      = $p.Type
                        ImagePath = $p.ImagePath
                    }
                } | Export-Csv (Join-Path $script:Pastas.Registro 'servicos.csv') -NoTypeInformation -Encoding UTF8
        }

        foreach ($chave in $hivesMontados) {
            Executar "Desmontar $chave" {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                & reg unload $chave 2>&1 | Out-Null
            } -Silencioso | Out-Null
        }
    }

    if ($InfoWindowsInstalado.Count -gt 0) {
        Escrever-TabelaMd -Campos $InfoWindowsInstalado -Titulo 'Windows instalado' |
            Out-File (Join-Path $script:Pastas.Registro 'RESUMO_REGISTRO.md') -Encoding UTF8
        $script:Dados['InfoWindows'] = $InfoWindowsInstalado
    }
    Marcar 'Registro'
}

function Coletar-Hardware {
    Detectar-Ambiente
    Log ">> Coletando inventario de hardware..." 'Cyan'

    $CS   = Executar "Sistema (Win32_ComputerSystem)" { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
    $CSP  = Executar "Modelo/serial (Win32_ComputerSystemProduct)" { Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop }
    $BIOS = Executar "BIOS/UEFI" { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    $BB   = Executar "Placa-mae" { Get-CimInstance Win32_BaseBoard -ErrorAction Stop }
    $CPU  = Executar "Processador" { Get-CimInstance Win32_Processor -ErrorAction Stop }
    $MEM  = Executar "Memoria RAM (por pente)" { Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop }
    $DISK = Executar "Discos fisicos" { Get-CimInstance Win32_DiskDrive -ErrorAction Stop }
    $PART = Executar "Particoes" { Get-CimInstance Win32_DiskPartition -ErrorAction Stop }
    $VID  = Executar "Placa de video" { Get-CimInstance Win32_VideoController -ErrorAction Stop }
    $NET  = Executar "Adaptadores de rede" { Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.MACAddress } }
    $PNP_ERR = Executar "Dispositivos com erro" {
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
    }
    $TPM = Executar "TPM" { Get-Tpm -ErrorAction Stop }
    $SB  = Executar "Secure Boot" { Confirm-SecureBootUEFI -ErrorAction Stop }
    $SMART = Executar "Confiabilidade do armazenamento (SMART/NVMe)" {
        Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop
    }

    Salvar-Json $CS   (Join-Path $script:Pastas.Bruto 'computer_system.json')
    Salvar-Json $CSP  (Join-Path $script:Pastas.Bruto 'computer_system_product.json')
    Salvar-Json $BIOS (Join-Path $script:Pastas.Bruto 'bios.json')
    Salvar-Json $BB   (Join-Path $script:Pastas.Bruto 'baseboard.json')
    Salvar-Csv  $CPU  (Join-Path $script:Pastas.Bruto 'cpu.csv')
    Salvar-Csv  $MEM  (Join-Path $script:Pastas.Bruto 'memoria.csv')
    Salvar-Csv  $DISK (Join-Path $script:Pastas.Bruto 'discos.csv')
    Salvar-Csv  $PART (Join-Path $script:Pastas.Bruto 'particoes.csv')
    Salvar-Csv  $VID  (Join-Path $script:Pastas.Bruto 'video.csv')
    Salvar-Csv  $NET  (Join-Path $script:Pastas.Bruto 'rede.csv')
    Salvar-Csv  $PNP_ERR (Join-Path $script:Pastas.Bruto 'dispositivos_com_erro.csv')
    Salvar-Csv  $SMART (Join-Path $script:Pastas.Bruto 'smart_confiabilidade.csv')

    $RamTotalGB = if ($MEM) { [math]::Round(($MEM | Measure-Object Capacity -Sum).Sum / 1GB, 1) } else { $null }

    $ResumoHardware = [ordered]@{
        'Fabricante'           = $CS.Manufacturer
        'Modelo'               = $CS.Model
        'Numero de serie'      = $BIOS.SerialNumber
        'BIOS/UEFI versao'     = $BIOS.SMBIOSBIOSVersion
        'BIOS/UEFI data'       = $BIOS.ReleaseDate
        'Placa-mae'            = "$($BB.Manufacturer) $($BB.Product)"
        'CPU'                  = ($CPU | Select-Object -First 1).Name
        'Nucleos / threads'    = "$(($CPU | Measure-Object NumberOfCores -Sum).Sum) / $(($CPU | Measure-Object NumberOfLogicalProcessors -Sum).Sum)"
        'RAM total'            = "$RamTotalGB GB ($(($MEM | Measure-Object).Count) pente(s))"
        'Discos'               = ($DISK | ForEach-Object { "$($_.Model) ($([math]::Round($_.Size/1GB,0)) GB)" }) -join '; '
        'GPU'                  = ($VID | Select-Object -First 1).Name
        'TPM presente'         = if ($TPM) { $TPM.TpmPresent } else { '-' }
        'TPM pronto'           = if ($TPM) { $TPM.TpmReady } else { '-' }
        'Secure Boot ativo'    = if ($null -ne $SB) { $SB } else { '-' }
        'Dispositivos com erro'= if ($PNP_ERR) { ($PNP_ERR | Measure-Object).Count } else { 0 }
    }
    Escrever-TabelaMd -Campos $ResumoHardware -Titulo 'Inventario de Hardware' |
        Out-File (Join-Path $script:Pastas.Hardware 'RESUMO_HARDWARE.md') -Encoding UTF8

    if ($PNP_ERR) {
        $linhasErro = $PNP_ERR | ForEach-Object { "- **$($_.Name)** - codigo $($_.ConfigManagerErrorCode) ($($_.DeviceID))" }
        "## Dispositivos com erro no Gerenciador de Dispositivos`n`n$($linhasErro -join "`n")" |
            Out-File (Join-Path $script:Pastas.Hardware 'dispositivos_com_erro.md') -Encoding UTF8
    }

    $script:Dados['CS'] = $CS
    $script:Dados['BIOS'] = $BIOS
    $script:Dados['DISK'] = $DISK
    $script:Dados['PNP_ERR'] = $PNP_ERR
    Marcar 'Hardware'
}

# Roda o powercfg protegido por timeout. Um powercfg que trava e sintoma
# classico de barramento I2C/SMBus travado no controlador da bateria.
# Retorna 'OK', 'TIMEOUT' ou 'ERRO'.
function Invoke-PowercfgSeguro {
    param([string]$Args, [int]$TimeoutSeg = 30)
    try {
        $p = Start-Process -FilePath 'powercfg' -ArgumentList $Args -PassThru -WindowStyle Hidden -ErrorAction Stop
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeg) { Start-Sleep -Milliseconds 400 }
        if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}; return 'TIMEOUT' }
        return 'OK'
    } catch { return 'ERRO' }
}

# Parse do battery-report em XML (fonte mais completa e sem depender de locale).
# Namespace-agnostico: usa local-name() para pegar os nos independente do xmlns.
function Parse-BatteryReportXml {
    param([string]$XmlPath)
    if (-not (Test-Path $XmlPath)) { return $null }
    try { [xml]$doc = Get-Content $XmlPath -Raw -ErrorAction Stop } catch { return $null }

    $out = [ordered]@{ Sistema = [ordered]@{}; Baterias = @() }

    $sys = $doc.SelectSingleNode("//*[local-name()='SystemInformation']")
    if ($sys) {
        foreach ($c in $sys.ChildNodes) {
            if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element) { $out.Sistema[$c.LocalName] = $c.InnerText }
        }
        if ($sys.Attributes) { foreach ($a in $sys.Attributes) { $out.Sistema[$a.LocalName] = $a.Value } }
    }

    foreach ($b in $doc.SelectNodes("//*[local-name()='Battery']")) {
        $o = [ordered]@{}
        foreach ($c in $b.ChildNodes) {
            if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element) { $o[$c.LocalName] = $c.InnerText }
        }
        if ($b.Attributes) { foreach ($a in $b.Attributes) { $o[$a.LocalName] = $a.Value } }

        $dc = [int64]0; $fc = [int64]0
        [void][int64]::TryParse(('' + $o['DesignCapacity']), [ref]$dc)
        [void][int64]::TryParse(('' + $o['FullChargeCapacity']), [ref]$fc)
        if ($dc -gt 0 -and $fc -gt 0) { $o['WearPct'] = [math]::Round((1 - ($fc / $dc)) * 100, 1) }

        $out.Baterias += , ([PSCustomObject]$o)
    }
    return [PSCustomObject]$out
}

# Extrai as linhas de uma tabela do battery-report.html entre dois marcadores.
# Retorna um array de arrays de celulas (texto limpo). Serve para o historico
# de capacidade e para as estimativas de autonomia (tabelas so presentes no HTML).
function Parse-HtmlSectionRows {
    param([string]$Html, [string]$StartRegex, [string]$EndRegex)
    $out = @()
    if (-not $Html) { return $out }
    $m = [regex]::Match($Html, "(?is)$StartRegex(.*?)(?:$EndRegex)")
    if (-not $m.Success) { return $out }
    $sec = $m.Groups[1].Value
    foreach ($tr in [regex]::Matches($sec, '(?is)<tr[^>]*>(.*?)</tr>')) {
        $cells = @()
        foreach ($td in [regex]::Matches($tr.Groups[1].Value, '(?is)<t[dh][^>]*>(.*?)</t[dh]>')) {
            $txt = ($td.Groups[1].Value -replace '(?is)<[^>]+>', ' ' -replace '&nbsp;', ' ' -replace '\s+', ' ').Trim()
            $cells += $txt
        }
        if ($cells.Count -gt 0) { $out += , $cells }
    }
    return $out
}

function Coletar-Bateria {
    Detectar-Ambiente
    Log ">> Coletando dados de bateria/BMS (completo)..." 'Cyan'

    # --- Telemetria WMI/CIM ---
    $BatWin32   = Executar "Win32_Battery" { Get-CimInstance Win32_Battery -ErrorAction Stop }
    $BatStatic  = Executar "BatteryStaticData (capacidade de projeto)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop }
    $BatFull    = Executar "BatteryFullChargedCapacity (capacidade cheia)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop }
    $BatStatus  = Executar "BatteryStatus (tensao, taxa, criticidade)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop }
    $BatCycle   = Executar "BatteryCycleCount (ciclos)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop }
    $BatTemp    = Executar "BatteryTemperature" { Get-CimInstance -Namespace root\wmi -ClassName BatteryTemperature -ErrorAction Stop }

    Salvar-Json $BatWin32  (Join-Path $script:Pastas.Bruto 'bateria_win32.json')
    Salvar-Json $BatStatic (Join-Path $script:Pastas.Bruto 'bateria_static_data.json')
    Salvar-Json $BatFull   (Join-Path $script:Pastas.Bruto 'bateria_full_charged.json')
    Salvar-Json $BatStatus (Join-Path $script:Pastas.Bruto 'bateria_status.json')
    Salvar-Json $BatCycle  (Join-Path $script:Pastas.Bruto 'bateria_ciclos.json')
    Salvar-Json $BatTemp   (Join-Path $script:Pastas.Bruto 'bateria_temperatura.json')

    # --- Relatorios do powercfg (HTML + XML + energy), so no modo ao vivo ---
    $htmlPath   = Join-Path $script:Pastas.Bateria 'battery-report.html'
    $xmlPath    = Join-Path $script:Pastas.Bateria 'battery-report.xml'
    $energyPath = Join-Path $script:Pastas.Bateria 'energy-report.html'
    $stBatHtml = '-'; $stBatXml = '-'; $stEnergy = '-'
    if ($script:ModoAoVivo) {
        Log "Gerando powercfg /batteryreport (HTML + XML) e /energy..." 'Cyan'
        $stBatHtml = Invoke-PowercfgSeguro "/batteryreport /output `"$htmlPath`"" 30
        $stBatXml  = Invoke-PowercfgSeguro "/batteryreport /output `"$xmlPath`" /xml" 30
        $stEnergy  = Invoke-PowercfgSeguro "/energy /output `"$energyPath`" /duration 5" 60
        Log "powercfg -> battery HTML: $stBatHtml | battery XML: $stBatXml | energy: $stEnergy" 'Gray'
    } else {
        Log "[INFO] powercfg /batteryreport so roda no modo ao vivo (Windows em execucao)." 'DarkGray'
    }

    # --- Parse do relatorio (XML completo + tabelas do HTML) ---
    $xmlParsed = $null
    if (Test-Path $xmlPath) { $xmlParsed = Executar "Parse do battery-report.xml" { Parse-BatteryReportXml $xmlPath } }
    if ($xmlParsed) { Salvar-Json $xmlParsed (Join-Path $script:Pastas.Bruto 'battery_report_parsed.json') }

    $htmlContent = $null
    if (Test-Path $htmlPath) { try { $htmlContent = Get-Content $htmlPath -Raw -ErrorAction Stop } catch {} }

    # Historico de capacidade ao longo do tempo (mostra a degradacao mes a mes).
    $capHist = @()
    if ($htmlContent) {
        $capHist = @(Parse-HtmlSectionRows $htmlContent 'Battery capacity history' 'Battery life estimates|</body>') |
            Where-Object { $_.Count -ge 3 -and $_[0] -match '\d{4}' }
    }
    if ($capHist.Count -gt 0) {
        $capObj = $capHist | ForEach-Object { [PSCustomObject]@{ Periodo = $_[0]; CapacidadeCheia = $_[1]; CapacidadeProjeto = $_[2] } }
        Salvar-Csv $capObj (Join-Path $script:Pastas.Bateria 'historico_capacidade.csv')
    }

    # Estimativas de autonomia (autonomia a plena carga x capacidade de projeto).
    $lifeEst = @()
    if ($htmlContent) {
        $lifeEst = @(Parse-HtmlSectionRows $htmlContent 'Battery life estimates' '</body>') |
            Where-Object { $_.Count -ge 2 -and $_[0] -match '\d{4}' }
    }
    if ($lifeEst.Count -gt 0) {
        $lifeObj = $lifeEst | ForEach-Object {
            [PSCustomObject]@{
                Periodo       = $_[0]
                AtivoCheia    = if ($_.Count -gt 1) { $_[1] } else { '-' }
                StandbyCheia  = if ($_.Count -gt 2) { $_[2] } else { '-' }
                AtivoProjeto  = if ($_.Count -gt 3) { $_[3] } else { '-' }
                StandbyProjeto= if ($_.Count -gt 4) { $_[4] } else { '-' }
            }
        }
        Salvar-Csv $lifeObj (Join-Path $script:Pastas.Bateria 'estimativas_autonomia.csv')
    }

    # --- Desgaste: prioriza XML do relatorio; cai pra WMI se preciso ---
    $DesgastePct = $null
    if ($xmlParsed -and $xmlParsed.Baterias.Count -gt 0) {
        $b0 = $xmlParsed.Baterias[0]
        if ($b0.PSObject.Properties['WearPct']) { $DesgastePct = $b0.WearPct }
    }
    if ($null -eq $DesgastePct -and $BatStatic -and $BatFull) {
        $projeto = ($BatStatic | Select-Object -First 1).DesignedCapacity
        $cheia   = ($BatFull | Select-Object -First 1).FullChargedCapacity
        if ($projeto -gt 0) { $DesgastePct = [math]::Round((1 - ($cheia / $projeto)) * 100, 1) }
    }

    # --- Monta o RESUMO_BATERIA.md (rico) ---
    $mb = New-Object System.Text.StringBuilder
    [void]$mb.AppendLine("# Bateria / BMS - Relatorio Completo`n")
    [void]$mb.AppendLine("_gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')_`n")

    [void]$mb.AppendLine("## Status da coleta (powercfg)`n")
    [void]$mb.AppendLine("| Relatorio | Status |")
    [void]$mb.AppendLine("| --- | --- |")
    [void]$mb.AppendLine("| battery-report.html | $stBatHtml |")
    [void]$mb.AppendLine("| battery-report.xml  | $stBatXml |")
    [void]$mb.AppendLine("| energy-report.html  | $stEnergy |")
    [void]$mb.AppendLine("")
    [void]$mb.AppendLine("> TIMEOUT em qualquer um sugere barramento I2C/SMBus travado no controlador da bateria.`n")

    $temBateria = [bool]$BatWin32
    $ResumoBateria = [ordered]@{
        'Bateria detectada'            = if ($temBateria) { 'Sim' } else { 'Nao (desktop, ou BMS nao exposto via WMI)' }
        'Fabricante'                   = ($BatStatic | Select-Object -First 1).ManufactureName
        'Quimica'                      = ($BatStatic | Select-Object -First 1).Chemistry
        'Numero de serie'              = ($BatStatic | Select-Object -First 1).SerialNumber
        'Data de fabricacao'           = ($BatStatic | Select-Object -First 1).ManufactureDate
        'Tensao de projeto (mV)'       = ($BatStatic | Select-Object -First 1).DesignedVoltage
        'Capacidade de projeto (mWh)'  = ($BatStatic | Select-Object -First 1).DesignedCapacity
        'Capacidade cheia atual (mWh)' = ($BatFull | Select-Object -First 1).FullChargedCapacity
        'Desgaste estimado'            = if ($null -ne $DesgastePct) { "$DesgastePct%" } else { '-' }
        'Ciclos de carga'              = ($BatCycle | Select-Object -First 1).CycleCount
        'Status (Win32_Battery)'       = ($BatWin32 | Select-Object -First 1).Status
        'Carga estimada (%)'           = ($BatWin32 | Select-Object -First 1).EstimatedChargeRemaining
        'Autonomia estimada (min)'     = $(if (($BatWin32 | Select-Object -First 1).EstimatedRunTime -and ($BatWin32 | Select-Object -First 1).EstimatedRunTime -lt 71582788) { ($BatWin32 | Select-Object -First 1).EstimatedRunTime } else { '- (na tomada)' })
        'Temperatura'                  = if ($BatTemp) { ($BatTemp | Select-Object -First 1).Temperature } else { 'nao exposto pelo BMS/EC' }
    }
    [void]$mb.AppendLine((Escrever-TabelaMd -Campos $ResumoBateria -Titulo 'Resumo (WMI/CIM)'))

    # Por bateria, direto do XML do powercfg (todos os campos disponiveis).
    if ($xmlParsed -and $xmlParsed.Baterias.Count -gt 0) {
        $i = 0
        foreach ($bat in $xmlParsed.Baterias) {
            $i++
            $campos = [ordered]@{}
            foreach ($pn in $bat.PSObject.Properties.Name) { $campos[$pn] = $bat.$pn }
            [void]$mb.AppendLine((Escrever-TabelaMd -Campos $campos -Titulo "Bateria #$i (powercfg XML)"))
        }
    }

    # Historico de capacidade (degradacao ao longo do tempo).
    if ($capHist.Count -gt 0) {
        [void]$mb.AppendLine("## Historico de capacidade (degradacao ao longo do tempo)`n")
        [void]$mb.AppendLine("| Periodo | Capacidade cheia | Capacidade de projeto |")
        [void]$mb.AppendLine("| --- | --- | --- |")
        foreach ($r in $capHist) { [void]$mb.AppendLine("| $($r[0]) | $($r[1]) | $($r[2]) |") }
        [void]$mb.AppendLine("")
    }

    # Estimativas de autonomia.
    if ($lifeEst.Count -gt 0) {
        [void]$mb.AppendLine("## Estimativas de autonomia`n")
        [void]$mb.AppendLine("| Periodo | Ativo (cheia) | Standby (cheia) | Ativo (projeto) | Standby (projeto) |")
        [void]$mb.AppendLine("| --- | --- | --- | --- | --- |")
        foreach ($r in $lifeEst) {
            $c1 = if ($r.Count -gt 1) { $r[1] } else { '-' }
            $c2 = if ($r.Count -gt 2) { $r[2] } else { '-' }
            $c3 = if ($r.Count -gt 3) { $r[3] } else { '-' }
            $c4 = if ($r.Count -gt 4) { $r[4] } else { '-' }
            [void]$mb.AppendLine("| $($r[0]) | $c1 | $c2 | $c3 | $c4 |")
        }
        [void]$mb.AppendLine("")
    }

    # Plano de energia ativo (so ao vivo).
    if ($script:ModoAoVivo) {
        $plano = Executar "Plano de energia ativo (powercfg /getactivescheme)" { powercfg /getactivescheme | Out-String }
        if ($plano) {
            [void]$mb.AppendLine("## Plano de energia ativo`n")
            [void]$mb.AppendLine('```text')
            [void]$mb.AppendLine($plano.Trim())
            [void]$mb.AppendLine('```')
            [void]$mb.AppendLine("")
        }
    }

    # Dados brutos completos (Format-List *) - toda propriedade exposta pelo BMS.
    [void]$mb.AppendLine("## Dados brutos (Format-List completo)`n")
    $paresBrutos = @(
        @('Win32_Battery', $BatWin32),
        @('BatteryStatus (root\wmi - tempo real)', $BatStatus),
        @('BatteryStaticData (root\wmi - registradores de fabrica)', $BatStatic),
        @('BatteryFullChargedCapacity (root\wmi)', $BatFull),
        @('BatteryCycleCount (root\wmi)', $BatCycle),
        @('BatteryTemperature (root\wmi)', $BatTemp)
    )
    foreach ($par in $paresBrutos) {
        [void]$mb.AppendLine("### $($par[0])")
        [void]$mb.AppendLine('```text')
        if ($par[1]) {
            [void]$mb.AppendLine((($par[1] | Format-List * | Out-String).Trim()))
        } else {
            [void]$mb.AppendLine('[sem dados retornados pelo hardware para esta classe]')
        }
        [void]$mb.AppendLine('```')
        [void]$mb.AppendLine("")
    }

    [void]$mb.AppendLine("## Arquivos gerados`n")
    [void]$mb.AppendLine("- battery-report.html / .xml - relatorio nativo do powercfg (completo)")
    [void]$mb.AppendLine("- energy-report.html - analise de energia/eficiencia (/energy)")
    [void]$mb.AppendLine("- historico_capacidade.csv / estimativas_autonomia.csv - tabelas extraidas")
    [void]$mb.AppendLine("- 09_Dados_Brutos\\battery_report_parsed.json - XML parseado")
    [void]$mb.AppendLine("- eventos_energia_bateria.csv - eventos de energia (se coletado)`n")
    [void]$mb.AppendLine("## Como ler`n")
    [void]$mb.AppendLine("- Desgaste = 1 - (capacidade cheia / capacidade de projeto). Acima de ~20% ja e desgaste relevante.")
    [void]$mb.AppendLine("- Ciclos acima de ~500 costumam justificar troca em uso intenso.")
    [void]$mb.AppendLine("- LastErrorCode != 0 no Win32_Battery: consultar doc da Microsoft.")

    $mb.ToString() | Out-File (Join-Path $script:Pastas.Bateria 'RESUMO_BATERIA.md') -Encoding UTF8

    # --- Eventos de energia (precisa do System.evtx copiado) ---
    $SystemEvtx = Join-Path $script:Pastas.EventLogs 'System.evtx'
    if (Test-Path $SystemEvtx) {
        $EventosBateria = Executar "Eventos de energia (Kernel-Power etc.)" {
            Get-WinEvent -FilterHashtable @{ Path = $SystemEvtx; ProviderName = 'Microsoft-Windows-Kernel-Power','Microsoft-Windows-Kernel-Processor-Power','Microsoft-Windows-UserModePowerService' } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Sort-Object TimeCreated -Descending | Select-Object -First 500
        }
        if ($EventosBateria) {
            Salvar-Csv $EventosBateria (Join-Path $script:Pastas.Bateria 'eventos_energia_bateria.csv')
            $script:Dados['nBateria'] = ($EventosBateria | Measure-Object).Count
        }
    }

    $script:Dados['DesgastePct'] = $DesgastePct
    $script:Dados['BatCycle'] = $BatCycle
    Marcar 'Bateria'
}

function Coletar-Drivers {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[PULADO] Drivers - Windows nao encontrado" 'Yellow'; return }
    Log ">> Coletando drivers..." 'Cyan'
    Executar "Listar drivers (DriverStore)" {
        if (Test-Path "$($script:WinDrive)\Windows\System32\DriverStore\FileRepository") {
            Get-ChildItem "$($script:WinDrive)\Windows\System32\DriverStore\FileRepository" -ErrorAction Stop |
                Select-Object Name, LastWriteTime |
                Export-Csv (Join-Path $script:Pastas.Drivers 'driverstore.csv') -NoTypeInformation -Encoding UTF8
        }
    }
    if ($script:ModoAoVivo) {
        Executar "Listar drivers assinados (driverquery)" {
            $out = & driverquery /v /fo csv 2>$null
            if ($out) { $out | Out-File (Join-Path $script:Pastas.Drivers 'drivers_ativos.csv') -Encoding UTF8 }
        }
    }
    Marcar 'Drivers'
}

# ============================================================
#  Resumo geral e ZIP
# ============================================================
function Gerar-ResumoGeral {
    Detectar-Ambiente
    Log ">> Gerando resumo geral..." 'Cyan'

    $CS   = $script:Dados['CS']
    $BIOS = $script:Dados['BIOS']
    $DISK = $script:Dados['DISK']
    $PNP_ERR = $script:Dados['PNP_ERR']
    $InfoWindowsInstalado = $script:Dados['InfoWindows']
    $DesgastePct = $script:Dados['DesgastePct']
    $BatCycle = $script:Dados['BatCycle']
    $nCriticos = if ($script:Dados['nCriticos']) { $script:Dados['nCriticos'] } else { 0 }
    $nBateria  = if ($script:Dados['nBateria'])  { $script:Dados['nBateria'] }  else { 0 }

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Coleta de Diagnostico")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("_gerado em $(Get-Date -Format 'dd/MM/yyyy, HH:mm')  -  modo: $(if ($script:ModoAoVivo) { 'ao vivo' } elseif ($script:WinDrive) { 'offline' } else { 'so hardware' })_")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("Coletas executadas: $((@($script:Executadas) | Sort-Object) -join ', ')")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Identificacao rapida")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Campo | Valor |")
    [void]$md.AppendLine("| --- | --- |")
    [void]$md.AppendLine("| Fabricante / Modelo | $($CS.Manufacturer) $($CS.Model) |")
    [void]$md.AppendLine("| Numero de serie | $($BIOS.SerialNumber) |")
    [void]$md.AppendLine("| Particao do Windows | $(if ($script:WinDrive) { $script:WinDrive } else { 'NAO ENCONTRADA' }) |")
    if ($InfoWindowsInstalado -and $InfoWindowsInstalado.Count -gt 0) {
        [void]$md.AppendLine("| Windows | $($InfoWindowsInstalado['Produto']) $($InfoWindowsInstalado['Versao']) (build $($InfoWindowsInstalado['Build'])) |")
        if ($InfoWindowsInstalado['Ultimo desligamento registrado']) {
            [void]$md.AppendLine("| Ultimo desligamento registrado | $($InfoWindowsInstalado['Ultimo desligamento registrado']) |")
        }
    }
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Diagnostico de inicializacao")
    [void]$md.AppendLine("")
    $nDumps = (Get-ChildItem $script:Pastas.Dumps -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    [void]$md.AppendLine("- Eventos de desligamento inesperado / bugcheck: $nCriticos (ver 04_Boot)")
    [void]$md.AppendLine("- Dumps encontrados: $nDumps arquivo(s) em 03_Dumps_e_WER")
    [void]$md.AppendLine("- Dispositivos com erro no gerenciador: $(if ($PNP_ERR) { ($PNP_ERR | Measure-Object).Count } else { 0 })")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Bateria / BMS")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("- Desgaste estimado: $(if ($null -ne $DesgastePct) { "$DesgastePct%" } else { '-' })")
    [void]$md.AppendLine("- Ciclos de carga: $(($BatCycle | Select-Object -First 1).CycleCount)")
    [void]$md.AppendLine("- Eventos de energia/bateria: $nBateria (ver 07_Bateria_BMS)")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Armazenamento")
    [void]$md.AppendLine("")
    if ($DISK) {
        foreach ($d in $DISK) {
            [void]$md.AppendLine("- $($d.Model) - $([math]::Round($d.Size/1GB,0)) GB, status: $($d.Status)")
        }
    }
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Indice das pastas")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("- 00_Resumo - este arquivo")
    [void]$md.AppendLine("- 01_EventLogs - Event Logs (.evtx)")
    [void]$md.AppendLine("- 02_Panther - logs de setup do Windows")
    [void]$md.AppendLine("- 03_Dumps_e_WER - minidumps, MEMORY.DMP, WER")
    [void]$md.AppendLine("- 04_Boot - ntbtlog e eventos criticos de desligamento")
    [void]$md.AppendLine("- 05_Registro - versao do Windows, servicos, ultimo shutdown")
    [void]$md.AppendLine("- 06_Hardware - inventario completo do hardware")
    [void]$md.AppendLine("- 07_Bateria_BMS - bateria, BMS, battery-report, eventos de energia")
    [void]$md.AppendLine("- 08_Drivers - drivers")
    [void]$md.AppendLine("- 09_Dados_Brutos - JSON/CSV sem curadoria")
    [void]$md.AppendLine("")
    $md.ToString() | Out-File (Join-Path $script:Pastas.Resumo 'RESUMO_GERAL.md') -Encoding UTF8
}

function Compactar-Zip {
    Detectar-Ambiente
    Executar "Compactar coleta em .zip" {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $modelo = if ($script:Dados['CS']) { $script:Dados['CS'].Model } else { 'maquina' }
        $nomeZip = ("coleta_{0}_{1}.zip" -f ($modelo -replace '[^\w\-]', '_'), $Timestamp) -replace '_+', '_'
        $zipParent = Split-Path $Destino -Parent
        if (-not $zipParent) { $zipParent = $ScriptRoot }
        $zipPath = Join-Path $zipParent $nomeZip
        if (Test-Path $zipPath) { Remove-Item $zipPath -Force -ErrorAction SilentlyContinue }

        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $baseLen = $Destino.TrimEnd('\').Length + 1
            Get-ChildItem $Destino -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
                $rel = $_.FullName.Substring($baseLen)
                try {
                    $fs = [System.IO.File]::Open($_.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
                    try {
                        $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                        $es = $entry.Open()
                        try { $fs.CopyTo($es) } finally { $es.Dispose() }
                    } finally { $fs.Dispose() }
                } catch {
                    Log "[FALHOU] zip do arquivo '$rel' -> $($_.Exception.Message)" 'Yellow'
                }
            }
        } finally { $zip.Dispose() }
        Log "ZIP gerado: $zipPath" 'Green'
    }
}

# ============================================================
#  Coleta COMPLETA (ordem importa: EventLogs antes de Boot/Bateria
#  para minerar os eventos do System.evtx)
# ============================================================
function Coletar-Completa {
    Log "===== COLETA COMPLETA =====" 'Cyan'
    Coletar-EventLogs
    Coletar-Panther
    Coletar-Boot
    Coletar-Dumps
    Coletar-Registro
    Coletar-Hardware
    Coletar-Bateria
    Coletar-Drivers
    Gerar-ResumoGeral
    if (-not $SemZip) { Compactar-Zip }
}

# ============================================================
#  Dispatcher por palavra-chave
# ============================================================
function Executar-Tarefa {
    param([string]$Nome)
    switch -Regex ($Nome.Trim().ToLower()) {
        '^(1|completa|tudo|all)$'      { Coletar-Completa; return }
        '^(2|eventlogs|eventos|logs)$' { Coletar-EventLogs; return }
        '^(3|panther|setup)$'          { Coletar-Panther; return }
        '^(4|boot)$'                   { Coletar-Boot; return }
        '^(5|dumps|dump|wer)$'         { Coletar-Dumps; return }
        '^(6|registro|registry)$'      { Coletar-Registro; return }
        '^(7|hardware|hw|inventario)$' { Coletar-Hardware; return }
        '^(8|bateria|bms|battery)$'    { Coletar-Bateria; return }
        '^(9|drivers|driver)$'         { Coletar-Drivers; return }
        default { Log "[?] Opcao desconhecida: '$Nome'" 'Yellow' }
    }
}

# ============================================================
#  Menu interativo
# ============================================================
function Mostrar-Menu {
    Detectar-Ambiente
    $amb = "Windows NAO encontrado (so hardware/bateria)"
    if ($script:WinDrive) {
        if ($script:ModoAoVivo)  { $amb = "Windows ao vivo ($($script:WinDrive))" }
        elseif ($script:IsWinPE) { $amb = "WinPE / offline - Windows em $($script:WinDrive)" }
        else                     { $amb = "Offline - Windows em $($script:WinDrive)" }
    } elseif ($script:IsWinPE) {
        $amb = "WinPE - Windows NAO encontrado (so hardware/bateria)"
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   COLETA DE DIAGNOSTICO" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   Ambiente: $amb"
    Write-Host "   Destino : $Destino"
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] COLETA COMPLETA  (tudo + resumo geral + .zip)" -ForegroundColor Green
    Write-Host "   ----------------------------------------------------------"
    Write-Host "   [2] Event Logs (winevt)"
    Write-Host "   [3] Panther (logs de setup)"
    Write-Host "   [4] Boot log + eventos criticos de desligamento"
    Write-Host "   [5] Dumps (minidump, MEMORY.DMP, WER)"
    Write-Host "   [6] Registro (versao, servicos, ultimo shutdown)"
    Write-Host "   [7] Inventario de Hardware (BIOS/CPU/RAM/disco/GPU/TPM...)"
    Write-Host "   [8] Bateria / BMS (desgaste, ciclos, temperatura)"
    Write-Host "   [9] Drivers"
    Write-Host "   ----------------------------------------------------------"
    Write-Host "   [D] Alterar pasta de destino"
    Write-Host "   [R] Gerar/atualizar resumo geral"
    Write-Host "   [Z] Compactar coleta atual em .zip"
    Write-Host "   [0] Sair"
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   Dica: pode combinar, ex.:  2,4,7" -ForegroundColor DarkGray
}

function Loop-Menu {
    while ($true) {
        Mostrar-Menu
        $entrada = Read-Host "Escolha"
        if ($null -eq $entrada) { break }
        $entrada = $entrada.Trim()
        if ($entrada -eq '') { continue }
        $up = $entrada.ToUpper()

        # Comandos de letra/numero unico (if-chain: 'continue'/'return' aqui
        # atuam no while, nao dentro de um switch)
        if ($up -eq '0' -or $up -eq 'Q') { Log "Encerrando." 'Cyan'; return }

        if ($up -eq 'D') {
            $novo = Read-Host "Nova pasta de destino (ex: D:\Coleta)"
            if ($novo -and $novo.Trim() -ne '') {
                Set-Variable -Name Destino -Value ($novo.Trim()) -Scope Script
                $script:Pastas = $null
                $script:AmbienteOk = $false
                $script:LogFile = $null
                Detectar-Ambiente
            }
            continue
        }

        if ($up -eq 'R') { Gerar-ResumoGeral; Read-Host "ENTER para continuar" | Out-Null; continue }
        if ($up -eq 'Z') { Compactar-Zip;     Read-Host "ENTER para continuar" | Out-Null; continue }

        # Uma ou varias tarefas separadas por virgula/espaco/ponto-e-virgula
        $itens = $entrada -split '[,; ]+' | Where-Object { $_ -ne '' }
        foreach ($it in $itens) { Executar-Tarefa $it }

        # Se rodou coletas individuais (nao a completa), atualiza o resumo.
        if ($itens -notcontains '1') { Gerar-ResumoGeral }

        Write-Host ""
        Read-Host "Coleta(s) concluida(s). ENTER para voltar ao menu" | Out-Null
    }
}

# ============================================================
#  Entrada
# ============================================================
# Destino automatico quando nao foi informado (evita gravar em X:\ - RAM).
if (-not $Destino) {
    $raizAuto = Selecionar-DestinoAuto
    if ($raizAuto) {
        $Destino = Join-Path ($raizAuto + '\') "Coleta\coleta_$Timestamp"
    } else {
        # Nenhum disco gravavel alem do X: - usa o ScriptRoot mesmo (com aviso).
        $Destino = Join-Path $ScriptRoot "coleta_$Timestamp"
    }
}

Detectar-Ambiente

if ($Auto) { $Tarefas = @('Completa') }

if ($Tarefas -and $Tarefas.Count -gt 0) {
    # Modo nao-interativo
    foreach ($t in $Tarefas) { Executar-Tarefa $t }
    if ($Tarefas -notcontains 'Completa' -and $Tarefas -notcontains 'Tudo' -and $Tarefas -notcontains '1') {
        Gerar-ResumoGeral
        if (-not $SemZip) { Compactar-Zip }
    }
} else {
    # Modo menu
    Loop-Menu
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  FIM. Pasta: $Destino" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
