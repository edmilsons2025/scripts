<#
.SYNOPSIS
  Script de diagnóstico para coleta automatizada de hardware, sistema, logs e telemetria de energia.
  Suporta execução online ou offline (WinPE), adaptando os métodos de extração.

.DESCRIPTION
  O utilitário identifica o ambiente de execução e seleciona a estratégia adequada:
  - Online (SO Ativo): Utiliza WMI, CIM e registro nativo em tempo de execução.
  - Offline (WinPE/SO Inativo): Localiza a partição do Windows, monta os hives de registro via 'reg load' e realiza cópia bruta de logs.

  Módulos de Coleta:
    * Event Logs (winevt)
    * Panther (Setup Logs)
    * Boot Logs (Crash e eventos críticos)
    * Dumps (Memory, Minidump, LiveKernel, WER)
    * Registro (Versão, Serviços, Telemetria de Shutdown)
    * Inventário de Hardware (BIOS, Placa-mãe, CPU, RAM, Discos/SMART, GPU, Rede, TPM, Secure Boot, Erros PnP)
    * Telemetria de Bateria/BMS (Desgaste, Ciclos, Relatórios de Energia do powercfg)
    * Drivers (DriverStore e Ativos)

.PARAMETER Destino
  Diretório alvo para gravação estruturada dos artefatos.

.PARAMETER Tarefas
  Lista de execuções automatizadas. Exemplo: -Tarefas Hardware,Bateria

.PARAMETER Auto
  Executa a rotina completa sem intervenção interativa.

.PARAMETER SemZip
  Suprime a compactação final dos artefatos coletados.
#>

[CmdletBinding()]
param(
    [string]$Destino,
    [string[]]$Tarefas,
    [switch]$Auto,
    [switch]$SemZip
)

$ErrorActionPreference = 'Continue'
$DestinoFoiInformado =$PSBoundParameters.ContainsKey('Destino')

# Determina o diretório de execução base dependendo do contexto de invocação (local ou web).
$ScriptRoot =$null
$ScriptPath =$MyInvocation.MyCommand.Path
if ($ScriptPath) { $ScriptRoot = Split-Path -Parent$ScriptPath }
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

# Estruturas de controle de estado em memória.
$script:Dados      = [ordered]@{}$script:Executadas = New-Object System.Collections.ArrayList

function Marcar {
    <#
    .SYNOPSIS
      Registra a conclusão de um módulo na lista de tarefas executadas.
    #>
    param([string]$Nome)
    if (-not $script:Executadas.Contains($Nome)) { [void]$script:Executadas.Add($Nome) }
}

# ============================================================
#  MÓDULOS DE SAÍDA E MANIPULAÇÃO DE DADOS
# ============================================================
$script:LogFile =$null
$script:LogEnc  = New-Object System.Text.UTF8Encoding($false)

function Log {
    <#
    .SYNOPSIS
      Emite registros no console e persiste no arquivo log central.
    #>
    param([string]$Msg, [string]$Cor = 'Gray')
    $linha = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Msg
    Write-Host $linha -ForegroundColor$Cor
    if ($script:LogFile) {
        try { [System.IO.File]::AppendAllText($script:LogFile, ($linha + "`r`n"), $script:LogEnc) } catch {}
    }
}

function Executar {
    <#
    .SYNOPSIS
      Invólucro para blocos de execução com tratamento de exceções.
    #>
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
    <#
    .SYNOPSIS
      Serializa objetos em formato JSON UTF-8.
    #>
    param($Objeto, [string]$Caminho)
    if ($null -eq $Objeto) { return }
    try { $Objeto | ConvertTo-Json -Depth 6 | Out-File -FilePath $Caminho -Encoding UTF8 } catch {}
}

function Salvar-Csv {
    <#
    .SYNOPSIS
      Exporta coleções de objetos para formato CSV UTF-8.
    #>
    param($Objeto, [string]$Caminho)
    if ($null -eq $Objeto) { return }
    try { $Objeto | Export-Csv -Path $Caminho -NoTypeInformation -Encoding UTF8 } catch {}
}

function Escrever-TabelaMd {
    <#
    .SYNOPSIS
      Gera uma tabela Markdown formatada a partir de propriedades de objeto.
    #>
    param([Parameter(Mandatory)]$Campos, [string]$Titulo)
    $sb = New-Object System.Text.StringBuilder
    if ($Titulo) { [void]$sb.AppendLine("## $Titulo`n") }
    [void]$sb.AppendLine("| Campo | Valor |")
    [void]$sb.AppendLine("| --- | --- |")
    foreach ($k in $Campos.Keys) {$v = $Campos[$k]
        if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) {$v = '-' }
        [void]$sb.AppendLine("| $k \vert{}$v |")
    }
    return $sb.ToString()
}

# ============================================================
#  INICIALIZAÇÃO DE AMBIENTE E SISTEMA DE ARQUIVOS
# ============================================================
$script:Pastas    =$null
$script:WinDrive  =$null
$script:IsWinPE   =$false
$script:ModoAoVivo=$false
$script:AmbienteOk=$false

