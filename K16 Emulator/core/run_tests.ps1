# K16 Emulator Test Runner for PowerShell
# Usage: .\run_tests.ps1 [BinDir] [-BigEndian] [-Trace] [-MaxCycles N]

param(
    [string]$BinDir    = ".\tests",
    [switch]$BigEndian,
    [switch]$Trace,
    [int]   $MaxCycles = 10000000
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Emu       = Join-Path $ScriptDir "K16EmuCLI.exe"

if (-not (Test-Path $Emu)) {
    Write-Error "K16EmuCLI.exe not found at: $Emu"
    exit 1
}
if (-not (Test-Path $BinDir)) {
    Write-Error "Directory not found: $BinDir"
    exit 1
}

$Bins = Get-ChildItem -Path $BinDir -Filter "*.bin" | Sort-Object Name
if ($Bins.Count -eq 0) { Write-Host "No .bin files found in $BinDir"; exit 1 }

$ExtraArgs = @("--maxcycles", "$MaxCycles")
if ($BigEndian) { $ExtraArgs += "--bigendian" }
if ($Trace)     { $ExtraArgs += "--trace" }

$Pass = 0; $Fail = 0; $Total = $Bins.Count

Write-Host "K16 Emulator Test Run"
Write-Host "Emulator : $Emu"
Write-Host "Test dir : $BinDir"
Write-Host "Tests    : $Total"
Write-Host "---"

foreach ($Bin in $Bins) {
    $Name = $Bin.BaseName
    & $Emu $Bin.FullName @ExtraArgs | Out-Null
    $ExitCode = $LASTEXITCODE

    if ($ExitCode -eq 0) {
        Write-Host ("PASS    {0}" -f $Name) -ForegroundColor Green
        $Pass++
    } else {
        Write-Host ("FAIL    {0,-40}  (exit {1})" -f $Name, $ExitCode) -ForegroundColor Red
        $Fail++
    }
}

Write-Host "---"
Write-Host "Results: $Pass/$Total passed, $Fail failed"

if ($Fail -eq 0) {
    Write-Host "ALL TESTS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "FAILURES: $Fail" -ForegroundColor Red
    exit 1
}
