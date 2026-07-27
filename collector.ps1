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
$DestinoFoiInformado = $PSBoundParameters.ContainsKey('Destino')

$ScriptRoot = $null
$ScriptPath = $MyInvocation.MyCommand.Path
if ($ScriptPath) { $ScriptRoot = Split-Path -Parent $ScriptPath }
if (-not $ScriptRoot) { $ScriptRoot = (Get-Location).Path }
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'

$script:Dados      = [ordered]@{}
$script:Executadas = New-Object System.Collections.ArrayList

function Marcar {
    param([string]$Nome)
    if (-not $script:Executadas.Contains($Nome)) { [void]$script:Executadas.Add($Nome) }
}

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
        if ($null -eq $v -or ($v -is [string] -and $v.Trim() -eq '')) { $v = '-' }
        [void]$sb.AppendLine("| $k | $v |")
    }
    return $sb.ToString()
}

$script:Pastas    = $null
$script:WinDrive  = $null
$script:IsWinPE   = $false
$script:ModoAoVivo= $false
$script:AmbienteOk= $false

function Selecionar-DestinoAuto {
    $cands = @()
    try {
        $vols = Get-CimInstance Win32_LogicalDisk -ErrorAction Stop | Where-Object { $_.DriveType -eq 2 -or $_.DriveType -eq 3 }
        foreach ($v in $vols) {
            if ($v.DeviceID -eq 'X:') { continue }
            if (-not $v.FreeSpace) { continue }
            $cands += [PSCustomObject]@{ Letra = $v.DeviceID; Livre = [int64]$v.FreeSpace; Tipo = [int]$v.DriveType }
        }
    } catch {}

    $cands = $cands | Sort-Object @{ Expression = { if ($_.Tipo -eq 2) { 0 } else { 1 } } }, @{ Expression = { $_.Livre }; Descending = $true }

    foreach ($c in $cands) {
        if ($c.Livre -lt 200MB) { continue }
        $teste = Join-Path ($c.Letra + '\') ('._coleta_test_' + $Timestamp)
        try {
            New-Item -ItemType Directory -Path $teste -Force -ErrorAction Stop | Out-Null
            Remove-Item $teste -Recurse -Force -ErrorAction SilentlyContinue
            $gb = [math]::Round($c.Livre / 1GB, 1)
            $tipoTxt = if ($c.Tipo -eq 2) { 'USB/Removivel' } else { 'Disco Local' }
            Log "Destino automatico: $($c.Letra) ($tipoTxt, $gb GB livres)" 'Green'
            return $c.Letra
        } catch { continue }
    }
    return $null
}

function Inicializar-Destino {
    if ($script:Pastas) { return }

    $DriveDestino = $null
    try { $DriveDestino = (Split-Path -Qualifier $Destino -ErrorAction Stop) } catch {}
    if (-not $DestinoFoiInformado -and $DriveDestino -eq 'X:') {
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
    foreach ($p in $script:Pastas.Values) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    $script:LogFile = Join-Path $Destino 'coleta_diagnostico.log'
    Log "Diretorio Alvo: $Destino" 'Cyan'
    Escrever-Visualizador
}

function Escrever-Visualizador {
    <#
    .SYNOPSIS
      Grava o visualizador HTML (navegacao completa, tema claro/escuro, estilo shadcn) na raiz do
      diretorio de coleta, para que va junto no arquivo compactado final.
    #>
    if ($script:VisualizadorGravado) { return }
    $destHtml = Join-Path $Destino 'visualizador.html'
    Executar "Gravacao do visualizador HTML na raiz da coleta" {
        $htmlContent | Out-File -FilePath $destHtml -Encoding UTF8 -Force
    } -Silencioso | Out-Null
    $script:VisualizadorGravado = $true
}

function Gerar-DadosEmbutidos {
    <#
    .SYNOPSIS
      Varre os arquivos de texto ja coletados (JSON, CSV, MD, TXT, LOG, XML, HTML) e embute o
      conteudo de todos eles num unico 'dados.js', que define window.EMBEDDED_DATA. Com isso, o
      visualizador.html abre com duplo-clique e carrega tudo automaticamente, sem o usuario precisar
      selecionar a pasta. Arquivos binarios (evtx, dmp) sao referenciados como null (metadados apenas).
    #>
    Detectar-Ambiente
    Log ">> Embutindo dados coletados no visualizador (dados.js)..." 'Cyan'
    $jsPath = Join-Path $Destino 'dados.js'

    $extTexto = @('.json', '.csv', '.md', '.txt', '.log', '.xml', '.html', '.htm', '.ini', '.reg')
    $extBinRef = @('.evtx', '.dmp')          # referenciados, mas conteudo nao embutido
    $limiteBytes = 6MB                        # trava por arquivo, evita estourar memoria do navegador

    Executar "Serializacao dos artefatos em dados.js" {
        $baseLen = $Destino.TrimEnd('\').Length + 1
        $rootName = Split-Path $Destino -Leaf

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("window.EMBEDDED_DATA = {")
        [void]$sb.AppendLine("  rootName: $($rootName | ConvertTo-Json),")
        [void]$sb.AppendLine("  files: {")

        $arquivos = Get-ChildItem $Destino -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'dados.js' -and $_.Name -ne 'visualizador.html' }

        $primeiro = $true
        foreach ($arq in $arquivos) {
            $rel = ($rootName + '\' + $arq.FullName.Substring($baseLen)) -replace '\\', '/'
            $ext = $arq.Extension.ToLower()
            $chaveJson = $rel | ConvertTo-Json

            if (-not $primeiro) { [void]$sb.AppendLine(",") }
            $primeiro = $false

            if ($extBinRef -contains $ext) {
                [void]$sb.Append("    $chaveJson`: null")
            } elseif (($extTexto -contains $ext) -and ($arq.Length -le $limiteBytes)) {
                try {
                    $conteudo = [System.IO.File]::ReadAllText($arq.FullName, [System.Text.Encoding]::UTF8)
                    $valJson = $conteudo | ConvertTo-Json
                    [void]$sb.Append("    $chaveJson`: $valJson")
                } catch {
                    [void]$sb.Append("    $chaveJson`: null")
                }
            } else {
                # arquivo grande ou tipo nao textual -> apenas referencia
                [void]$sb.Append("    $chaveJson`: null")
            }
        }

        [void]$sb.AppendLine("")
        [void]$sb.AppendLine("  }")
        [void]$sb.AppendLine("};")

        [System.IO.File]::WriteAllText($jsPath, $sb.ToString(), (New-Object System.Text.UTF8Encoding($false)))

        # Injeta a referencia ao dados.js no HTML (uma unica vez), antes do </head>
        $destHtml = Join-Path $Destino 'visualizador.html'
        if (Test-Path $destHtml) {
            $htmlAtual = [System.IO.File]::ReadAllText($destHtml, [System.Text.Encoding]::UTF8)
            if ($htmlAtual -notmatch 'src="dados\.js"') {
                $htmlAtual = $htmlAtual -replace '</head>', '<script src="dados.js"></script></head>'
                [System.IO.File]::WriteAllText($destHtml, $htmlAtual, (New-Object System.Text.UTF8Encoding($false)))
            }
        }
        $tam = [math]::Round((Get-Item $jsPath).Length / 1MB, 2)
        Log "dados.js gerado ($tam MB). Abra visualizador.html com duplo-clique." 'Green'
    }
}

$htmlContent = @'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Visualizador de Diagnóstico</title>
<style>
  :root{
    --background:0 0% 100%; --foreground:240 10% 3.9%;
    --card:0 0% 100%; --card-foreground:240 10% 3.9%;
    --border:240 5.9% 90%; --input:240 5.9% 90%;
    --primary:240 5.9% 10%; --primary-foreground:0 0% 98%;
    --secondary:240 4.8% 95.9%; --secondary-foreground:240 5.9% 10%;
    --muted:240 4.8% 95.9%; --muted-foreground:240 3.8% 46.1%;
    --accent:240 4.8% 95.9%; --accent-foreground:240 5.9% 10%;
    --destructive:0 72% 51%; --destructive-foreground:0 0% 98%;
    --success:142 71% 35%; --warning:38 92% 45%;
    --ring:240 5.9% 10%;
    --radius:0.6rem;
    --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace;
    --sans:ui-sans-serif,-apple-system,'Segoe UI',Inter,Roboto,sans-serif;
  }
  html.dark{
    --background:240 10% 5.5%; --foreground:0 0% 96%;
    --card:240 8% 8%; --card-foreground:0 0% 96%;
    --border:240 6% 16%; --input:240 6% 16%;
    --primary:0 0% 96%; --primary-foreground:240 6% 10%;
    --secondary:240 6% 14%; --secondary-foreground:0 0% 96%;
    --muted:240 6% 13%; --muted-foreground:240 5% 62%;
    --accent:240 6% 14%; --accent-foreground:0 0% 96%;
    --destructive:0 63% 48%; --destructive-foreground:0 0% 98%;
    --success:142 62% 45%; --warning:38 92% 55%;
    --ring:240 5% 70%;
  }
  *{box-sizing:border-box; border-color:hsl(var(--border))}
  html,body{height:100%}
  body{
    margin:0; background:hsl(var(--background)); color:hsl(var(--foreground));
    font-family:var(--sans); font-size:14px; line-height:1.55;
    transition:background .15s,color .15s;
  }
  a{color:inherit}
  ::selection{background:hsl(var(--foreground)/.15)}
  code, .mono{font-family:var(--mono)}
  svg{width:1em; height:1em; flex-shrink:0}
  ::-webkit-scrollbar{width:10px; height:10px}
  ::-webkit-scrollbar-thumb{background:hsl(var(--border)); border-radius:8px}
  ::-webkit-scrollbar-track{background:transparent}

  /* --- layout --- */
  #app{display:flex; height:100vh; overflow:hidden}
  #sidebar{
    width:272px; min-width:272px; border-right:1px solid hsl(var(--border));
    display:flex; flex-direction:column; background:hsl(var(--card));
  }
  #sidebar .brand{
    padding:16px 18px; border-bottom:1px solid hsl(var(--border));
    display:flex; align-items:center; gap:9px;
  }
  #sidebar .brand .logo{
    width:26px; height:26px; border-radius:7px; background:hsl(var(--primary));
    display:flex; align-items:center; justify-content:center; flex-shrink:0;
  }
  #sidebar .brand .logo svg{width:14px !important; height:14px !important; stroke:hsl(var(--primary-foreground))}
  #sidebar .brand .txt{line-height:1.2}
  #sidebar .brand .txt b{font-size:13px; font-weight:600; display:block}
  #sidebar .brand .txt span{font-size:11px; color:hsl(var(--muted-foreground))}

  #navwrap{flex:1; overflow-y:auto; padding:10px}
  .navgroup{margin-bottom:14px}
  .navgroup-label{
    font-size:10.5px; font-weight:600; text-transform:uppercase; letter-spacing:.06em;
    color:hsl(var(--muted-foreground)); padding:6px 10px 4px;
  }
  .navitem{
    display:flex; align-items:center; justify-content:space-between; gap:8px;
    padding:7px 10px; border-radius:calc(var(--radius) - 2px); cursor:pointer; font-size:13px;
    color:hsl(var(--foreground)/.8);
  }
  .navitem:hover{background:hsl(var(--accent))}
  .navitem.active{background:hsl(var(--secondary)); color:hsl(var(--foreground)); font-weight:500}
  .navitem .left{display:flex; align-items:center; gap:9px; overflow:hidden}
  .navitem .ic{width:15px; height:15px; flex-shrink:0; opacity:.75}
  .navitem .lbl{white-space:nowrap; overflow:hidden; text-overflow:ellipsis}
  .navitem .count{
    font-size:10.5px; color:hsl(var(--muted-foreground)); background:hsl(var(--muted));
    padding:0px 6px; border-radius:99px; flex-shrink:0;
  }
  .navitem.disabled{opacity:.4; cursor:default}
  .navitem.disabled:hover{background:transparent}

  #sidebar-foot{padding:12px; border-top:1px solid hsl(var(--border)); font-size:11px; color:hsl(var(--muted-foreground))}

  /* --- main --- */
  #main{flex:1; display:flex; flex-direction:column; min-width:0}
  #topbar{
    height:56px; min-height:56px; border-bottom:1px solid hsl(var(--border));
    display:flex; align-items:center; justify-content:space-between; padding:0 20px;
    background:hsl(var(--background)/.85); backdrop-filter:blur(6px);
  }
  #topbar .crumbs{font-size:13px; color:hsl(var(--muted-foreground))}
  #topbar .crumbs b{color:hsl(var(--foreground)); font-weight:600}
  #topbar .actions{display:flex; gap:8px; align-items:center}

  .btn{
    display:inline-flex; align-items:center; gap:6px; font-family:var(--sans);
    font-size:12.5px; font-weight:500; padding:7px 13px; border-radius:calc(var(--radius) - 2px);
    border:1px solid hsl(var(--border)); background:hsl(var(--secondary)); color:hsl(var(--secondary-foreground));
    cursor:pointer; transition:.1s;
  }
  .btn:hover{background:hsl(var(--accent))}
  .btn.primary{background:hsl(var(--primary)); color:hsl(var(--primary-foreground)); border-color:transparent}
  .btn.primary:hover{opacity:.88}
  .btn.icon{padding:7px; width:32px; height:32px; justify-content:center}
  .btn svg{width:14px; height:14px}

  #content{flex:1; overflow-y:auto; padding:26px 32px 70px}
  #content.centered{display:flex; align-items:center; justify-content:center}

  .page-head{margin-bottom:6px}
  .page-head h1{font-size:20px; font-weight:600; margin:0 0 4px; display:flex; align-items:center; gap:10px}
  .page-head h1 svg{width:22px; height:22px}
  .page-desc{
    color:hsl(var(--muted-foreground)); font-size:13px; max-width:760px; margin:0 0 22px; line-height:1.6;
    padding:12px 14px; background:hsl(var(--muted)/.5); border:1px solid hsl(var(--border)); border-radius:var(--radius);
  }
  .page-desc b{color:hsl(var(--foreground))}

  .grid{display:grid; grid-template-columns:repeat(auto-fit,minmax(230px,1fr)); gap:12px; margin-bottom:20px}
  .card{
    background:hsl(var(--card)); border:1px solid hsl(var(--border)); border-radius:var(--radius);
    padding:16px 18px;
  }
  .card h3{
    margin:0 0 12px; font-size:11.5px; font-weight:600; text-transform:uppercase; letter-spacing:.05em;
    color:hsl(var(--muted-foreground)); display:flex; align-items:center; justify-content:space-between;
  }
  .card h3 .count{font-weight:400; text-transform:none; letter-spacing:0; font-size:11px}
  .card.stat .num{font-size:26px; font-weight:700; line-height:1}
  .card.stat .lbl{font-size:11.5px; color:hsl(var(--muted-foreground)); margin-top:6px}
  .card.stat.bad .num{color:hsl(var(--destructive))}
  .card.stat.warn .num{color:hsl(var(--warning))}
  .card.stat.ok .num{color:hsl(var(--success))}

  table.kv{width:100%; border-collapse:collapse; font-size:12.5px}
  table.kv tr{border-bottom:1px solid hsl(var(--border)/.6)}
  table.kv tr:last-child{border-bottom:none}
  table.kv td{padding:6px 0; vertical-align:top}
  table.kv td.k{color:hsl(var(--muted-foreground)); width:46%; padding-right:12px}
  table.kv td.v{word-break:break-word}

  .section-title{
    font-size:12px; font-weight:600; text-transform:uppercase; letter-spacing:.05em;
    color:hsl(var(--muted-foreground)); margin:26px 0 10px;
  }

  .badge{
    display:inline-flex; align-items:center; padding:1.5px 8px; border-radius:99px; font-size:11px; font-weight:500;
  }
  .badge.ok{background:hsl(var(--success)/.13); color:hsl(var(--success))}
  .badge.warn{background:hsl(var(--warning)/.15); color:hsl(var(--warning))}
  .badge.bad{background:hsl(var(--destructive)/.13); color:hsl(var(--destructive))}
  .badge.dim{background:hsl(var(--muted)); color:hsl(var(--muted-foreground))}

  .tablewrap{border:1px solid hsl(var(--border)); border-radius:var(--radius); overflow:auto; max-height:520px; margin-bottom:16px}
  table.data{width:100%; border-collapse:collapse; font-size:12.5px}
  table.data thead th{
    position:sticky; top:0; background:hsl(var(--muted)); text-align:left; padding:8px 12px;
    font-weight:600; font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:hsl(var(--muted-foreground));
    border-bottom:1px solid hsl(var(--border)); white-space:nowrap;
  }
  table.data tbody td{padding:7px 12px; border-bottom:1px solid hsl(var(--border)/.6); white-space:nowrap; max-width:340px; overflow:hidden; text-overflow:ellipsis}
  table.data tbody tr:hover{background:hsl(var(--accent)/.5)}
  table.data tbody td.wrap{white-space:normal}

  .filebrowser{display:flex; gap:14px; align-items:flex-start}
  .filelist{
    width:280px; min-width:220px; border:1px solid hsl(var(--border)); border-radius:var(--radius);
    max-height:560px; overflow-y:auto; flex-shrink:0;
  }
  .filelist .fitem{
    display:flex; align-items:center; gap:8px; padding:8px 12px; font-size:12.5px; cursor:pointer;
    border-bottom:1px solid hsl(var(--border)/.6);
  }
  .filelist .fitem:last-child{border-bottom:none}
  .filelist .fitem:hover{background:hsl(var(--accent))}
  .filelist .fitem.active{background:hsl(var(--secondary)); font-weight:500}
  .filelist .fitem .sz{margin-left:auto; font-size:10.5px; color:hsl(var(--muted-foreground))}
  .fileview{flex:1; min-width:0}
  .fileview pre{
    background:hsl(var(--muted)/.5); border:1px solid hsl(var(--border)); border-radius:var(--radius);
    padding:14px 16px; font-size:12px; font-family:var(--mono); overflow:auto; max-height:560px; white-space:pre-wrap; word-break:break-word;
    margin:0;
  }
  .binary-note{
    display:flex; gap:12px; align-items:flex-start; padding:16px; border:1px dashed hsl(var(--border));
    border-radius:var(--radius); color:hsl(var(--muted-foreground)); font-size:12.5px;
  }
  .binary-note svg{width:20px; height:20px; opacity:.6}
  #dropzone svg, .landing .logo-big svg{margin-bottom:0}
  .navitem .ic{width:15px; height:15px}
  .fitem svg{width:15px; height:15px}

  .empty-state{
    text-align:center; padding:60px 20px; color:hsl(var(--muted-foreground));
  }
  .empty-state svg{width:34px !important; height:34px !important; opacity:.4; margin-bottom:10px}
  .empty-state h3{font-size:14px; color:hsl(var(--foreground)); margin:0 0 4px}
  .empty-state p{font-size:12.5px; margin:0; max-width:340px; margin:0 auto}

  /* markdown render */
  .md h1{font-size:19px; margin:0 0 10px}
  .md h2{font-size:15px; margin:20px 0 8px; padding-bottom:6px; border-bottom:1px solid hsl(var(--border))}
  .md h3{font-size:13px; margin:16px 0 6px}
  .md p{margin:0 0 10px; font-size:13px}
  .md ul{margin:0 0 10px; padding-left:20px; font-size:13px}
  .md table{width:100%; border-collapse:collapse; margin:0 0 16px; font-size:12.5px}
  .md table th{text-align:left; background:hsl(var(--muted)); padding:7px 10px; border:1px solid hsl(var(--border)); font-weight:600}
  .md table td{padding:7px 10px; border:1px solid hsl(var(--border))}
  .md pre{background:hsl(var(--muted)/.5); border:1px solid hsl(var(--border)); border-radius:8px; padding:12px 14px; font-size:12px; overflow:auto}
  .md code{background:hsl(var(--muted)); padding:1px 5px; border-radius:4px; font-size:12px}

  /* --- landing / uploader --- */
  .landing{max-width:560px; text-align:center; padding:30px}
  .landing .logo-big{
    width:52px; height:52px; border-radius:14px; background:hsl(var(--primary)); margin:0 auto 20px;
    display:flex; align-items:center; justify-content:center;
  }
  .landing .logo-big svg{width:26px !important; height:26px !important; stroke:hsl(var(--primary-foreground))}
  .landing h1{font-size:20px; margin:0 0 8px; font-weight:600}
  .landing p{color:hsl(var(--muted-foreground)); font-size:13.5px; margin:0 0 26px; line-height:1.6}
  #dropzone{
    border:1.5px dashed hsl(var(--border)); border-radius:var(--radius); padding:34px 20px;
    transition:.15s; cursor:pointer;
  }
  #dropzone.drag{border-color:hsl(var(--ring)); background:hsl(var(--accent)/.4)}
  #dropzone svg{width:26px !important; height:26px !important; opacity:.5; margin-bottom:10px}
  .landing .fallback{margin-top:14px; font-size:12px; color:hsl(var(--muted-foreground))}
  .landing .fallback label{color:hsl(var(--foreground)); text-decoration:underline; cursor:pointer; text-underline-offset:2px}

  @media (max-width:820px){
    #sidebar{position:fixed; z-index:20; height:100vh; transform:translateX(-100%); transition:.2s}
    #sidebar.open{transform:translateX(0)}
    .filebrowser{flex-direction:column}
    .filelist{width:100%; max-height:220px}
  }
