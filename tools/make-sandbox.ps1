# Creates sandbox\PEAK: a fake PEAK install for testing (never point tests at the real game folder).
param([string]$Root = (Join-Path $PSScriptRoot "..\sandbox"))
$ErrorActionPreference = 'Stop'
$dn = "C:\Program Files\dotnet\dotnet.exe"
$game = Join-Path $Root "PEAK"
New-Item -ItemType Directory -Force $game, (Join-Path $game "PEAK_Data\Managed") | Out-Null
& $dn publish (Join-Path $PSScriptRoot "FakePeak\FakePeak.csproj") -c Release -o $game --nologo -v q | Out-Null
Set-Content -Path (Join-Path $game "version.txt") -Value "2.6.b-sandbox"
Set-Content -Path (Join-Path $game "UnityPlayer.dll") -Value "fake"
Write-Host "Sandbox game folder ready: $game"
