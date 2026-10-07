<#
.SYNOPSIS
  Lanza varias instancias del juego en ventanas para probar el multijugador online en un solo PC.

.DESCRIPTION
  La primera instancia crea la sala (host) y las demás se unen por 127.0.0.1.
  Las ventanas se colocan en cuadrícula. Cierra todas las ventanas para terminar.

.PARAMETER Count      Nº de instancias humanas (host + clientes). 1..8. Por defecto 2.
.PARAMETER Bots       Bots que añade el host (simulan más jugadores sin más ventanas).
.PARAMETER Games      Nº de minijuegos si se usa -AutoStart.
.PARAMETER AutoStart  El host empieza solo la partida cuando están todos (humanos + bots).
.PARAMETER Autopilot  Todas las instancias se controlan solas (sin tocar nada).
.PARAMETER Godot      Ruta al ejecutable de Godot (o variable de entorno GODOT).

.EXAMPLE
  .\tools\dev_multi.ps1 -Count 3                        # 3 ventanas; empiezas la partida a mano en el host
  .\tools\dev_multi.ps1 -Count 2 -Bots 6 -AutoStart     # 8 jugadores con solo 2 ventanas
  .\tools\dev_multi.ps1 -Count 8 -Autopilot -AutoStart -Games 3
#>
param(
  [ValidateRange(1, 8)][int]$Count = 2,
  [int]$Bots = 0,
  [int]$Games = 3,
  [switch]$AutoStart,
  [switch]$Autopilot,
  [string]$Godot = $env:GODOT
)

if (-not $Godot) { $Godot = (Get-Command godot -ErrorAction SilentlyContinue).Source }
if (-not $Godot -or -not (Test-Path $Godot)) {
  Write-Error "No encuentro Godot. Usa -Godot <ruta> o define la variable de entorno GODOT."
  exit 1
}
$project = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea

# Tamaño de ventana según cuántas haya (cuadrícula).
$cols = [Math]::Ceiling([Math]::Sqrt($Count))
$rows = [Math]::Ceiling($Count / $cols)
$w = [int]([Math]::Min(960, $screen.Width / $cols))
$h = [int]($w * 9 / 16)
if ($h * $rows -gt $screen.Height) { $h = [int]($screen.Height / $rows); $w = [int]($h * 16 / 9) }

$procs = @()
for ($i = 0; $i -lt $Count; $i++) {
  $x = $screen.X + ($i % $cols) * $w
  $y = $screen.Y + [Math]::Floor($i / $cols) * ($h + 30)
  $gameArgs = @()
  if ($i -eq 0) {
    $gameArgs += "--host", "--name=Host", "--bots=$Bots"
    if ($AutoStart) { $gameArgs += "--players=$($Count + $Bots)", "--games=$Games" }
  } else {
    $gameArgs += "--join=127.0.0.1", "--name=Cliente$($i + 1)"
  }
  if ($Autopilot) { $gameArgs += "--autopilot" }
  $args = @("--path", $project, "--resolution", "${w}x${h}", "--position", "$x,$y", "--") + $gameArgs
  Write-Host "Instancia $($i + 1): $($gameArgs -join ' ')"
  $procs += Start-Process -FilePath $Godot -ArgumentList $args -PassThru
  if ($i -eq 0) { Start-Sleep -Seconds 3 } else { Start-Sleep -Milliseconds 600 }
}
Write-Host "Lanzadas $Count instancias. Cierra las ventanas para terminar (Ctrl+C aquí las cierra todas)."
try { $procs | ForEach-Object { $_.WaitForExit() } }
finally { $procs | Where-Object { -not $_.HasExited } | Stop-Process -Force }
