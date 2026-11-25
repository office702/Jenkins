# Keeps the audio-windows Jenkins agent connected: restarts Start-Agent.ps1 whenever it exits.
# Started by the "Jenkins audio-windows agent" scheduled task at user logon.
$ErrorActionPreference = 'Continue'
$start = Join-Path $PSScriptRoot 'Start-Agent.ps1'
$logDir = Join-Path $PSScriptRoot 'work/launcher-logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$supervisorLog = Join-Path $logDir 'supervisor.log'

function Write-SupervisorLog([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $message
    Add-Content -LiteralPath $supervisorLog -Value $line -Encoding UTF8
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\JenkinsAudioWindowsAgentSupervisor')
if (-not $mutex.WaitOne(0)) {
    Write-SupervisorLog 'Another supervisor is already running; exiting.'
    exit 0
}

try {
    while ($true) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        Write-SupervisorLog 'Starting agent.'
        $process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -Wait `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $start) `
            -RedirectStandardOutput (Join-Path $logDir "agent-$stamp.out.log") `
            -RedirectStandardError (Join-Path $logDir "agent-$stamp.err.log")
        Write-SupervisorLog "Agent exited with code $($process.ExitCode); restarting in 15 seconds."
        Get-ChildItem -LiteralPath $logDir -Filter 'agent-*.log' |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 40 | Remove-Item -Force
        Start-Sleep -Seconds 15
    }
} finally {
    $mutex.ReleaseMutex()
}
