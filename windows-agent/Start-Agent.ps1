$ErrorActionPreference = 'Stop'
$java = Join-Path $PSScriptRoot 'java-21/bin/java.exe'
$agent = Join-Path $PSScriptRoot 'agent.jar'
$work = Join-Path $PSScriptRoot 'work'
$secret = Join-Path $env:LOCALAPPDATA 'Jenkins/audio-windows/agent.secret'

foreach ($path in $java, $agent, $secret) {
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing Jenkins agent file: $path"
    }
}

& $java -jar $agent -url 'http://192.168.11.147:18090/' -name 'audio-windows' -webSocket -secret "@$secret" -workDir $work
exit $LASTEXITCODE
