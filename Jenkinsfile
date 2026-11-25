pipeline {
    agent none

    options {
        skipDefaultCheckout(true)
        disableConcurrentBuilds()
        copyArtifactPermission('audioTranslation-test')
        buildDiscarder(logRotator(numToKeepStr: '25', artifactNumToKeepStr: '3'))
        timeout(time: 75, unit: 'MINUTES')
    }

    environment {
        SOURCE_URL = 'https://github.com/office702/audioTranslation.git'
        SOURCE_BRANCH = 'migration/tencent-r5'
        GIT_TERMINAL_PROMPT = '0'
        GIT_CONFIG_COUNT = '0'
        WIN_GIT = 'C:/Users/Administrator/AppData/Local/UGit/app-5.55.1/resources/app/git/cmd/git.exe'
        WIN_PYTHON = 'C:/Users/Administrator/AppData/Local/Python/pythoncore-3.12-64/python.exe'
        WIN_ISCC = 'E:/Project/audioTranslation/tools/innosetup6/ISCC.exe'
        NETTAP_SERVER = 'https://43.136.77.153'
        NETTAP_MIGRATION_ID = 'tencent-server-20261123'
    }

    stages {
        stage('Fetch source') {
            agent { label 'audio-windows' }
            steps {
                deleteDir()
                powershell '''
                    $ErrorActionPreference = 'Stop'
                    & $env:WIN_GIT clone --config core.autocrlf=false --depth 1 --single-branch --branch $env:SOURCE_BRANCH -- $env:SOURCE_URL source
                    if ($LASTEXITCODE -ne 0) { throw 'Git checkout failed.' }
                '''
                script {
                    env.PACKAGE_COMMIT = powershell(returnStdout: true, script: '''
                        & $env:WIN_GIT -C source rev-parse --verify HEAD
                        if ($LASTEXITCODE -ne 0) { throw 'Could not determine the source commit.' }
                    ''').trim()
                    if (!(env.PACKAGE_COMMIT ==~ /[a-f0-9]{40}/)) {
                        error('The checkout did not return a valid Git commit.')
                    }
                    def userCause = currentBuild.getBuildCauses().find { it.userId }
                    env.PACKAGE_REQUESTED_BY = userCause?.userId ?: 'automation'
                    currentBuild.description = env.SOURCE_BRANCH + ' @ ' + env.PACKAGE_COMMIT.take(12)
                }
                powershell '''
                    $ErrorActionPreference = 'Stop'
                    $env:PATH = (Split-Path $env:WIN_GIT -Parent) + ';' + $env:PATH
                    $bundle = Join-Path $PWD 'pipeline-input/docker-source.tar.gz'
                    & $env:WIN_PYTHON 'source/server/container/package.py' --output $bundle
                    if ($LASTEXITCODE -ne 0) { throw 'Docker source packaging failed.' }
                '''
                stash name: 'docker-source', includes: 'pipeline-input/docker-source.tar.gz'
            }
            post {
                unsuccessful {
                    deleteDir()
                }
            }
        }
        stage('Build and archive') {
            parallel {
                stage('Server Docker image') {
                    agent { label 'audio-mac-docker' }
                    steps {
                        deleteDir()
                        unstash 'docker-source'
                        sh '''#!/bin/bash
set -euo pipefail

export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"

docker() {
    command docker --context desktop-linux "$@"
}

tag="amd64-$(printf '%.12s' "$PACKAGE_COMMIT")-b$BUILD_NUMBER"
image="audio-translation-prod:$tag"
output=artifacts/docker
archive="audio-translation-prod-$tag.tar.gz"
mkdir -p docker-source "$output"
tar -xzf pipeline-input/docker-source.tar.gz -C docker-source
/usr/bin/python3 -c '
import json, sys
from pathlib import Path
source = json.loads(Path("docker-source/server/container/build-info.json").read_text(encoding="utf-8"))
assert source["commit"] == sys.argv[1] and source["source_dirty"] is False, source["commit"]
' "$PACKAGE_COMMIT"

trap 'docker image rm "$image" >/dev/null 2>&1 || true' EXIT
docker buildx build --progress plain --platform linux/amd64 --load --tag "$image" \
    --file docker-source/server/container/Dockerfile docker-source
test "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image")" = linux/amd64
docker run --rm --network none --platform linux/amd64 --entrypoint /usr/local/bin/python "$image" -c '
import json, platform, subprocess, sys
from pathlib import Path
assert platform.machine() == "x86_64"
assert Path("/workspace/server/frontend/dist/index.html").is_file()
source = json.loads(Path("/opt/source-build-info.json").read_text(encoding="utf-8"))
assert source["commit"] == sys.argv[1] and source["source_dirty"] is False
ffmpeg = subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0]
assert "7.0.2-static" in ffmpeg, ffmpeg
print("Verified linux/amd64, frontend, source commit and", ffmpeg)
' "$PACKAGE_COMMIT"
docker save "$image" | gzip -1 > "$output/$archive"
gzip -t "$output/$archive"
cp docker-source/server/container/build-info.json "$output/source-build-info.json"
image_id=$(docker image inspect --format '{{.Id}}' "$image")
(
    cd "$output"
    shasum -a 256 "$archive" > "$archive.sha256"
    cat "$archive.sha256"
    /usr/bin/python3 - "$archive" "$image" "$image_id" <<'PY'
import json, os, sys
from pathlib import Path
archive, tag, image_id = sys.argv[1:]
manifest = {
    "artifact": archive,
    "bytes": Path(archive).stat().st_size,
    "sha256": Path(archive + ".sha256").read_text().split()[0],
    "platform": "linux/amd64",
    "image": tag,
    "image_id": image_id,
    "git_commit": os.environ["PACKAGE_COMMIT"],
    "triggered_by": os.environ["PACKAGE_REQUESTED_BY"],
    "jenkins_build_url": os.environ["BUILD_URL"],
}
Path("build.json").write_text(json.dumps(manifest, indent=2) + "\\n", encoding="utf-8")
PY
)
'''
                        archiveArtifacts artifacts: 'artifacts/docker/*', fingerprint: true, onlyIfSuccessful: true
                    }
                    post {
                        cleanup {
                            deleteDir()
                        }
                    }
                }
                stage('Windows NetTap Upgrade') {
                    agent { label 'audio-windows' }
                    steps {
                        powershell '''
                            $ErrorActionPreference = 'Stop'
                            $sourceRoot = (Resolve-Path -LiteralPath 'source').Path
                            $commit = & $env:WIN_GIT -C $sourceRoot rev-parse --verify HEAD
                            if ($LASTEXITCODE -ne 0 -or $commit -ne $env:PACKAGE_COMMIT) {
                                throw 'The Windows checkout differs from the Docker source.'
                            }
                            $versionFile = Join-Path $sourceRoot 'driver/schemes/net-tap/bridge_audio_pipeline.py'
                            $matches = @(Select-String -LiteralPath $versionFile -Pattern '^\\s*NET_TAP_VERSION\\s*=\\s*"(?<version>[0-9]+(?:\\.[0-9]+)+)"')
                            if ($matches.Count -ne 1) { throw 'Could not determine NET_TAP_VERSION.' }
                            $version = $matches[0].Matches[0].Groups['version'].Value

                            $venv = Join-Path $PWD 'nettap-venv'
                            & $env:WIN_PYTHON -m venv $venv
                            if ($LASTEXITCODE -ne 0) { throw 'Could not create the NetTap build environment.' }
                            $env:NET_TAP_BUILD_PYTHON = Join-Path $venv 'Scripts/python.exe'
                            & (Join-Path $sourceRoot 'driver/packaging/build-net-tap-exe.ps1') -Clean
                            if ($LASTEXITCODE -ne 0) { throw 'NetTap PyInstaller build failed.' }

                            $profilePath = Join-Path $PWD 'pipeline-input/server-profile.json'
                            $profile = @{api_url = $env:NETTAP_SERVER; migration_id = $env:NETTAP_MIGRATION_ID; api_key = ''}
                            [IO.File]::WriteAllText($profilePath, ($profile | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
                            $output = New-Item -Path 'artifacts/windows' -ItemType Directory -Force
                            $filename = "NetTapClient-Upgrade-v$version"
                            $definition = Join-Path $sourceRoot 'driver/packaging/net-tap-upgrade.iss'
                            & $env:WIN_ISCC /Q "/DMyAppVersion=$version" "/DSourceRoot=$sourceRoot" "/DServerProfile=$profilePath" "/O$($output.FullName)" "/F$filename" $definition
                            if ($LASTEXITCODE -ne 0) { throw 'NetTap Inno Setup compilation failed.' }

                            $installer = Get-Item -LiteralPath (Join-Path $output.FullName "$filename.exe")
                            $file = [IO.File]::OpenRead($installer.FullName)
                            $sha256 = [Security.Cryptography.SHA256]::Create()
                            try {
                                if ($file.ReadByte() -ne 0x4d -or $file.ReadByte() -ne 0x5a) {
                                    throw 'The NetTap installer is not a Windows executable.'
                                }
                                $file.Position = 0
                                $hash = [BitConverter]::ToString($sha256.ComputeHash($file)).Replace('-', '').ToLowerInvariant()
                            } finally {
                                $sha256.Dispose()
                                $file.Dispose()
                            }
                            "$hash  $($installer.Name)" | Set-Content -LiteralPath "$($installer.FullName).sha256" -Encoding ASCII
                            $metadata = [ordered]@{
                                artifact = $installer.Name
                                bytes = $installer.Length
                                sha256 = $hash
                                installer_type = 'upgrade'
                                version = $version
                                git_commit = $env:PACKAGE_COMMIT
                                triggered_by = $env:PACKAGE_REQUESTED_BY
                                jenkins_build_url = $env:BUILD_URL
                            }
                            $metadataJson = $metadata | ConvertTo-Json
                            [IO.File]::WriteAllText((Join-Path $output.FullName 'build.json'), $metadataJson, [Text.UTF8Encoding]::new($false))
                            Write-Host "$hash  $($installer.Name)"
                        '''
                        archiveArtifacts artifacts: 'artifacts/windows/*', fingerprint: true, onlyIfSuccessful: true
                    }
                    post {
                        cleanup {
                            deleteDir()
                        }
                    }
                }
            }
        }
    }
}