</style>
</head>
<body>
<div id="app">

  <aside id="sidebar">
    <div class="brand">
      <div class="logo"><svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 3 7l9 5 9-5-9-5Z"/><path d="M3 12l9 5 9-5"/><path d="M3 17l9 5 9-5"/></svg></div>
      <div class="txt"><b>Diagnóstico</b><span>Visualizador de coleta</span></div>
    </div>
    <div id="navwrap"></div>
    <div id="sidebar-foot">Dados processados localmente no navegador. Nada é enviado pela rede.</div>
  </aside>

  <div id="main">
    <div id="topbar">
      <div class="crumbs" id="crumbs">Nenhuma coleta carregada</div>
      <div class="actions">
        <button class="btn" id="mdBtn" style="display:none" title="Exportar visão atual em Markdown">Exportar .md</button>
        <button class="btn icon" id="themeBtn" title="Alternar tema"></button>
        <button class="btn" id="reloadBtn" style="display:none">Carregar outra coleta</button>
      </div>
    </div>
    <div id="content" class="centered"></div>
  </div>

</div>

<script>
/* ============================================================
   ÍCONES (heroicons-style, inline, sem dependência externa)
============================================================ */
const ICONS = {
  home:'<path d="M3 12l9-9 9 9"/><path d="M9 21V12h6v9"/>',
  cpu:'<rect x="6" y="6" width="12" height="12" rx="1.5"/><path d="M9 2v3M15 2v3M9 19v3M15 19v3M2 9h3M2 15h3M19 9h3M19 15h3"/>',
  battery:'<rect x="2" y="7" width="18" height="10" rx="1.5"/><path d="M22 10v4"/>',
  boot:'<path d="M3 12l3-9h6l3 9"/><path d="M3 12v6a2 2 0 0 0 2 2h4l1-4h4l1 4h4a2 2 0 0 0 2-2v-6"/>',
  registry:'<path d="M4 4h16v6H4z"/><path d="M4 14h16v6H4z"/><path d="M8 7h.01M8 17h.01"/>',
  logs:'<path d="M4 4h16v16H4z"/><path d="M8 9h8M8 13h8M8 17h4"/>',
  dumps:'<path d="M12 2v13"/><path d="M7 9l5 6 5-6"/><path d="M4 21h16"/>',
  setup:'<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1-1.6 1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.6-1 1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1Z"/>',
  drivers:'<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="3"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3"/>',
  raw:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
  folder:'<path d="M3 7a2 2 0 0 1 2-2h4l2 2h8a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V7Z"/>',
  file:'<path d="M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8z"/><path d="M14 2v6h6"/>',
  sun:'<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>',
  moon:'<path d="M21 12.8A9 9 0 1 1 11.2 3 7 7 0 0 0 21 12.8Z"/>',
};
function icon(name, extra){ return '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" class="'+(extra||'')+'">'+ICONS[name]+'</svg>'; }