function Selecionar-DestinoAuto {
    <#
    .SYNOPSIS
      Seleciona automaticamente o volume mais apropriado para a gravação da coleta, evitando ramdisks.
    #>
    $cands = @()
    try {
        $vols = Get-CimInstance Win32_LogicalDisk -ErrorAction Stop | Where-Object { $_.DriveType -eq 2 -or$_.DriveType -eq 3 }
        foreach ($v in$vols) {
            if ($v.DeviceID -eq 'X:') { continue }
            if (-not $v.FreeSpace) { continue }
            $cands += [PSCustomObject]@{ Letra =$v.DeviceID; Livre = [int64]$v.FreeSpace; Tipo = [int]$v.DriveType }
        }
    } catch {}

    $cands = $cands \vert{} Sort-Object @{ Expression = { if ($_.Tipo -eq 2) { 0 } else { 1 } } }, @{ Expression = { $_.Livre }; Descending =$true }

    foreach ($c in$cands) {
        if ($c.Livre -lt 200MB) { continue }$teste = Join-Path ($c.Letra + '\') ('._coleta_test_' +$Timestamp)
        try {
            New-Item -ItemType Directory -Path $teste -Force -ErrorAction Stop | Out-Null
            Remove-Item $teste -Recurse -Force -ErrorAction SilentlyContinue
            $gb = [math]::Round($c.Livre / 1GB, 1)
            $tipoTxt = if ($c.Tipo -eq 2) { 'USB/Removivel' } else { 'Disco Local' }
            Log "Destino automatico: $($c.Letra) ($tipoTxt,$gb GB livres)" 'Green'
            return $c.Letra
        } catch { continue }
    }
    return $null
}

function Inicializar-Destino {
    <#
    .SYNOPSIS
      Gera a árvore de diretórios estruturada para os artefatos de coleta.
    #>
    if ($script:Pastas) { return }

    $DriveDestino =$null
    try { $DriveDestino = (Split-Path -Qualifier$Destino -ErrorAction Stop) } catch {}
    if (-not $DestinoFoiInformado -and$DriveDestino -eq 'X:') {
        Write-Host ""
        Write-Host "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" -ForegroundColor Red
        Write-Host "  ALERTA CRITICO: Gravando no ramdisk (X:\) do ambiente WinPE." -ForegroundColor Red
        Write-Host "  Os dados serao volatilizados no proximo ciclo de energia." -ForegroundColor Red
        Write-Host "  Recomenda-se selecionar um volume persistente atraves do menu." -ForegroundColor Red
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
    foreach ($p in $script:Pastas.Values) { New-Item -ItemType Directory -Force -Path$p | Out-Null }
    $script:LogFile = Join-Path$Destino 'coleta_diagnostico.log'
    Log "Diretorio Alvo: $Destino" 'Cyan'
}

function Detectar-Ambiente {
    <#
    .SYNOPSIS
      Analisa o volume de sistema atual para identificar se a execução é online ou em ambiente pre-boot.
    #>
    if ($script:AmbienteOk) { return }
    Inicializar-Destino

    $RunningDrive =$env:SystemDrive
    $script:IsWinPE =$false
    try {
        $script:IsWinPE = ($RunningDrive -eq 'X:') -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')
    } catch {}

    Log "Inspecionando estrutura de particoes do Windows..." 'Cyan'
    $script:WinDrive =$null
    foreach ($letra in 67..90 \vert{} ForEach-Object { [char]$_ }) {
        $candidato = "$letra`:\Windows\System32\config\SYSTEM"
        if (Test-Path $candidato) { $script:WinDrive = "$letra`:"; break }
    }

    $script:ModoAoVivo = (-not $script:IsWinPE) -and$script:WinDrive -and ($script:WinDrive -eq$RunningDrive)

    if (-not $script:WinDrive) {         Log "[ERRO] Sistema Operacional base nao localizado. Modulos limitados a inspecao de hardware." 'Red'     } elseif ($script:ModoAoVivo) {
        Log "Windows ativo identificado no volume $($script:WinDrive) (Modo Online)" 'Green'
    } else {
        Log "Windows inativo identificado no volume $($script:WinDrive) (Modo Offline)" 'Green'
    }
    $script:AmbienteOk =$true
}

# ============================================================
#  MÓDULOS DE COLETA DE DADOS
# ============================================================

function Coletar-EventLogs {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[ABORTADO] Event Logs - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo de Event Logs..." 'Cyan'
    Executar "Extracao de Event Logs (.evtx)" {
        Copy-Item "$($script:WinDrive)\Windows\System32\winevt\Logs\*" $script:Pastas.EventLogs -Recurse -Force -ErrorAction Stop
    }
    Marcar 'EventLogs'
}

function Coletar-Panther {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[ABORTADO] Panther - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo Panther (Setup Logs)..." 'Cyan'
    Executar "Extracao do diretorio Panther" {
        if (Test-Path "$($script:WinDrive)\Windows\Panther") {
            Copy-Item "$($script:WinDrive)\Windows\Panther\*" $script:Pastas.Panther -Recurse -Force -ErrorAction Stop
        }
    }
    Executar "Extracao do diretorio UnattendGC" {
        if (Test-Path "$($script:WinDrive)\Windows\Panther\UnattendGC") {
            Copy-Item "$($script:WinDrive)\Windows\Panther\UnattendGC" (Join-Path $script:Pastas.Panther 'UnattendGC') -Recurse -Force -ErrorAction Stop
        }
    }
    Marcar 'Panther'
}

function Coletar-Boot {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[ABORTADO] Boot Logs - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo de Analise de Inicializacao..." 'Cyan'
    Executar "Coleta do arquivo de telemetria de boot (ntbtlog.txt)" {
        if (Test-Path "$($script:WinDrive)\Windows\ntbtlog.txt") {
            Copy-Item "$($script:WinDrive)\Windows\ntbtlog.txt" $script:Pastas.Boot -Force -ErrorAction Stop
        }
    }
    Executar "Coleta da trilha de diagnostico do Startup Repair (SrtTrail.txt)" {
        $srt = "$($script:WinDrive)\Windows\System32\LogFiles\Srt\SrtTrail.txt"
        if (Test-Path $srt) { Copy-Item $srt$script:Pastas.Boot -Force -ErrorAction Stop }
    }

    $SystemEvtx = Join-Path$script:Pastas.EventLogs 'System.evtx'
    if (Test-Path $SystemEvtx) {$ev = Executar "Mineracao de eventos de falha de kernel e desligamento" {
            Get-WinEvent -FilterHashtable @{ Path = $SystemEvtx; Id = 41,1001,6008 } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Sort-Object TimeCreated -Descending
        }
        if ($ev) {
            Salvar-Csv $ev (Join-Path$script:Pastas.Boot 'eventos_criticos_desligamento.csv')
            $script:Dados['nCriticos'] = ($ev | Measure-Object).Count
        }
    } else {
        Log "[INFO] Dependencia de módulo: System.evtx nao localizado para extracao cruzada." 'DarkGray'
    }
    Marcar 'Boot'
}

function Coletar-Dumps {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[ABORTADO] Crash Dumps - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo de Extracao de Dumps e WER..." 'Cyan'
    Executar "Coleta de Minidumps estruturados" {
        if (Test-Path "$($script:WinDrive)\Windows\Minidump") {
            Copy-Item "$($script:WinDrive)\Windows\Minidump\*" $script:Pastas.Dumps -Recurse -Force -ErrorAction Stop
        }
    }
    Executar "Coleta do Dump em Memoria Cheia (MEMORY.DMP)" {
        if (Test-Path "$($script:WinDrive)\Windows\MEMORY.DMP") {
            Copy-Item "$($script:WinDrive)\Windows\MEMORY.DMP" $script:Pastas.Dumps -Force -ErrorAction Stop
        }
    }
    Executar "Coleta de relatorios Kernel ao Vivo" {
        if (Test-Path "$($script:WinDrive)\Windows\LiveKernelReports") {
            Copy-Item "$($script:WinDrive)\Windows\LiveKernelReports" (Join-Path $script:Pastas.Dumps 'LiveKernelReports') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Executar "Coleta de relatorios de Erros de Sistema (WER)" {
        $werPaths = @(
            "$($script:WinDrive)\ProgramData\Microsoft\Windows\WER\ReportArchive",
            "$($script:WinDrive)\ProgramData\Microsoft\Windows\WER\ReportQueue"
        )
        foreach ($wp in$werPaths) {
            if (Test-Path $wp) {$destWer = Join-Path $script:Pastas.Dumps ("WER_" + (Split-Path $wp -Leaf))
                Copy-Item $wp$destWer -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }
    Marcar 'Dumps'
}

function Coletar-Registro {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[ABORTADO] Registro - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo de Analise de Registro e Servicos..." 'Cyan'

    $InfoWindowsInstalado = [ordered]@{}

    $lerInfo = {
        param([string]$RaizSoftware, [string]$RaizSystemCS)
        try {
            $cv = Get-ItemProperty "$RaizSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            $InfoWindowsInstalado['Produto'] =$cv.ProductName
            $InfoWindowsInstalado['Versao'] = if ($cv.DisplayVersion) {$cv.DisplayVersion } else { $cv.ReleaseId }$InfoWindowsInstalado['Build'] = "$($cv.CurrentBuild).$($cv.UBR)"
            $InfoWindowsInstalado['Instalado em'] = if ($cv.InstallDate) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$cv.InstallDate).LocalDateTime } else { '-' }
            $InfoWindowsInstalado['Dono registrado'] =$cv.RegisteredOwner
            Log "[OK] Leitura das subchaves de versao e build do sistema" 'Green'
        } catch { Log "[FALHOU] Falha na leitura de versao -> $($_.Exception.Message)" 'Yellow' }

        try {
            $cn = Get-ItemProperty "$RaizSystemCS\Control\ComputerName\ComputerName" -ErrorAction SilentlyContinue
            if ($cn) { $InfoWindowsInstalado['Nome do computador'] =$cn.ComputerName }
            $win = Get-ItemProperty "$RaizSystemCS\Control\Windows" -ErrorAction SilentlyContinue
            if ($win -and$win.ShutdownTime) {
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
            Log "[OK] Leitura de parametros de energia e CrashControl concluida" 'Green'
        } catch { Log "[FALHOU] Erro na extracao de metadata de sistema -> $($_.Exception.Message)" 'Yellow' }
    }

    if ($script:ModoAoVivo) {
        & $lerInfo 'HKLM:\SOFTWARE' 'HKLM:\SYSTEM\CurrentControlSet'
        Executar "Extracao de servicos via modelo CIM (Win32_Service)" {
            Get-CimInstance Win32_Service -ErrorAction Stop |
                Select-Object Name, DisplayName, State, StartMode, StartName, PathName |
                Export-Csv (Join-Path $script:Pastas.Registro 'servicos.csv') -NoTypeInformation -Encoding UTF8
        }
    } else {
        Log "Iniciando montagem offline das arvores de Registro..." 'Cyan'
        $hives = [ordered]@{
            'HKLM\VC_SYSTEM'   = "$($script:WinDrive)\Windows\System32\config\SYSTEM"
            'HKLM\VC_SOFTWARE' = "$($script:WinDrive)\Windows\System32\config\SOFTWARE"
        }
        $hivesMontados = @()
        foreach ($chave in$hives.Keys) {
            $arq =$hives[$chave]$ok = Executar "Montagem da estrutura binaria $chave" {
                $saida = & reg load $chave$arq 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Codigo de integridade $LASTEXITCODE retornado no sub-processo ($saida)" }
                $true
            }
            if ($ok) { $hivesMontados +=$chave }
        }

        $cs = 'ControlSet001'
        try {
            $sel = Get-ItemProperty 'HKLM:\VC_SYSTEM\Select' -ErrorAction Stop
            $cs = 'ControlSet{0:D3}' -f$sel.Current
        } catch {}
        $InfoWindowsInstalado['ControlSet atual'] =$cs

        & $lerInfo 'HKLM:\VC_SOFTWARE' "HKLM:\VC_SYSTEM\$cs"

        Executar "Parser de chaves de servicos em modo offline" {
            Get-ChildItem "HKLM:\VC_SYSTEM\$cs\Services" -ErrorAction Stop |
                ForEach-Object {
                    $p = Get-ItemProperty$_.PSPath -ErrorAction SilentlyContinue
                    [PSCustomObject]@{
                        Servico   = $_.PSChildName
                        Start     = $p.Start
                        Tipo      = $p.Type
                        ImagePath = $p.ImagePath
                    }
                } | Export-Csv (Join-Path $script:Pastas.Registro 'servicos.csv') -NoTypeInformation -Encoding UTF8
        }

        foreach ($chave in$hivesMontados) {
            Executar "Desmontagem segura da unidade binaria $chave" {
                [gc]::Collect(); [gc]::WaitForPendingFinalizers()
                & reg unload $chave 2>&1 | Out-Null
            } -Silencioso | Out-Null
        }
    }

    if ($InfoWindowsInstalado.Count -gt 0) {
        Escrever-TabelaMd -Campos $InfoWindowsInstalado -Titulo 'Windows instalado' |
            Out-File (Join-Path $script:Pastas.Registro 'RESUMO_REGISTRO.md') -Encoding UTF8
        $script:Dados['InfoWindows'] =$InfoWindowsInstalado
    }
    Marcar 'Registro'
}

function Coletar-Hardware {
    Detectar-Ambiente
    Log ">> Executando módulo de Inventario Central de Hardware..." 'Cyan'

    $CS      = Executar "Base de Sistema (Win32_ComputerSystem)" { Get-CimInstance Win32_ComputerSystem -ErrorAction Stop }
    $CSP     = Executar "Dados do Produto (Win32_ComputerSystemProduct)" { Get-CimInstance Win32_ComputerSystemProduct -ErrorAction Stop }
    $BIOS    = Executar "Firmware BIOS/UEFI" { Get-CimInstance Win32_BIOS -ErrorAction Stop }
    $BB      = Executar "Controlador de Placa-Mae" { Get-CimInstance Win32_BaseBoard -ErrorAction Stop }
    $CPU     = Executar "Arquitetura de Processador" { Get-CimInstance Win32_Processor -ErrorAction Stop }
    $MEM     = Executar "Topologia de Memoria RAM" { Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop }
    $DISK    = Executar "Controladores e Discos Fisicos" { Get-CimInstance Win32_DiskDrive -ErrorAction Stop }
    $PART    = Executar "Tabelas de Particao" { Get-CimInstance Win32_DiskPartition -ErrorAction Stop }
    $VID     = Executar "Aceleradores Graficos" { Get-CimInstance Win32_VideoController -ErrorAction Stop }
    $NET     = Executar "Interfaces de Rede" { Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.MACAddress } }$PNP_ERR = Executar "Barramento PnP e Conflitos" {
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
    }$TPM     = Executar "Cripto-processador (TPM)" { Get-Tpm -ErrorAction Stop }
    $SB      = Executar "Validacao Secure Boot" { Confirm-SecureBootUEFI -ErrorAction Stop }
    $SMART   = Executar "Telemetria de Confiabilidade SMART" {
        Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop
    }

    Salvar-Json $CS    (Join-Path$script:Pastas.Bruto 'computer_system.json')
    Salvar-Json $CSP   (Join-Path$script:Pastas.Bruto 'computer_system_product.json')
    Salvar-Json $BIOS  (Join-Path$script:Pastas.Bruto 'bios.json')
    Salvar-Json $BB    (Join-Path$script:Pastas.Bruto 'baseboard.json')
    Salvar-Csv  $CPU   (Join-Path$script:Pastas.Bruto 'cpu.csv')
    Salvar-Csv  $MEM   (Join-Path$script:Pastas.Bruto 'memoria.csv')
    Salvar-Csv  $DISK  (Join-Path$script:Pastas.Bruto 'discos.csv')
    Salvar-Csv  $PART  (Join-Path$script:Pastas.Bruto 'particoes.csv')
    Salvar-Csv  $VID   (Join-Path$script:Pastas.Bruto 'video.csv')
    Salvar-Csv  $NET   (Join-Path$script:Pastas.Bruto 'rede.csv')
    Salvar-Csv  $PNP_ERR (Join-Path$script:Pastas.Bruto 'dispositivos_com_erro.csv')
    Salvar-Csv  $SMART (Join-Path$script:Pastas.Bruto 'smart_confiabilidade.csv')

    $RamTotalGB = if ($MEM) { [math]::Round(($MEM | Measure-Object Capacity -Sum).Sum / 1GB, 1) } else {$null }

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
        'TPM presente'         = if ($TPM) {$TPM.TpmPresent } else { '-' }
        'TPM pronto'           = if ($TPM) {$TPM.TpmReady } else { '-' }
        'Secure Boot ativo'    = if ($null -ne $SB) {$SB } else { '-' }
        'Dispositivos com erro'= if ($PNP_ERR) { ($PNP_ERR | Measure-Object).Count } else { 0 }
    }
    Escrever-TabelaMd -Campos $ResumoHardware -Titulo 'Inventario de Hardware' |
        Out-File (Join-Path $script:Pastas.Hardware 'RESUMO_HARDWARE.md') -Encoding UTF8

    if ($PNP_ERR) {
        $linhasErro =$PNP_ERR | ForEach-Object { "- **$($_.Name)** - codigo $($_.ConfigManagerErrorCode) ($($_.DeviceID))" }
        "## Dispositivos com erro de barramento`n`n$($linhasErro -join "`n")" |
            Out-File (Join-Path $script:Pastas.Hardware 'dispositivos_com_erro.md') -Encoding UTF8
    }

    $script:Dados['CS'] = $CS
    $script:Dados['BIOS'] = $BIOS
    $script:Dados['BB'] = $BB
    $script:Dados['CPU'] = $CPU
    $script:Dados['MEM'] = $MEM
    $script:Dados['DISK'] = $DISK
    $script:Dados['PART'] = $PART
    $script:Dados['VID'] = $VID
    $script:Dados['NET'] = $NET
    $script:Dados['PNP_ERR'] = $PNP_ERR
    Marcar 'Hardware'
}

function Invoke-PowercfgSeguro {
    <#
    .SYNOPSIS
      Executa o utilitário powercfg com limites de timeout rigorosos. Prevê casos de congelamento em comunicação I2C/SMBus.
    #>
    param([string]$ArgLinha, [int]$TimeoutSeg = 30)
    try {
        $p = Start-Process -FilePath 'powercfg' -ArgumentList $ArgLinha -PassThru -WindowStyle Hidden -ErrorAction Stop
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $p.HasExited -and $sw.Elapsed.TotalSeconds -lt $TimeoutSeg) { Start-Sleep -Milliseconds 400 }
        if (-not $p.HasExited) { try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}; return 'TIMEOUT' }
        if ($null -ne $p.ExitCode -and $p.ExitCode -ne 0) { return "ERRO(cod $($p.ExitCode))" }
        return 'OK'
    } catch { return "ERRO($($_.Exception.Message))" }
}

function Parse-BatteryReportXml {
    <#
    .SYNOPSIS
      Desestrutura o relatório XML de bateria independente de namespace XML.
    #>
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

function Parse-HtmlSectionRows {
    <#
    .SYNOPSIS
      Analisa estrutura de tabelas em documentos HTML para extração de arrays limpos.
    #>
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
    Log ">> Executando módulo de Subsistema de Energia (BMS)..." 'Cyan'

    $BatWin32   = Executar "Telemetria de Estado WMI (Win32_Battery)" { Get-CimInstance Win32_Battery -ErrorAction Stop }
    $BatStatic  = Executar "Registradores OEM (BatteryStaticData)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop }
    $BatFull    = Executar "Acumuladores (BatteryFullChargedCapacity)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop }
    $BatStatus  = Executar "Sensores de Tensão (BatteryStatus)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction Stop }
    $BatCycle   = Executar "Contadores de Ciclo (BatteryCycleCount)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryCycleCount -ErrorAction Stop }
    $BatTemp    = Executar "Termistores de Bateria (BatteryTemperature)" { Get-CimInstance -Namespace root\wmi -ClassName BatteryTemperature -ErrorAction Stop }

    Salvar-Json $BatWin32  (Join-Path $script:Pastas.Bruto 'bateria_win32.json')
    Salvar-Json $BatStatic (Join-Path $script:Pastas.Bruto 'bateria_static_data.json')
    Salvar-Json $BatFull   (Join-Path $script:Pastas.Bruto 'bateria_full_charged.json')
    Salvar-Json $BatStatus (Join-Path $script:Pastas.Bruto 'bateria_status.json')
    Salvar-Json $BatCycle  (Join-Path $script:Pastas.Bruto 'bateria_ciclos.json')
    Salvar-Json $BatTemp   (Join-Path $script:Pastas.Bruto 'bateria_temperatura.json')

    $htmlPath   = Join-Path $script:Pastas.Bateria 'battery-report.html'
    $xmlPath    = Join-Path $script:Pastas.Bateria 'battery-report.xml'
    $energyPath = Join-Path $script:Pastas.Bateria 'energy-report.html'
    $stBatHtml = '-'; $stBatXml = '-'; $stEnergy = '-'
    
    if ($script:ModoAoVivo) {
        Log "Submetendo comandos nativos de diagnóstico powercfg..." 'Cyan'
        $stBatHtml = Invoke-PowercfgSeguro "/batteryreport /output `"$htmlPath`"" 30
        $stBatXml  = Invoke-PowercfgSeguro "/batteryreport /output `"$xmlPath`" /xml" 30
        $stEnergy  = Invoke-PowercfgSeguro "/energy /output `"$energyPath`" /duration 5" 60
        Log "Resultado processos: HTML=$stBatHtml | XML=$stBatXml | ENERGY=$stEnergy" 'Gray'
    } else {
        Log "[INFO] O mapeamento powercfg requer serviços de Kernel online e será suprimido no modelo WinPE." 'DarkGray'
    }

    $xmlParsed = $null
    if (Test-Path $xmlPath) { $xmlParsed = Executar "Parse do report consolidado em XML" { Parse-BatteryReportXml $xmlPath } }
    if ($xmlParsed) { Salvar-Json $xmlParsed (Join-Path $script:Pastas.Bruto 'battery_report_parsed.json') }

    $htmlContent = $null
    if (Test-Path $htmlPath) { try { $htmlContent = Get-Content $htmlPath -Raw -ErrorAction Stop } catch {} }

    $capHist = @()
    if ($htmlContent) {
        $capHist = @(Parse-HtmlSectionRows $htmlContent 'Battery capacity history' 'Battery life estimates|</body>') |
            Where-Object { $_.Count -ge 3 -and $_[0] -match '\d{4}' }
    }
    if ($capHist.Count -gt 0) {
        $capObj = $capHist | ForEach-Object { [PSCustomObject]@{ Periodo = $_[0]; CapacidadeCheia = $_[1]; CapacidadeProjeto = $_[2] } }
        Salvar-Csv $capObj (Join-Path $script:Pastas.Bateria 'historico_capacidade.csv')
    }

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

    $b0 = $null
    if ($xmlParsed -and $xmlParsed.Baterias.Count -gt 0) { $b0 = $xmlParsed.Baterias[0] }
    function Xget {
        param($obj, [string]$p)
        if ($obj -and $obj.PSObject.Properties[$p]) { return $obj.$p }
        return $null
    }
    function Vazio {
        param($v)
        return ($null -eq $v -or "$v".Trim() -eq '')
    }

    $stManu    = ($BatStatic | Select-Object -First 1).ManufactureName
    $stChem    = ($BatStatic | Select-Object -First 1).Chemistry
    $stSerial  = ($BatStatic | Select-Object -First 1).SerialNumber
    $stMfgDate = ($BatStatic | Select-Object -First 1).ManufactureDate
    $stDesignV = ($BatStatic | Select-Object -First 1).DesignedVoltage
    $stDesignC = ($BatStatic | Select-Object -First 1).DesignedCapacity
    $fullC     = ($BatFull   | Select-Object -First 1).FullChargedCapacity
    $cyc       = ($BatCycle  | Select-Object -First 1).CycleCount

    if ($b0) {
        if (Vazio $stManu)    { $stManu    = Xget $b0 'Manufacturer' }
        if (Vazio $stChem)    { $stChem    = Xget $b0 'Chemistry' }
        if (Vazio $stSerial)  { $stSerial  = Xget $b0 'SerialNumber' }
        if (Vazio $stMfgDate) { $stMfgDate = Xget $b0 'ManufactureDate' }
        if ((Vazio $stDesignC) -or ($stDesignC -eq 0)) { $x = Xget $b0 'DesignCapacity'; if (-not (Vazio $x)) { $stDesignC = $x } }
        if (Vazio $fullC)     { $x = Xget $b0 'FullChargeCapacity'; if (-not (Vazio $x)) { $fullC = $x } }
        if (Vazio $cyc)       { $x = Xget $b0 'CycleCount'; if (-not (Vazio $x)) { $cyc = $x } }
    }

    $DesgastePct = $null
    if ($b0) { $DesgastePct = Xget $b0 'WearPct' }
    if ($null -eq $DesgastePct) {
        $dcv = [int64]0; $fcv = [int64]0
        [void][int64]::TryParse(("$stDesignC" -replace '[^\d]', ''), [ref]$dcv)
        [void][int64]::TryParse(("$fullC" -replace '[^\d]', ''), [ref]$fcv)
        if ($dcv -gt 0 -and $fcv -gt 0) { $DesgastePct = [math]::Round((1 - ($fcv / $dcv)) * 100, 1) }
    }

    $mb = New-Object System.Text.StringBuilder
    [void]$mb.AppendLine("# Matriz Analítica do Controlador BMS`n")
    [void]$mb.AppendLine("_Atualizado: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')_`n")

    [void]$mb.AppendLine("## Processos Powercfg`n")
    [void]$mb.AppendLine("| Relatorio | Status |")
    [void]$mb.AppendLine("| --- | --- |")
    [void]$mb.AppendLine("| battery-report.html | $stBatHtml |")
    [void]$mb.AppendLine("| battery-report.xml  | $stBatXml |")
    [void]$mb.AppendLine("| energy-report.html  | $stEnergy |")
    [void]$mb.AppendLine("")
    
    $temBateria = [bool]$BatWin32
    $runTime = ($BatWin32 | Select-Object -First 1).EstimatedRunTime
    $ResumoBateria = [ordered]@{
        'Interface BMS Detectada'      = if ($temBateria) { 'Ativa' } else { 'Inativa (Desktop / Falha Barramento)' }
        'Fabricante'                   = $stManu
        'Quimica'                      = $stChem
        'Numero de serie'              = $stSerial
        'Data de fabricacao'           = $stMfgDate
        'Tensao de projeto (mV)'       = $stDesignV
        'Capacidade de projeto (mWh)'  = $stDesignC
        'Capacidade cheia atual (mWh)' = $fullC
        'Desgaste estrutural'          = if ($null -ne $DesgastePct) { "$DesgastePct%" } else { '-' }
        'Ciclos contados'              = $cyc
        'Fonte preferencial'           = if ($b0) { 'XML/Powercfg' } else { 'WMI Nativo' }
        'Vetor (Win32_Battery)'        = ($BatWin32 | Select-Object -First 1).Status
        'Carga nominal (%)'            = ($BatWin32 | Select-Object -First 1).EstimatedChargeRemaining
        'Autonomia estimada (min)'     = $(if ($runTime -and $runTime -lt 71582788) { $runTime } else { '- (AC/Linha)' })
        'Temperatura'                  = if ($BatTemp) { ($BatTemp | Select-Object -First 1).Temperature } else { 'Sensor Offline' }
    }
    [void]$mb.AppendLine((Escrever-TabelaMd -Campos $ResumoBateria -Titulo 'Indicadores Sintéticos WMI'))

    if ($xmlParsed -and $xmlParsed.Baterias.Count -gt 0) {
        $i = 0
        foreach ($bat in $xmlParsed.Baterias) {
            $i++
            $campos = [ordered]@{}
            foreach ($pn in $bat.PSObject.Properties.Name) { $campos[$pn] = $bat.$pn }
            [void]$mb.AppendLine((Escrever-TabelaMd -Campos $campos -Titulo "Estrutura XML da Bateria #$i"))
        }
    }

    if ($capHist.Count -gt 0) {
        [void]$mb.AppendLine("## Tabela de Degradação de Capacidade`n")
        [void]$mb.AppendLine("| Periodo | Capacidade cheia | Capacidade de projeto |")
        [void]$mb.AppendLine("| --- | --- | --- |")
        foreach ($r in $capHist) { [void]$mb.AppendLine("| $($r[0]) | $($r[1]) | $($r[2]) |") }
        [void]$mb.AppendLine("")
    }

    if ($script:ModoAoVivo) {
        $plano = Executar "Identificacao do Modelo Termal e Energia" { powercfg /getactivescheme | Out-String }
        if ($plano) {
            [void]$mb.AppendLine("## Esquema Ativo de Gerenciamento de Energia`n")
            [void]$mb.AppendLine('```text')
            [void]$mb.AppendLine($plano.Trim())
            [void]$mb.AppendLine('```')
            [void]$mb.AppendLine("")
        }
    }

    $mb.ToString() | Out-File (Join-Path $script:Pastas.Bateria 'RESUMO_BATERIA.md') -Encoding UTF8

    $SystemEvtx = Join-Path $script:Pastas.EventLogs 'System.evtx'
    if (Test-Path $SystemEvtx) {
        $EventosBateria = Executar "Parseamento do kernel em eventos de gerenciamento termal/energia" {
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
    $script:Dados['Ciclos'] = $cyc
    Marcar 'Bateria'
}

function Coletar-Drivers {
    Detectar-Ambiente
    if (-not $script:WinDrive) { Log "[ABORTADO] Drivers - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo de Analise de Binarios Drivers..." 'Cyan'
    Executar "Varredura do repositório DriverStore local" {
        if (Test-Path "$($script:WinDrive)\Windows\System32\DriverStore\FileRepository") {
            Get-ChildItem "$($script:WinDrive)\Windows\System32\DriverStore\FileRepository" -ErrorAction Stop |
                Select-Object Name, LastWriteTime |
                Export-Csv (Join-Path $script:Pastas.Drivers 'driverstore.csv') -NoTypeInformation -Encoding UTF8
        }
    }
    if ($script:ModoAoVivo) {
        Executar "Extracao da arvore hierarquica VQuery (DriverQuery)" {
            $out = & driverquery /v /fo csv 2>$null
            if ($out) { $out | Out-File (Join-Path $script:Pastas.Drivers 'drivers_ativos.csv') -Encoding UTF8 }
        }
    }
    Marcar 'Drivers'
}

# ============================================================
#  EXPORTAÇÃO DE DADOS MESTRE
# ============================================================

function Gerar-ArquivoJson {
    <#
    .SYNOPSIS
      Exporta todos os conjuntos de dados carregados na memória do script para um JSON mestre padronizado.
    #>
    Detectar-Ambiente
    Log ">> Iniciando compilação do arquivo estruturado (JSON)..." 'Cyan'
    $JsonPath = Join-Path $script:Pastas.Resumo 'coleta_consolidada.json'

    $Payload = [ordered]@{
        Metadados = [ordered]@{
            DataColeta = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
            Ambiente = if ($script:ModoAoVivo) { 'Online' } elseif ($script:WinDrive) { 'Offline' } else { 'WinPE_SemWindows' }
            UnidadeWindows = $script:WinDrive
            ColetasRealizadas = $script:Executadas
        }
        Registro = $script:Dados['InfoWindows']
        Boot = [ordered]@{
            EventosCriticos = $script:Dados['nCriticos']
        }
        Hardware = [ordered]@{
            Sistema = $script:Dados['CS']
            PlacaMae = $script:Dados['BB']
            Processador = $script:Dados['CPU']
            Memoria = $script:Dados['MEM']
            BIOS = $script:Dados['BIOS']
            Discos = $script:Dados['DISK']
            Particoes = $script:Dados['PART']
            Video = $script:Dados['VID']
            Rede = $script:Dados['NET']
            DispositivosErro = $script:Dados['PNP_ERR']
        }
        Bateria = [ordered]@{
            DesgastePercentual = $script:Dados['DesgastePct']
            Ciclos = $script:Dados['Ciclos']
            TelemetriaWMI = $script:Dados['BatCycle']
            EventosEnergia = $script:Dados['nBateria']
        }
    }

    Executar "Gravacao do JSON estruturado (Payload)" {
        $Payload | ConvertTo-Json -Depth 10 | Out-File -FilePath $JsonPath -Encoding UTF8
    }
}

function Gerar-ResumoGeral {
    Detectar-Ambiente
    Log ">> Gerando o mapa central Markdown (Resumo Geral)..." 'Cyan'

    $CS      = $script:Dados['CS']
    $BIOS    = $script:Dados['BIOS']
    $DISK    = $script:Dados['DISK']
    $PNP_ERR = $script:Dados['PNP_ERR']
    $InfoWindowsInstalado = $script:Dados['InfoWindows']
    $DesgastePct = $script:Dados['DesgastePct']
    $BatCycle = $script:Dados['BatCycle']
    $nCriticos = if ($script:Dados['nCriticos']) { $script:Dados['nCriticos'] } else { 0 }
    $nBateria  = if ($script:Dados['nBateria'])  { $script:Dados['nBateria'] }  else { 0 }

    $md = New-Object System.Text.StringBuilder
    [void]$md.AppendLine("# Diagnóstico Master Field")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("_Compilado às $(Get-Date -Format 'dd/MM/yyyy, HH:mm')  -  Runtime Env: $(if ($script:ModoAoVivo) { 'SO Nativo/Online' } elseif ($script:WinDrive) { 'SO Inativo/Offline' } else { 'Firmware Limitado/WinPE' })_")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("Modulos Executados: $((@($script:Executadas) | Sort-Object) -join ', ')")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Identificacao do Ativo")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("| Campo | Valor |")
    [void]$md.AppendLine("| --- | --- |")
    [void]$md.AppendLine("| Fabricante / Modelo | $($CS.Manufacturer) $($CS.Model) |")
    [void]$md.AppendLine("| Numero de serie | $($BIOS.SerialNumber) |")
    [void]$md.AppendLine("| Diretório raiz sistema | $(if ($script:WinDrive) { $script:WinDrive } else { 'FALHA DE ALOCAÇAO' }) |")
    if ($InfoWindowsInstalado -and $InfoWindowsInstalado.Count -gt 0) {
        [void]$md.AppendLine("| Windows OS | $($InfoWindowsInstalado['Produto']) $($InfoWindowsInstalado['Versao']) (Build $($InfoWindowsInstalado['Build'])) |")
        if ($InfoWindowsInstalado['Ultimo desligamento registrado']) {
            [void]$md.AppendLine("| Ultimo shutdown verificado | $($InfoWindowsInstalado['Ultimo desligamento registrado']) |")
        }
    }
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Análise de Estabilidade")
    [void]$md.AppendLine("")
    $nDumps = (Get-ChildItem $script:Pastas.Dumps -Recurse -File -ErrorAction SilentlyContinue | Measure-Object).Count
    [void]$md.AppendLine("- Eventos críticos de kernel/energia reportados: $nCriticos")
    [void]$md.AppendLine("- Endereçamento Dump gerado: $nDumps arquivo(s) localizados")
    [void]$md.AppendLine("- Dispositivos de barramento instáveis: $(if ($PNP_ERR) { ($PNP_ERR | Measure-Object).Count } else { 0 })")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Telemetria de BMS e Energia")
    [void]$md.AppendLine("")
    $ciclosResumo = if ($null -ne $script:Dados['Ciclos'] -and "$($script:Dados['Ciclos'])" -ne '') { $script:Dados['Ciclos'] } elseif ($BatCycle) { ($BatCycle | Select-Object -First 1).CycleCount } else { '-' }
    [void]$md.AppendLine("- Desgaste de células reportado: $(if ($null -ne $DesgastePct) { "$DesgastePct%" } else { '-' })")
    [void]$md.AppendLine("- Total de ciclos consumidos: $ciclosResumo")
    [void]$md.AppendLine("- Registro de anomalias energéticas: $nBateria eventos")
    [void]$md.AppendLine("")
    [void]$md.AppendLine("## Mapeamento de Arrays Físicos")
    [void]$md.AppendLine("")
    if ($DISK) {
        foreach ($d in $DISK) {
            [void]$md.AppendLine("- $($d.Model) - $([math]::Round($d.Size/1GB,0)) GB, Firmware Report: $($d.Status)")
        }
    }
    
    $md.ToString() | Out-File (Join-Path $script:Pastas.Resumo 'RESUMO_GERAL.md') -Encoding UTF8
}

function Compactar-Zip {
    Detectar-Ambiente
    Executar "Compactacao de fluxo em extensao .ZIP" {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $modelo = if ($script:Dados['CS']) { $script:Dados['CS'].Model } else { 'target' }
        $nomeZip = ("coletadiag_{0}_{1}.zip" -f ($modelo -replace '[^\w\-]', '_'), $Timestamp) -replace '_+', '_'
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
                    Log "[FALHOU] Erro de compressão no arquivo '$rel' -> $($_.Exception.Message)" 'Yellow'
                }
            }
        } finally { $zip.Dispose() }
        Log "Arquivo Master ZIP gerado na arvore hierarquica: $zipPath" 'Green'
    }
}

function Coletar-Completa {
    Log "===== INIT: BATCH DE COLETA COMPLETA =====" 'Cyan'
    Coletar-EventLogs
    Coletar-Panther
    Coletar-Boot
    Coletar-Dumps
    Coletar-Registro
    Coletar-Hardware
    Coletar-Bateria
    Coletar-Drivers
    Gerar-ResumoGeral
    Gerar-ArquivoJson
    if (-not $SemZip) { Compactar-Zip }
}

# ============================================================
#  ROTEAMENTO DE MENU INTERATIVO E EXECUÇÃO
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
        default { Log "[ALERTA] Roteamento desconhecido pelo switch regex: '$Nome'" 'Yellow' }
    }
}

function Mostrar-Menu {
    Detectar-Ambiente
    $amb = "Volume Local Windows NAO encontrado (Firmware Scan Only)"
    if ($script:WinDrive) {
        if ($script:ModoAoVivo)  { $amb = "Status: Online | Volume Base: $($script:WinDrive)" }
        elseif ($script:IsWinPE) { $amb = "Status: WinPE | Volume Base Inativo: $($script:WinDrive)" }
        else                     { $amb = "Status: Offline | Volume Base: $($script:WinDrive)" }
    } elseif ($script:IsWinPE) {
        $amb = "Status: WinPE | Volume Local Windows NAO encontrado"
    }

    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   SUBSISTEMA DE COLETA DE DIAGNOSTICO DE CAMPO" -ForegroundColor Cyan
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   Telemetria Atual : $amb"
    Write-Host "   Diretório de I/O : $Destino"
    Write-Host "----------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "   [1] BATCH COMPLETO DE DIAGNÓSTICO (Rotina Integral)" -ForegroundColor Green
    Write-Host "   ----------------------------------------------------------"
    Write-Host "   [2] Módulo: Event Logs Genéricos (.evtx)"
    Write-Host "   [3] Módulo: Auditoria Panther e Configurações (Setup Logs)"
    Write-Host "   [4] Módulo: Kernel Boot Logs e Desligamentos Inesperados"
    Write-Host "   [5] Módulo: Crash Dumps (Memory.dmp, Minidumps, Relatórios WER)"
    Write-Host "   [6] Módulo: Colmeias do Registro, Controle e Serviços"
    Write-Host "   [7] Módulo: Mapa Físico e Inventário de Hardware Estrutural"
    Write-Host "   [8] Módulo: Bateria, Degradação e Subsistema BMS"
    Write-Host "   [9] Módulo: Árvores de Repositórios de Drivers"
    Write-Host "   ----------------------------------------------------------"
    Write-Host "   [J] Exportar JSON Mestre e consolidar dados na memória"
    Write-Host "   [D] Alterar destino de alocação de saída"
    Write-Host "   [R] Renderizar novo relatório analítico Markdown (Resumo)"
    Write-Host "   [Z] Disparar rotina de compressão ZIP do diretório atual"
    Write-Host "   [0] Encerrar e Sair"
    Write-Host "================================================================" -ForegroundColor Cyan
    Write-Host "   Dica de sintaxe CLI: Insira tarefas intercaladas, ex.: 2,4,7" -ForegroundColor DarkGray
}

function Loop-Menu {
    while ($true) {
        Mostrar-Menu
        $entrada = Read-Host "Input"
        if ($null -eq $entrada) { break }
        $entrada = $entrada.Trim()
        if ($entrada -eq '') { continue }
        $up = $entrada.ToUpper()

        if ($up -eq '0' -or $up -eq 'Q') { Log "Protocolo de desligamento de script acionado." 'Cyan'; return }

        if ($up -eq 'D') {
            $novo = Read-Host "Insira novo caminho estrito (ex: D:\Coleta_Diag)"
            if ($novo -and $novo.Trim() -ne '') {
                Set-Variable -Name Destino -Value ($novo.Trim()) -Scope Script
                $script:Pastas = $null
                $script:AmbienteOk = $false
                $script:LogFile = $null
                Detectar-Ambiente
            }
            continue
        }

        if ($up -eq 'R') { Gerar-ResumoGeral; Read-Host "Retornando. ENTER" | Out-Null; continue }
        if ($up -eq 'Z') { Compactar-Zip;     Read-Host "Retornando. ENTER" | Out-Null; continue }
        if ($up -eq 'J') { Gerar-ArquivoJson; Read-Host "JSON gravado com sucesso. Retornando. ENTER" | Out-Null; continue }

        $itens = $entrada -split '[,; ]+' | Where-Object { $_ -ne '' }
        foreach ($it in $itens) { Executar-Tarefa $it }

        if ($itens -notcontains '1') { Gerar-ResumoGeral }

        Write-Host ""
        Read-Host "Tolerancia de thread terminada. ENTER para liberar menu." | Out-Null
    }
}

# ============================================================
#  INICIALIZAÇÃO BASE E DISPATCHER DE ARGUMENTOS
# ============================================================
if (-not $Destino) {
    $raizAuto = Selecionar-DestinoAuto
    if ($raizAuto) {
        $Destino = Join-Path ($raizAuto + '\') "ColetasDiag\target_$Timestamp"
    } else {
        $Destino = Join-Path $ScriptRoot "target_$Timestamp"
    }
}

Detectar-Ambiente

if ($Auto) { $Tarefas = @('Completa') }

if ($Tarefas -and $Tarefas.Count -gt 0) {
    foreach ($t in $Tarefas) { Executar-Tarefa $t }
    if ($Tarefas -notcontains 'Completa' -and $Tarefas -notcontains 'Tudo' -and $Tarefas -notcontains '1') {
        Gerar-ResumoGeral
        Gerar-ArquivoJson
        if (-not $SemZip) { Compactar-Zip }
    }
} else {
    Loop-Menu
}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "  PROCESSO CONCLUIDO. Alocado no espaco: $Destino" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