/* ============================================================
   MODO EMBUTIDO
   Se um arquivo dados.js (gerado pelo script de coleta) estiver ao lado
   deste HTML, ele define window.EMBEDDED_DATA = { rootName, files: {rel: conteudo} }.
   Nesse caso o visualizador carrega tudo automaticamente, sem pedir a pasta.
============================================================ */
let EMBEDDED = null;   // { rootName, files: {relPath: string} }

/* ============================================================
   ESTADO
============================================================ */
let FILES = {};        // relPath -> File object (modo seleção de pasta)
let TREE = {};         // topFolder -> [ {rel,name,ext,size,file} ]
let ROOTNAME = '';
let ACTIVE = null;
let JSONCACHE = {};     // path -> parsed json
let CURFILE = null;     // for raw/file-browser sections

/* ============================================================
   DEFINIÇÃO DAS SEÇÕES (mapeadas para as pastas geradas pelo script)
============================================================ */
const SECTIONS = [
  { id:'overview', label:'Visão Geral', icon:'home', group:'Resumo', folder:'00_Resumo',
    desc:'Panorama consolidado da coleta: identificação do equipamento, ambiente de execução (online/offline/WinPE) e indicadores centrais de todos os módulos. É o ponto de partida de qualquer triagem.' },
  { id:'registro', label:'Sistema & Registro', icon:'registry', group:'Resumo', folder:'05_Registro',
    desc:'Dados extraídos do Registro do Windows (hives SYSTEM e SOFTWARE) — versão/build do sistema, dono registrado, estado do CrashControl (se dumps de memória estão habilitados) e a lista completa de serviços instalados com seus caminhos de imagem e modo de inicialização. Em modo offline, essas chaves são montadas temporariamente via "reg load" a partir dos hives do disco.' },

  { id:'hardware', label:'Hardware', icon:'cpu', group:'Inventário', folder:'06_Hardware',
    desc:'Inventário físico da máquina via WMI/CIM: BIOS/UEFI, placa-mãe, CPU, memória RAM (por pente), discos, GPU, interfaces de rede, estado do TPM/Secure Boot e dispositivos com erro no barramento PnP (código de erro do Gerenciador de Dispositivos). Útil para confirmar especificações e localizar hardware com falha de driver ou conflito.' },
  { id:'bateria', label:'Bateria & Energia', icon:'battery', group:'Inventário', folder:'07_Bateria_BMS',
    desc:'Telemetria do subsistema de energia (BMS): fabricante e química da célula, capacidade de projeto vs. capacidade cheia atual (usadas para calcular o desgaste estrutural), contagem de ciclos de carga, e os relatórios nativos do powercfg (battery-report, energy-report) quando coletados em modo online. Ciclos altos e desgaste acima de ~20% geralmente indicam célula próxima do fim de vida útil.' },
  { id:'drivers', label:'Drivers', icon:'drivers', group:'Inventário', folder:'08_Drivers',
    desc:'Repositório de drivers (DriverStore) e, quando coletado em modo online, a lista de drivers atualmente carregados via driverquery. Ajuda a identificar drivers desatualizados, não assinados, ou remanescentes de hardware removido.' },

  { id:'boot', label:'Boot & Estabilidade', icon:'boot', group:'Estabilidade', folder:'04_Boot',
    desc:'Eventos de desligamento inesperado e falha de kernel (IDs 41, 1001, 6008 do Event Log), o log de inicialização (ntbtlog.txt) quando o boot logging estava ativo, e a trilha de diagnóstico do Startup Repair (SrtTrail.txt). O ID 41 ("Kernel-Power") é o principal indicador de desligamento abrupto (queda de energia, travamento, ou corte manual).' },
  { id:'dumps', label:'Dumps & WER', icon:'dumps', group:'Estabilidade', folder:'03_Dumps_e_WER',
    desc:'Arquivos de despejo de memória (Minidump, MEMORY.DMP, LiveKernelReports) e relatórios de erro do Windows Error Reporting (WER). São arquivos binários — este visualizador lista metadados (nome, tamanho, data), mas a análise do conteúdo requer uma ferramenta como o WinDbg.' },
  { id:'eventlogs', label:'Event Logs', icon:'logs', group:'Estabilidade', folder:'01_EventLogs',
    desc:'Cópia bruta dos arquivos .evtx do Visualizador de Eventos do Windows (Application, System, Security, Setup e demais). São arquivos binários indexados — abra-os com o Visualizador de Eventos (eventvwr.msc) ou Get-WinEvent para consulta detalhada.' },
  { id:'panther', label:'Setup / Panther', icon:'setup', group:'Estabilidade', folder:'02_Panther',
    desc:'Logs do processo de instalação/atualização do Windows (pasta Panther), incluindo setupact.log, setuperr.log e o diretório UnattendGC. Relevante para diagnosticar falhas de upgrade de versão ou instalações corrompidas.' },

  { id:'raw', label:'Dados Brutos', icon:'raw', group:'Outros', folder:'09_Dados_Brutos',
    desc:'Todos os arquivos JSON/CSV originais exportados diretamente das consultas WMI/CIM, antes de qualquer resumo ou formatação — a fonte primária de cada número mostrado nas outras seções.' },
];

/* ============================================================
   UTILITÁRIOS
============================================================ */
function fmtBytes(n){
  if (n===undefined||n===null) return '—';
  n=Number(n); if(!n) return '0 B';
  const u=['B','KB','MB','GB','TB']; let i=0;
  while(n>=1024 && i<u.length-1){n/=1024;i++;}
  return (i===0? n : n.toFixed(1)) + ' ' + u[i];
}
function fmtBytesRaw(n){ // for values already in bytes reported by WMI (Capacity, Size)
  const v=Number(n); if(!v) return '—';
  return (v/1073741824).toFixed(1) + ' GB';
}
function esc(s){
  return String(s).replace(/[&<>"']/g, c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
}
function fmtVal(v){
  if (v===null||v===undefined||v==='') return '<span style="color:hsl(var(--muted-foreground))">—</span>';
  if (typeof v==='boolean') return v? '<span class="badge ok">sim</span>':'<span class="badge dim">não</span>';
  if (Array.isArray(v)) return esc(v.join(', '));
  if (typeof v==='object') return '<span class="mono" style="font-size:11.5px">'+esc(JSON.stringify(v))+'</span>';
  return esc(v);
}
function isEmptyVal(v){
  if (v===null||v===undefined) return true;
  if (Array.isArray(v)) return v.length===0;
  if (typeof v==='object') return Object.keys(v).length===0;
  if (typeof v==='string') return v.trim()==='';
  return false;
}

/* --- CSV parser (RFC4180-ish, sem libs externas) --- */
function parseCSV(text){
  text = text.replace(/^\uFEFF/, '');
  const rows=[]; let row=[]; let field=''; let inQuotes=false;
  for (let i=0;i<text.length;i++){
    const c=text[i];
    if (inQuotes){
      if (c==='"'){
        if (text[i+1]==='"'){ field+='"'; i++; } else { inQuotes=false; }
      } else field+=c;
    } else {
      if (c==='"') inQuotes=true;
      else if (c===','){ row.push(field); field=''; }
      else if (c==='\r'){ /* skip */ }
      else if (c==='\n'){ row.push(field); rows.push(row); row=[]; field=''; }
      else field+=c;
    }
  }
  if (field.length||row.length){ row.push(field); rows.push(row); }
  if (!rows.length) return {headers:[], rows:[]};
  const headers = rows[0];
  const dataRows = rows.slice(1).filter(r => r.length>1 || (r[0]!==undefined && r[0]!==''));
  return {headers, rows:dataRows.map(r => { const o={}; headers.forEach((h,i)=>o[h]=r[i]); return o; })};
}

/* --- minimal markdown renderer --- */
function renderMD(md){
  let html = esc(md);
  // code blocks
  html = html.replace(/```([\s\S]*?)```/g, (m,c)=>'<pre>'+c.replace(/^\w*\n/,'')+'</pre>');
  // tables
  html = html.replace(/((?:^\|.*\|\r?\n)+)/gm, block=>{
    const lines = block.trim().split('\n');
    if (lines.length<2) return block;
    const head = lines[0].split('|').slice(1,-1).map(s=>s.trim());
    const bodyLines = lines.slice(2);
    let t = '<table><thead><tr>'+head.map(h=>'<th>'+h+'</th>').join('')+'</tr></thead><tbody>';
    bodyLines.forEach(l=>{
      const cells = l.split('|').slice(1,-1).map(s=>s.trim());
      if (cells.length) t += '<tr>'+cells.map(c=>'<td>'+c+'</td>').join('')+'</tr>';
    });
    t += '</tbody></table>';
    return t;
  });
  html = html.replace(/^### (.*)$/gm, '<h3>$1</h3>');
  html = html.replace(/^## (.*)$/gm, '<h2>$1</h2>');
  html = html.replace(/^# (.*)$/gm, '<h1>$1</h1>');
  html = html.replace(/\*\*(.*?)\*\*/g, '<b>$1</b>');
  html = html.replace(/^- (.*)$/gm, '<li>$1</li>');
  html = html.replace(/(<li>[\s\S]*?<\/li>)(?!\s*<li>)/g, '<ul>$1</ul>');
  html = html.replace(/^(?!<h|<ul|<table|<pre|<li|<\/)(.+)$/gm, '<p>$1</p>');
  return '<div class="md">'+html+'</div>';
}

function kvCard(title, obj, fieldsMap){
  const src = obj||{};
  const entries = fieldsMap ? fieldsMap : Object.keys(src).map(k=>[k,k]);
  const rows = [];
  entries.forEach(([label,key])=>{
    if (!(key in src)) return;
    rows.push('<tr><td class="k">'+esc(label)+'</td><td class="v">'+fmtVal(src[key])+'</td></tr>');
  });
  if (!rows.length) return '';
  return '<div class="card"><h3>'+esc(title)+'</h3><table class="kv">'+rows.join('')+'</table></div>';
}

function dataTable(rows, columns){
  if (!rows || !rows.length) return '<div class="empty-state" style="padding:30px"><p>Nenhum dado disponível para esta tabela.</p></div>';
  const head = columns.map(c=>'<th>'+esc(c[0])+'</th>').join('');
  const body = rows.map(r=>{
    const cells = columns.map(c=>{
      const raw = c[2] ? c[2](r[c[1]], r) : fmtVal(r[c[1]]);
      return '<td class="'+(c[3]||'')+'">'+raw+'</td>';
    }).join('');
    return '<tr>'+cells+'</tr>';
  }).join('');
  return '<div class="tablewrap"><table class="data"><thead><tr>'+head+'</tr></thead><tbody>'+body+'</tbody></table></div>';
}

/* ============================================================
   LEITURA DE ARQUIVOS (JSON/CSV) — funciona em modo File ou embutido
============================================================ */
function allKeys(){
  return EMBEDDED ? Object.keys(EMBEDDED.files) : Object.keys(FILES);
}
async function readByKey(key){
  if (EMBEDDED) return EMBEDDED.files[key];
  return await FILES[key].text();
}
function sizeByKey(key){
  if (EMBEDDED){ const v = EMBEDDED.files[key]; return v ? v.length : 0; }
  return FILES[key].size;
}
async function readText(target){
  // target pode ser um File (modo pasta) ou uma string-chave (não usado direto aqui)
  if (typeof target === 'string') return await readByKey(target);
  return await target.text();
}
async function getJSON(relSuffix){
  const f = findFile(relSuffix);
  if (!f) return null;
  if (JSONCACHE[relSuffix]) return JSONCACHE[relSuffix];
  try {
    const txt = await readByKey(f.rel);
    const parsed = JSON.parse(txt);
    JSONCACHE[relSuffix] = parsed;
    return parsed;
  } catch(e){ return null; }
}
async function getCSV(relSuffix){
  const f = findFile(relSuffix);
  if (!f) return null;
  try { return parseCSV(await readByKey(f.rel)).rows; } catch(e){ return null; }
}
async function getTextFile(relSuffix){
  const f = findFile(relSuffix);
  if (!f) return null;
  try { return await readByKey(f.rel); } catch(e){ return null; }
}
function findFile(suffix){
  const norm = suffix.replace(/\\/g,'/').toLowerCase();
  for (const key of allKeys()){
    if (key.replace(/\\/g,'/').toLowerCase().endsWith(norm)) return {rel:key};
  }
  return null;
}
function filesInFolder(folderName){
  const out = [];
  for (const key of allKeys()){
    const parts = key.replace(/\\/g,'/').split('/');
    const idx = parts.indexOf(folderName);
    if (idx !== -1){
      out.push({rel:key, name:parts[parts.length-1], size:sizeByKey(key), sub:parts.slice(idx+1).join('/')});
    }
  }
  return out.sort((a,b)=>a.rel.localeCompare(b.rel));
}

/* ============================================================
   INGESTÃO DE ARQUIVOS (input directory + drag&drop recursivo)
============================================================ */
function ingestFileList(fileList){
  FILES = {}; JSONCACHE = {};
  let count = 0;
  for (const f of fileList){
    const rel = f.webkitRelativePath || f.relativePath || f.name;
    FILES[rel] = f;
    count++;
  }
  if (!count) return;
  const firstKey = Object.keys(FILES)[0];
  ROOTNAME = firstKey.split('/')[0];
  buildTree();
  buildNav();
  navigate(SECTIONS[0].id);
  document.getElementById('reloadBtn').style.display='inline-flex';
  document.getElementById('mdBtn').style.display='inline-flex';
}

function buildTree(){
  TREE = {};
  for (const key in FILES){
    const parts = key.replace(/\\/g,'/').split('/');
    const top = parts.length>1 ? parts[1] : parts[0];
    TREE[top] = TREE[top] || [];
    TREE[top].push(key);
  }
}

async function traverseEntry(entry, path, out){
  return new Promise(resolve=>{
    if (entry.isFile){
      entry.file(f=>{
        Object.defineProperty(f,'webkitRelativePath',{value: path + f.name});
        out.push(f); resolve();
      });
    } else if (entry.isDirectory){
      const reader = entry.createReader();
      const readEntries = ()=>{
        reader.readEntries(async entries=>{
          if (!entries.length){ resolve(); return; }
          for (const e of entries){ await traverseEntry(e, path+entry.name+'/', out); }
          readEntries();
        });
      };
      readEntries();
    } else resolve();
  });
}

/* ============================================================
   NAV / RENDER
============================================================ */
function buildNav(){
  const wrap = document.getElementById('navwrap');
  const groups = {};
  SECTIONS.forEach(s=>{ (groups[s.group] = groups[s.group]||[]).push(s); });
  let html = '';
  for (const g in groups){
    html += '<div class="navgroup"><div class="navgroup-label">'+esc(g)+'</div>';
    groups[g].forEach(s=>{
      const files = filesInFolder(s.folder);
      const has = files.length>0;
      html += '<div class="navitem'+(has?'':' disabled')+'" data-id="'+s.id+'" title="'+(has?'':'Módulo não presente nesta coleta')+'">'
            + '<div class="left">'+icon(s.icon,'ic')+'<span class="lbl">'+esc(s.label)+'</span></div>'
            + (has ? '<span class="count">'+files.length+'</span>' : '')
            + '</div>';
    });
    html += '</div>';
  }
  wrap.innerHTML = html;
  wrap.querySelectorAll('.navitem').forEach(el=>{
    el.addEventListener('click', ()=>{
      if (el.classList.contains('disabled')) return;
      navigate(el.dataset.id);
    });
  });
}

async function navigate(id){
  ACTIVE = id;
  document.querySelectorAll('.navitem').forEach(el=>el.classList.toggle('active', el.dataset.id===id));
  const sec = SECTIONS.find(s=>s.id===id);
  document.getElementById('crumbs').innerHTML = esc(ROOTNAME) + ' <span style="opacity:.4">/</span> <b>'+esc(sec.label)+'</b>';
  const content = document.getElementById('content');
  content.classList.remove('centered');
  content.innerHTML = '<div class="page-head"><h1>'+icon(sec.icon)+' '+esc(sec.label)+'</h1></div><div class="page-desc">'+esc(sec.desc)+'</div><div id="secbody">Carregando…</div>';
  const body = document.getElementById('secbody');
  try {
    const html = await RENDERERS[id]();
    body.innerHTML = html;
  } catch(e){
    body.innerHTML = '<div class="empty-state"><p>Erro ao processar os dados desta seção: '+esc(e.message)+'</p></div>';
  }
}

/* ============================================================
   RENDERIZADORES POR SEÇÃO
============================================================ */
const RENDERERS = {

  overview: async ()=>{
    const consolidado = await getJSON('00_Resumo/coleta_consolidada.json');
    const resumoMD = await getTextFile('00_Resumo/RESUMO_GERAL.md');
    let out = '';
    if (consolidado){
      const meta = consolidado.Metadados||{};
      const boot = consolidado.Boot||{};
      const bat = consolidado.Bateria||{};
      const hw = consolidado.Hardware||{};
      const pnpCount = Array.isArray(hw.DispositivosErro) ? hw.DispositivosErro.length : (hw.DispositivosErro?1:0);
      out += '<div class="grid">'
        + statCard(boot.EventosCriticos,'Eventos críticos','')
        + statCard(bat.DesgastePercentual!=null? bat.DesgastePercentual+'%':'—','Desgaste bateria', bat.DesgastePercentual>20?'warn':'ok')
        + statCard(bat.Ciclos,'Ciclos de carga','')
        + statCard(pnpCount,'Dispositivos com erro', pnpCount>0?'bad':'ok')
        + statCard((meta.ColetasRealizadas||[]).length,'Módulos coletados','')
        + '</div>';
      out += '<div class="grid">'
        + kvCard('Metadados da coleta', meta, [['Ambiente','Ambiente'],['Data da coleta','DataColeta'],['Unidade do Windows','UnidadeWindows']])
        + '<div class="card"><h3>Módulos coletados</h3><table class="kv">'
          + (meta.ColetasRealizadas||[]).map(m=>'<tr><td class="k">'+esc(m)+'</td><td class="v"><span class="badge ok">coletado</span></td></tr>').join('')
          + '</table></div>'
        + '</div>';
    } else {
      out += '<div class="empty-state">'+icon('raw')+'<h3>coleta_consolidada.json não encontrado</h3><p>Rode a opção [J] no script ou uma coleta completa para gerar o arquivo mestre em 00_Resumo.</p></div>';
    }
    if (resumoMD){
      out += '<div class="section-title">Relatório Markdown (RESUMO_GERAL.md)</div><div class="card">'+renderMD(resumoMD)+'</div>';
    }
    return out;
  },

  registro: async ()=>{
    const consolidado = await getJSON('00_Resumo/coleta_consolidada.json');
    const info = consolidado ? consolidado.Registro : null;
    const servicos = await getCSV('05_Registro/servicos.csv');
    const md = await getTextFile('05_Registro/RESUMO_REGISTRO.md');
    let out = '';
    if (info && !isEmptyVal(info)){
      out += '<div class="grid">'+kvCard('Windows instalado', info, [
        ['Produto','Produto'],['Versão','Versao'],['Build','Build'],['Instalado em','Instalado em'],
        ['Dono registrado','Dono registrado'],['Nome do computador','Nome do computador'],
        ['ControlSet atual','ControlSet atual'],['Último desligamento registrado','Ultimo desligamento registrado'],
        ['Dump de memória habilitado','Dump de memoria habilitado'],['Reinício automático após crash','Reinicio automatico apos crash']
      ])+'</div>';
    } else if (md){
      out += '<div class="card">'+renderMD(md)+'</div>';
    }
    out += '<div class="section-title">Serviços do Windows ('+((servicos||[]).length)+')</div>';
    out += dataTable(servicos, [
      ['Nome','Name'],['Nome de exibição','DisplayName'],['Estado','State'],['Início','StartMode'],['Executando como','StartName'],['Caminho da imagem','PathName','','wrap']
    ]);
    return out;
  },

  hardware: async ()=>{
    const consolidado = await getJSON('00_Resumo/coleta_consolidada.json');
    const hw = consolidado ? consolidado.Hardware||{} : {};
    const md = await getTextFile('06_Hardware/RESUMO_HARDWARE.md');
    const cpuArr = hw.Processador || await getCSV('09_Dados_Brutos/cpu.csv') || [];
    const memArr = hw.Memoria || await getCSV('09_Dados_Brutos/memoria.csv') || [];
    const diskArr = hw.Discos || await getCSV('09_Dados_Brutos/discos.csv') || [];
    const partArr = hw.Particoes || await getCSV('09_Dados_Brutos/particoes.csv') || [];
    const vidArr = hw.Video || await getCSV('09_Dados_Brutos/video.csv') || [];
    const netArr = hw.Rede || await getCSV('09_Dados_Brutos/rede.csv') || [];
    const errArr = hw.DispositivosErro || await getCSV('09_Dados_Brutos/dispositivos_com_erro.csv') || [];
    const smartArr = await getCSV('09_Dados_Brutos/smart_confiabilidade.csv') || [];
    const bios = hw.BIOS || (await getJSON('09_Dados_Brutos/bios.json')) || {};
    const bb = hw.PlacaMae || (await getJSON('09_Dados_Brutos/baseboard.json')) || {};
    const sys = hw.Sistema || (await getJSON('09_Dados_Brutos/computer_system.json')) || {};
    const cpu0 = (Array.isArray(cpuArr)?cpuArr[0]:cpuArr) || {};

    let out = '<div class="grid">';
    out += kvCard('Sistema / BIOS', {...sys, ...bios}, [
      ['Fabricante','Manufacturer'],['Modelo','Model'],['Número de série','SerialNumber'],
      ['BIOS/UEFI versão','SMBIOSBIOSVersion'],['BIOS/UEFI data','ReleaseDate']
    ]);
    out += kvCard('Placa-mãe', bb, [['Fabricante','Manufacturer'],['Produto','Product']]);
    out += kvCard('CPU', cpu0, [
      ['Nome','Name'],['Núcleos','NumberOfCores'],['Threads lógicos','NumberOfLogicalProcessors'],['Clock máximo (MHz)','MaxClockSpeed']
    ]);
    out += '</div>';

    out += '<div class="section-title">Memória RAM ('+memArr.length+' pente(s))</div>';
    out += dataTable(memArr, [['Local','DeviceLocator'],['Capacidade',null,r=>fmtBytesRaw(r.Capacity)],['Velocidade (MHz)','Speed'],['Fabricante','Manufacturer'],['Número de série','SerialNumber']]);

    out += '<div class="section-title">Discos ('+diskArr.length+')</div>';
    out += dataTable(diskArr, [['Modelo','Model'],['Tamanho',null,r=>fmtBytesRaw(r.Size)],['Interface','InterfaceType'],['Status','Status'],['Número de série','SerialNumber']]);

    if (smartArr.length){
      out += '<div class="section-title">Confiabilidade SMART ('+smartArr.length+')</div>';
      out += dataTable(smartArr, [['Disco','DeviceId'],['Temperatura','Temperature'],['Setores realocados','ReadErrorsUncorrected'],['Horas ligado','PowerOnHours'],['Ciclos de energia','PowerCycleCount']]);
    }

    if (partArr.length){
      out += '<div class="section-title">Partições ('+partArr.length+')</div>';
      out += dataTable(partArr, [['Nome','Name'],['Tipo','Type'],['Tamanho',null,r=>fmtBytesRaw(r.Size)],['Inicializável','BootPartition']]);
    }

    out += '<div class="section-title">Placas de vídeo ('+vidArr.length+')</div>';
    out += dataTable(vidArr, [['Nome','Name'],['RAM',null,r=>fmtBytesRaw(r.AdapterRAM)],['Resolução atual',null,r=>(r.CurrentHorizontalResolution&&r.CurrentVerticalResolution)?(r.CurrentHorizontalResolution+'x'+r.CurrentVerticalResolution):'—']]);

    out += '<div class="section-title">Interfaces de rede ('+netArr.length+')</div>';
    out += dataTable(netArr, [['Descrição','Description'],['MAC','MACAddress'],['IP',null,r=>Array.isArray(r.IPAddress)?r.IPAddress.join(', '):(r.IPAddress||'—')],['DHCP habilitado','DHCPEnabled']]);

    out += '<div class="section-title">Dispositivos com erro no barramento PnP ('+errArr.length+')</div>';
    out += dataTable(errArr, [['Nome','Name'],['Código de erro','ConfigManagerErrorCode'],['Device ID','DeviceID','','wrap']]);

    return out;
  },

  bateria: async ()=>{
    const consolidado = await getJSON('00_Resumo/coleta_consolidada.json');
    const bat = consolidado ? consolidado.Bateria||{} : {};
    const md = await getTextFile('07_Bateria_BMS/RESUMO_BATERIA.md');
    const capHist = await getCSV('07_Bateria_BMS/historico_capacidade.csv') || [];
    const lifeEst = await getCSV('07_Bateria_BMS/estimativas_autonomia.csv') || [];
    const staticData = await getJSON('09_Dados_Brutos/bateria_static_data.json');
    const win32 = await getJSON('09_Dados_Brutos/bateria_win32.json');
    const parsed = await getJSON('09_Dados_Brutos/battery_report_parsed.json');

    let out = '<div class="grid">';
    out += kvCard('Indicadores', bat, [['Desgaste (%)','DesgastePercentual'],['Ciclos de carga','Ciclos'],['Eventos de energia','EventosEnergia']]);
    const st0 = Array.isArray(staticData)? staticData[0] : staticData;
    out += kvCard('Dados de fabricação', st0, [['Fabricante','ManufactureName'],['Química','Chemistry'],['Número de série','SerialNumber'],['Data de fabricação','ManufactureDate']]);
    const w0 = Array.isArray(win32)? win32[0] : win32;
    out += kvCard('Estado atual (WMI)', w0, [['Status','Status'],['Carga restante (%)','EstimatedChargeRemaining'],['Autonomia estimada (min)','EstimatedRunTime']]);
    out += '</div>';

    if (parsed && parsed.Baterias && parsed.Baterias.length){
      out += '<div class="section-title">Estrutura detalhada (battery-report.xml)</div><div class="grid">';
      parsed.Baterias.forEach((b,i)=>{
        out += kvCard('Bateria #'+(i+1), b, Object.keys(b).map(k=>[k,k]));
      });
      out += '</div>';
    }

    if (capHist.length){
      out += '<div class="section-title">Histórico de degradação de capacidade</div>';
      out += dataTable(capHist, [['Período','Periodo'],['Capacidade cheia','CapacidadeCheia'],['Capacidade de projeto','CapacidadeProjeto']]);
    }
    if (lifeEst.length){
      out += '<div class="section-title">Estimativas de autonomia</div>';
      out += dataTable(lifeEst, [['Período','Periodo'],['Ativo (cheia)','AtivoCheia'],['Standby (cheia)','StandbyCheia'],['Ativo (projeto)','AtivoProjeto'],['Standby (projeto)','StandbyProjeto']]);
    }
    if (md){
      out += '<div class="section-title">Relatório completo (RESUMO_BATERIA.md)</div><div class="card">'+renderMD(md)+'</div>';
    }
    return out || '<div class="empty-state"><p>Nenhum dado de bateria coletado (a máquina pode ser um desktop sem BMS).</p></div>';
  },

  drivers: async ()=>{
    const store = await getCSV('08_Drivers/driverstore.csv') || [];
    const ativos = await getCSV('08_Drivers/drivers_ativos.csv') || [];
    let out = '';
    out += '<div class="section-title">Repositório de drivers - DriverStore ('+store.length+')</div>';
    out += dataTable(store, [['Nome','Name'],['Última modificação','LastWriteTime']]);
    if (ativos.length){
      out += '<div class="section-title">Drivers ativos (driverquery) ('+ativos.length+')</div>';
      const cols = Object.keys(ativos[0]).slice(0,6).map(k=>[k,k]);
      out += dataTable(ativos, cols);
    }
    return out;
  },

  boot: async ()=>{
    const consolidado = await getJSON('00_Resumo/coleta_consolidada.json');
    const boot = consolidado ? consolidado.Boot||{} : {};
    const eventos = await getCSV('04_Boot/eventos_criticos_desligamento.csv') || [];
    const ntbtlog = await getTextFile('04_Boot/ntbtlog.txt');
    const srttrail = await getTextFile('04_Boot/SrtTrail.txt');
    let out = '<div class="grid">'+kvCard('Resumo', boot, [['Eventos críticos de kernel/energia','EventosCriticos']])+'</div>';
    out += '<div class="section-title">Eventos críticos (IDs 41 / 1001 / 6008) — '+eventos.length+'</div>';
    out += dataTable(eventos, [['Data/hora','TimeCreated'],['ID','Id'],['Nível','LevelDisplayName'],['Provedor','ProviderName'],['Mensagem','Message','','wrap']]);
    if (srttrail){
      out += '<div class="section-title">Startup Repair (SrtTrail.txt)</div><pre style="background:hsl(var(--muted)/.5);border:1px solid hsl(var(--border));border-radius:8px;padding:14px;font-size:12px;overflow:auto;max-height:340px">'+esc(srttrail)+'</pre>';
    }
    if (ntbtlog){
      out += '<div class="section-title">Log de inicialização (ntbtlog.txt)</div><pre style="background:hsl(var(--muted)/.5);border:1px solid hsl(var(--border));border-radius:8px;padding:14px;font-size:12px;overflow:auto;max-height:340px">'+esc(ntbtlog.slice(0,20000))+(ntbtlog.length>20000?'\n\n[...truncado...]':'')+'</pre>';
    }
    return out;
  },

  dumps: async ()=> fileBrowser('03_Dumps_e_WER'),
  eventlogs: async ()=> fileBrowser('01_EventLogs'),
  panther: async ()=> fileBrowser('02_Panther'),
  raw: async ()=> fileBrowser('09_Dados_Brutos'),
};

function statCard(val, label, cls){
  return '<div class="card stat '+(cls||'')+'"><div class="num">'+(val===undefined||val===null||val===''?'—':esc(val))+'</div><div class="lbl">'+esc(label)+'</div></div>';
}

/* --- Navegador de arquivos genérico (usado para pastas com binários/texto misturado) --- */
const TEXT_EXT = ['.txt','.log','.md','.xml','.html','.htm','.csv','.json','.ini','.reg'];
const BINARY_EXT = ['.evtx','.dmp'];

function fileBrowser(folder){
  const files = filesInFolder(folder);
  if (!files.length){
    return '<div class="empty-state">'+icon('folder')+'<h3>Pasta vazia</h3><p>Este módulo não foi coletado nesta execução.</p></div>';
  }
  const listId = 'fb_'+folder.replace(/\W/g,'');
  setTimeout(()=>initFileBrowser(folder, files, listId), 0);
  return '<div class="filebrowser">'
    + '<div class="filelist" id="'+listId+'_list"></div>'
    + '<div class="fileview" id="'+listId+'_view"><div class="empty-state"><p>Selecione um arquivo à esquerda.</p></div></div>'
    + '</div>';
}

function initFileBrowser(folder, files, listId){
  const listEl = document.getElementById(listId+'_list');
  listEl.innerHTML = files.map((f,i)=>{
    const ext = '.'+f.name.split('.').pop().toLowerCase();
    return '<div class="fitem" data-i="'+i+'">'+icon('file','ic')+' <span style="overflow:hidden;text-overflow:ellipsis">'+esc(f.sub)+'</span><span class="sz">'+fmtBytes(f.size)+'</span></div>';
  }).join('');
  listEl.querySelectorAll('.fitem').forEach(el=>{
    el.addEventListener('click', async ()=>{
      listEl.querySelectorAll('.fitem').forEach(x=>x.classList.remove('active'));
      el.classList.add('active');
      const f = files[+el.dataset.i];
      await showFile(f, listId);
    });
  });
  // auto-open first text-ish file (que não seja binário embutido nulo)
  const firstText = files.find(f=>TEXT_EXT.includes('.'+f.name.split('.').pop().toLowerCase()) && !(EMBEDDED && EMBEDDED.files[f.rel]===null));
  if (firstText){
    const idx = files.indexOf(firstText);
    listEl.querySelector('[data-i="'+idx+'"]').click();
  }
}

async function showFile(f, listId){
  const view = document.getElementById(listId+'_view');
  const ext = '.'+f.name.split('.').pop().toLowerCase();
  const isBinary = BINARY_EXT.includes(ext) || (EMBEDDED && EMBEDDED.files[f.rel] === null);
  if (isBinary){
    view.innerHTML = '<div class="binary-note">'+icon('raw')+'<div><b>'+esc(f.name)+'</b> ('+fmtBytes(f.size)+')<br>'
      + (ext==='.evtx' ? 'Arquivo de log de eventos binário. Abra com o Visualizador de Eventos do Windows (eventvwr.msc → Ação → Abrir Log Salvo) ou <code>Get-WinEvent -Path</code> no PowerShell. No modo embutido, o conteúdo binário não é incluído — abra o arquivo original na pasta da coleta.'
        : 'Arquivo de despejo de memória binário. Analise com WinDbg ou <code>!analyze -v</code> para identificar a causa do travamento. O conteúdo binário não é embutido no visualizador — use o arquivo original.')
      + '</div></div>';
    return;
  }
  view.innerHTML = '<div class="empty-state"><p>Carregando…</p></div>';
  const txt = await readByKey(f.rel);
  if (ext==='.json'){
    try {
      const parsed = JSON.parse(txt);
      view.innerHTML = '<pre>'+esc(JSON.stringify(parsed, null, 2))+'</pre>';
    } catch(e){ view.innerHTML = '<pre>'+esc(txt)+'</pre>'; }
  } else if (ext==='.csv'){
    const {headers, rows} = parseCSV(txt);
    view.innerHTML = dataTable(rows, headers.map(h=>[h,h]));
  } else if (ext==='.md'){
    view.innerHTML = '<div class="card">'+renderMD(txt)+'</div>';
  } else {
    const truncated = txt.length>60000;
    view.innerHTML = '<pre>'+esc(truncated? txt.slice(0,60000)+'\n\n[...truncado, arquivo grande...]' : txt)+'</pre>';
  }
}

/* ============================================================
   TEMA
============================================================ */
function applyTheme(t){
  document.documentElement.classList.toggle('dark', t==='dark');
  document.getElementById('themeBtn').innerHTML = icon(t==='dark'?'sun':'moon');
  localStorage.setItem('diag-theme', t);
}
document.getElementById('themeBtn').addEventListener('click', ()=>{
  const cur = document.documentElement.classList.contains('dark') ? 'dark':'light';
  applyTheme(cur==='dark' ? 'light':'dark');
});
applyTheme((window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light');

/* ============================================================
   LANDING / UPLOAD
============================================================ */
function showLanding(){
  const content = document.getElementById('content');
  content.classList.add('centered');
  content.innerHTML = ''
    +'<div class="landing">'
    +'  <div class="logo-big">'+icon('folder')+'</div>'
    +'  <h1>Carregar coleta de diagnóstico</h1>'
    +'  <p>Selecione a pasta gerada pelo script de coleta (a que contém 00_Resumo, 06_Hardware etc.) para navegar por todos os dados extraídos.</p>'
    +'  <div id="dropzone">'+icon('folder')+'<div>Arraste a pasta da coleta aqui</div>'
    +'    <div class="fallback"><label for="dirInput">ou selecione a pasta manualmente</label></div>'
    +'  </div>'
    +'</div>';
  document.getElementById('crumbs').textContent = 'Nenhuma coleta carregada';

  const dz = document.getElementById('dropzone');
  dz.addEventListener('click', ()=> document.getElementById('dirInput').click());
  ['dragenter','dragover'].forEach(ev=>dz.addEventListener(ev,e=>{e.preventDefault();dz.classList.add('drag');}));
  ['dragleave','drop'].forEach(ev=>dz.addEventListener(ev,e=>{e.preventDefault();dz.classList.remove('drag');}));
  dz.addEventListener('drop', async e=>{
    const items = e.dataTransfer.items;
    if (items && items[0] && items[0].webkitGetAsEntry){
      const out = [];
      const proms = [];
      for (const it of items){
        const entry = it.webkitGetAsEntry();
        if (entry) proms.push(traverseEntry(entry, '', out));
      }
      await Promise.all(proms);
      if (out.length) ingestFileList(out);
    } else if (e.dataTransfer.files.length){
      ingestFileList(e.dataTransfer.files);
    }
  });
}

const dirInput = document.createElement('input');
dirInput.type='file'; dirInput.id='dirInput'; dirInput.webkitdirectory=true; dirInput.style.display='none';
dirInput.addEventListener('change', e=>{ if (e.target.files.length) ingestFileList(e.target.files); });
document.body.appendChild(dirInput);

document.getElementById('reloadBtn').addEventListener('click', ()=>{
  FILES={}; TREE={}; JSONCACHE={}; ACTIVE=null; EMBEDDED=null;
  document.getElementById('navwrap').innerHTML='';
  document.getElementById('reloadBtn').style.display='none';
  document.getElementById('mdBtn').style.display='none';
  showLanding();
});

/* ============================================================
   EXPORTAÇÃO EM MARKDOWN
============================================================ */
function tableToMD(rows, columns){
  if (!rows || !rows.length) return '_Sem dados._\n';
  const strip = h => String(h).replace(/<[^>]+>/g,'').replace(/\|/g,'\\|').replace(/\n/g,' ').trim();
  let md = '| '+columns.map(c=>strip(c[0])).join(' | ')+' |\n';
  md += '| '+columns.map(()=>'---').join(' | ')+' |\n';
  rows.forEach(r=>{
    md += '| '+columns.map(c=>{
      let v = c[2] ? c[2](r[c[1]], r) : r[c[1]];
      return strip(v===undefined||v===null?'—':v);
    }).join(' | ')+' |\n';
  });
  return md+'\n';
}

async function exportMarkdown(){
  const meta = (await getJSON('00_Resumo/coleta_consolidada.json')||{}).Metadados || {};
  const rootName = EMBEDDED ? EMBEDDED.rootName : ROOTNAME;
  let md = '# Diagnóstico — '+rootName+'\n\n';
  md += '- **Ambiente:** '+(meta.Ambiente||'—')+'\n';
  md += '- **Data da coleta:** '+(meta.DataColeta||'—')+'\n';
  md += '- **Unidade do Windows:** '+(meta.UnidadeWindows||'—')+'\n';
  md += '- **Módulos coletados:** '+((meta.ColetasRealizadas||[]).join(', ')||'—')+'\n\n';

  // Anexa todos os RESUMO_*.md que existirem
  const mdFiles = allKeys().filter(k=>/RESUMO_.*\.md$/i.test(k) || /RESUMO_GERAL\.md$/i.test(k));
  for (const k of mdFiles){
    const txt = await readByKey(k);
    if (txt){ md += '\n---\n\n'+txt.trim()+'\n'; }
  }

  // Tabelas principais de hardware/serviços/bateria a partir dos CSV
  const blocks = [
    ['## Serviços do Windows', await getCSV('05_Registro/servicos.csv'), [['Nome','Name'],['Estado','State'],['Início','StartMode'],['Caminho','PathName']]],
    ['## Memória RAM', await getCSV('09_Dados_Brutos/memoria.csv'), [['Local','DeviceLocator'],['Capacidade',null,r=>fmtBytesRaw(r.Capacity)],['Velocidade','Speed'],['Fabricante','Manufacturer']]],
    ['## Discos', await getCSV('09_Dados_Brutos/discos.csv'), [['Modelo','Model'],['Tamanho',null,r=>fmtBytesRaw(r.Size)],['Interface','InterfaceType'],['Status','Status']]],
    ['## Dispositivos com erro', await getCSV('09_Dados_Brutos/dispositivos_com_erro.csv'), [['Nome','Name'],['Código','ConfigManagerErrorCode'],['Device ID','DeviceID']]],
    ['## Histórico de bateria', await getCSV('07_Bateria_BMS/historico_capacidade.csv'), [['Período','Periodo'],['Cheia','CapacidadeCheia'],['Projeto','CapacidadeProjeto']]],
    ['## Eventos críticos', await getCSV('04_Boot/eventos_criticos_desligamento.csv'), [['Data','TimeCreated'],['ID','Id'],['Nível','LevelDisplayName'],['Provedor','ProviderName']]],
  ];
  for (const [title, rows, cols] of blocks){
    if (rows && rows.length){ md += '\n---\n\n'+title+'\n\n'+tableToMD(rows, cols); }
  }

  const blob = new Blob([md], {type:'text/markdown;charset=utf-8'});
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = 'diagnostico_'+rootName+'.md';
  a.click();
  URL.revokeObjectURL(a.href);
}
document.getElementById('mdBtn').addEventListener('click', exportMarkdown);

/* ============================================================
   BOOT: modo embutido (dados.js) ou seleção manual de pasta
============================================================ */
function startEmbedded(){
  EMBEDDED = window.EMBEDDED_DATA;
  ROOTNAME = EMBEDDED.rootName || 'coleta';
  buildNav();
  const first = SECTIONS.find(s=>filesInFolder(s.folder).length>0) || SECTIONS[0];
  navigate(first.id);
  document.getElementById('reloadBtn').style.display='none'; // sem "carregar outra" em modo embutido
  document.getElementById('mdBtn').style.display='inline-flex';
}

if (window.EMBEDDED_DATA && window.EMBEDDED_DATA.files && Object.keys(window.EMBEDDED_DATA.files).length){
  startEmbedded();
} else {
  showLanding();
}
</script>
</body>
</html>

'@

function Detectar-Ambiente {
    if ($script:AmbienteOk) { return }
    Inicializar-Destino

    $RunningDrive = $env:SystemDrive
    $script:IsWinPE = $false
    try {
        $script:IsWinPE = ($RunningDrive -eq 'X:') -or (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\MiniNT')
    } catch {}

    Log "Inspecionando estrutura de particoes do Windows..." 'Cyan'
    $script:WinDrive = $null
    foreach ($letra in 67..90 | ForEach-Object { [char]$_ }) {
        $candidato = "$letra`:\Windows\System32\config\SYSTEM"
        if (Test-Path $candidato) { $script:WinDrive = "$letra`:"; break }
    }

    $script:ModoAoVivo = (-not $script:IsWinPE) -and $script:WinDrive -and ($script:WinDrive -eq $RunningDrive)

    if (-not $script:WinDrive) {
        Log "[ERRO] Sistema Operacional base nao localizado. Modulos limitados a inspecao de hardware." 'Red'
    } elseif ($script:ModoAoVivo) {
        Log "Windows ativo identificado no volume $($script:WinDrive) (Modo Online)" 'Green'
    } else {
        Log "Windows inativo identificado no volume $($script:WinDrive) (Modo Offline)" 'Green'
    }
    $script:AmbienteOk = $true
}

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
        if (Test-Path $srt) { Copy-Item $srt $script:Pastas.Boot -Force -ErrorAction Stop }
    }

    $SystemEvtx = Join-Path $script:Pastas.EventLogs 'System.evtx'
    if (Test-Path $SystemEvtx) {
        $ev = Executar "Mineracao de eventos de falha de kernel e desligamento" {
            Get-WinEvent -FilterHashtable @{ Path = $SystemEvtx; Id = 41,1001,6008 } -ErrorAction Stop |
                Select-Object TimeCreated, Id, LevelDisplayName, ProviderName, Message |
                Sort-Object TimeCreated -Descending
        }
        if ($ev) {
            Salvar-Csv $ev (Join-Path $script:Pastas.Boot 'eventos_criticos_desligamento.csv')
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
    if (-not $script:WinDrive) { Log "[ABORTADO] Registro - Volume do sistema nao identificado" 'Yellow'; return }
    Log ">> Executando módulo de Analise de Registro e Servicos..." 'Cyan'

    $InfoWindowsInstalado = [ordered]@{}

    $lerInfo = {
        param([string]$RaizSoftware, [string]$RaizSystemCS)
        try {
            $cv = Get-ItemProperty "$RaizSoftware\Microsoft\Windows NT\CurrentVersion" -ErrorAction Stop
            $InfoWindowsInstalado['Produto'] = $cv.ProductName
            $InfoWindowsInstalado['Versao'] = if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId }
            $InfoWindowsInstalado['Build'] = "$($cv.CurrentBuild).$($cv.UBR)"
            $InfoWindowsInstalado['Instalado em'] = if ($cv.InstallDate) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$cv.InstallDate).LocalDateTime } else { '-' }
            $InfoWindowsInstalado['Dono registrado'] = $cv.RegisteredOwner
            Log "[OK] Leitura das subchaves de versao e build do sistema" 'Green'
        } catch { Log "[FALHOU] Falha na leitura de versao -> $($_.Exception.Message)" 'Yellow' }

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
        foreach ($chave in $hives.Keys) {
            $arq = $hives[$chave]
            $ok = Executar "Montagem da estrutura binaria $chave" {
                $saida = & reg load $chave $arq 2>&1
                if ($LASTEXITCODE -ne 0) { throw "Codigo de integridade $LASTEXITCODE retornado no sub-processo ($saida)" }
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

        Executar "Parser de chaves de servicos em modo offline" {
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
            Executar "Desmontagem segura da unidade binaria $chave" {
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
    $NET     = Executar "Interfaces de Rede" { Get-CimInstance Win32_NetworkAdapterConfiguration -ErrorAction Stop | Where-Object { $_.MACAddress } }
    $PNP_ERR = Executar "Barramento PnP e Conflitos" {
        Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -ne 0 }
    }
    $TPM     = Executar "Cripto-processador (TPM)" { Get-Tpm -ErrorAction Stop }
    $SB      = Executar "Validacao Secure Boot" { Confirm-SecureBootUEFI -ErrorAction Stop }
    $SMART   = Executar "Telemetria de Confiabilidade SMART" {
        Get-PhysicalDisk -ErrorAction Stop | Get-StorageReliabilityCounter -ErrorAction Stop
    }

    Salvar-Json $CS    (Join-Path $script:Pastas.Bruto 'computer_system.json')
    Salvar-Json $CSP   (Join-Path $script:Pastas.Bruto 'computer_system_product.json')
    Salvar-Json $BIOS  (Join-Path $script:Pastas.Bruto 'bios.json')
    Salvar-Json $BB    (Join-Path $script:Pastas.Bruto 'baseboard.json')
    Salvar-Csv  $CPU   (Join-Path $script:Pastas.Bruto 'cpu.csv')
    Salvar-Csv  $MEM   (Join-Path $script:Pastas.Bruto 'memoria.csv')
    Salvar-Csv  $DISK  (Join-Path $script:Pastas.Bruto 'discos.csv')
    Salvar-Csv  $PART  (Join-Path $script:Pastas.Bruto 'particoes.csv')
    Salvar-Csv  $VID   (Join-Path $script:Pastas.Bruto 'video.csv')
    Salvar-Csv  $NET   (Join-Path $script:Pastas.Bruto 'rede.csv')
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

function Gerar-ArquivoJson {
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

function Obter-CaminhoSevenZip {
    <#
    .SYNOPSIS
      Localiza um binario 7-Zip (7z.exe) disponivel no sistema, se houver, para permitir
      compactacao LZMA2 solida (taxa de compressao muito superior ao Deflate padrao do .NET).
    #>
    $candidatos = @(
        (Get-Command '7z.exe' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
    )
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

function Compactar-Zip {
    <#
    .SYNOPSIS
      Compacta o diretorio de coleta com a maior taxa de compressao disponivel no ambiente.
      Prioriza 7-Zip (LZMA2, modo solido, nivel maximo) quando presente; caso contrario,
      recorre ao compactador .NET nativo (Deflate no nivel Optimal), sempre disponivel.
    #>
    Detectar-Ambiente
    $modelo = if ($script:Dados['CS']) { $script:Dados['CS'].Model } else { 'target' }
    $baseNome = ("coletadiag_{0}_{1}" -f ($modelo -replace '[^\w\-]', '_'), $Timestamp) -replace '_+', '_'
    $zipParent = Split-Path $Destino -Parent
    if (-not $zipParent) { $zipParent = $ScriptRoot }

    $sevenZip = Obter-CaminhoSevenZip
    if ($sevenZip) {
        Executar "Compactacao maxima via 7-Zip (LZMA2, modo solido, nivel 9)" {
            $arqPath = Join-Path $zipParent ($baseNome + '.7z')
            if (Test-Path $arqPath) { Remove-Item $arqPath -Force -ErrorAction SilentlyContinue }
            # -mx=9: nivel maximo | -m0=lzma2: algoritmo | -mfb=273: match finder mais profundo
            # -ms=on: modo solido (aproveita redundancia entre arquivos JSON/CSV similares) | -mmt=on: multi-thread
            $args = @('a', '-t7z', '-mx=9', '-m0=lzma2', '-mfb=273', '-ms=on', '-mmt=on', $arqPath, "$Destino\*")
            $p = Start-Process -FilePath $sevenZip -ArgumentList $args -PassThru -WindowStyle Hidden -Wait -ErrorAction Stop
            if ($p.ExitCode -ne 0) { throw "7z.exe retornou codigo de saida $($p.ExitCode)" }
            $tamOrig = (Get-ChildItem $Destino -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            $tamZip = (Get-Item $arqPath).Length
            $taxa = if ($tamOrig -gt 0) { [math]::Round((1 - ($tamZip / $tamOrig)) * 100, 1) } else { 0 }
            Log "Arquivo 7z gerado: $arqPath ($([math]::Round($tamZip/1MB,1)) MB, $taxa% menor que o original)" 'Green'
        }
        return
    }

    Log "[INFO] 7-Zip nao encontrado no sistema. Usando compactador .NET nativo (Deflate/Optimal)." 'DarkGray'
    Executar "Compactacao via .NET (Deflate, nivel Optimal)" {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

        $zipPath = Join-Path $zipParent ($baseNome + '.zip')
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
    Gerar-DadosEmbutidos
    if (-not $SemZip) { Compactar-Zip }
}

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
    Write-Host "   [H] Atualizar visualizador HTML (embutir dados coletados)"
    Write-Host "   [J] Exportar JSON Mestre e consolidar dados na memória"
    Write-Host "   [D] Alterar destino de alocação de saída"
    Write-Host "   [R] Renderizar novo relatório analítico Markdown (Resumo)"
    Write-Host "   [Z] Compactar (7-Zip/LZMA2 se disponivel, senao ZIP nativo)"
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
        if ($up -eq 'Z') { Gerar-DadosEmbutidos; Compactar-Zip; Read-Host "Retornando. ENTER" | Out-Null; continue }
        if ($up -eq 'J') { Gerar-ArquivoJson; Read-Host "JSON gravado com sucesso. Retornando. ENTER" | Out-Null; continue }
        if ($up -eq 'H') { Gerar-DadosEmbutidos; Read-Host "Visualizador atualizado com os dados atuais. Retornando. ENTER" | Out-Null; continue }

        $itens = $entrada -split '[,; ]+' | Where-Object { $_ -ne '' }
        foreach ($it in $itens) { Executar-Tarefa $it }

        if ($itens -notcontains '1') { Gerar-ResumoGeral; Gerar-DadosEmbutidos }

        Write-Host ""
        Read-Host "Tolerancia de thread terminada. ENTER para liberar menu." | Out-Null
    }
}

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
        Gerar-DadosEmbutidos
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
