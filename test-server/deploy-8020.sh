#!/bin/bash
set -Eeuo pipefail
trap 'echo "deploy-8020.sh failed at line $LINENO: $BASH_COMMAND" >&2' ERR
umask 077

root=$(cd "$(dirname "$0")" && pwd -P)
archives=$1
receipt=$2
url=http://192.168.11.147:8020
dataset="$HOME/qa-data/case-form-top100-20261125"
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"

docker() { command docker --context desktop-linux "$@"; }

compose() {
    local config=$1 tag=$2
    shift 2
    IMAGE_TAG="$tag" BIND_ADDRESS=192.168.11.147 GATEWAY_PORT=8020 ACCURACY_DATASET_DIR="$dataset" \
        docker compose --project-name audio-test-server --project-directory "$config" \
        --file "$config/compose.yaml" "$@"
}

metadata=$(/usr/bin/python3 - "$archives" "$PACKAGE_BUILD_NUMBER" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

directory, number = Path(sys.argv[1]), sys.argv[2]
manifest = json.loads((directory / "build.json").read_text(encoding="utf-8"))
source = json.loads((directory / "source-build-info.json").read_text(encoding="utf-8"))
commit = manifest["git_commit"]
assert re.fullmatch(r"[0-9a-f]{40}", commit)
assert re.fullmatch(r"[1-9][0-9]*", number)
assert source["commit"] == commit and source["source_dirty"] is False
tag = f"amd64-{commit[:12]}-b{number}"
assert manifest["platform"] == "linux/amd64"
assert manifest["image"] == f"audio-translation-prod:{tag}"
assert manifest["artifact"] == f"audio-translation-prod-{tag}.tar.gz"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", manifest["image_id"])
assert re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"])
for name in ("compose.yaml", "gateway.conf"):
    digest = hashlib.sha256((directory / name).read_bytes()).hexdigest()
    assert digest == source["source_sha256"]["server/container/" + name], name
print(tag, manifest["image_id"], manifest["sha256"], manifest["artifact"], commit)
PY
)
read -r tag expected_id expected_hash archive commit <<< "$metadata"
archive_path="$archives/$archive"
actual_hash=$(shasum -a 256 "$archive_path" | awk '{print $1}')
read -r checksum checksum_name < "$archive_path.sha256"
[[ "$actual_hash" == "$expected_hash" && "$checksum" == "$expected_hash" && "$checksum_name" == "$archive" ]]

test -s "$root/secrets.env"
test -s "$root/production-reference.json"
test -d "$dataset"
compgen -G "$root/audio/*.wav" >/dev/null
mkdir -p "$root/releases"
release=$(mktemp -d "$root/releases/$tag.XXXXXXXX")
current="$root/current-release"
previous=
if [[ -f "$current" ]]; then
    previous=$(<"$current")
    [[ "$previous" == "$root/releases/"* && -f "$previous/image-tag" && -f "$previous/compose.yaml" ]]
fi

cp "$archives/compose.yaml" "$archives/gateway.conf" "$release/"
ln -s "$root/secrets.env" "$release/secrets.env"
ln -s "$root/production-reference.json" "$release/production-reference.json"
ln -s "$root/audio" "$release/audio"
printf '%s\n' "$tag" > "$release/image-tag"
compose "$release" "$tag" config --format json | /usr/bin/python3 -c '
import json, sys
config = json.load(sys.stdin)
app, gateway = (config["services"][name] for name in ("app", "gateway"))
assert config["name"] == "audio-test-server"
assert set(config["services"]) == {"app", "gateway"}
assert app["environment"]["AUDIO_TEST_SERVER"] == "1"
assert not app.get("ports")
ports = gateway["ports"]
assert len(ports) == 1 and ports[0]["host_ip"] == "192.168.11.147" and str(ports[0]["published"]) == "8020"
assert config["volumes"]["runtime"]["name"] == "audio-test-server_runtime"
assert any(mount["target"] == "/qa-dataset" and mount["read_only"] for mount in app["volumes"])
'

switched=0
finish() {
    local result=$?
    trap - EXIT
    if [[ "$result" != 0 && "$switched" == 1 ]]; then
        compose "$release" "$tag" ps || true
        if [[ -n "$previous" ]]; then
            compose "$previous" "$(<"$previous/image-tag")" up --detach --wait --wait-timeout 300 --no-build --pull never ||
                echo 'Could not restore the previous 8020 release.' >&2
        else
            compose "$release" "$tag" stop || true
        fi
    fi
    exit "$result"
}
trap finish EXIT

docker load --input "$archive_path"
image="audio-translation-prod:$tag"
[[ "$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$image")" == "$expected_id linux/amd64" ]]
switched=1
compose "$release" "$tag" up --detach --wait --wait-timeout 300 --no-build --pull never

/usr/bin/python3 - "$url" "$commit" "$archives/build.json" "$receipt" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path
from urllib.request import ProxyHandler, build_opener

url, commit, manifest, receipt = sys.argv[1:]
opener = build_opener(ProxyHandler({}))

def fetch(path):
    with opener.open(url + path, timeout=15) as response:
        assert response.status == 200 and response.headers["X-AudioTranslation-Environment"] == "test", path
        return response.read()

assert "测试服".encode() in fetch("/")
assert json.loads(fetch("/api/health"))["status"] == "ok"
assert json.loads(fetch("/sim/api/status"))["backend_alive"] is True
assert json.loads(fetch("/sim/api/build-info"))["commit"] == commit
accuracy = json.loads(fetch("/accuracy/api/health"))
assert accuracy["status"] == "ok" and accuracy["test_server"] is True
assert accuracy["dataset_cases"] == 100 and accuracy["dataset_audio"] == 100
assert accuracy["model_key"] is True
assert fetch("/?mode=records")
package = json.loads(Path(manifest).read_text(encoding="utf-8"))
deployment = {
    "environment": "test",
    "url": url,
    "git_commit": commit,
    "image": package["image"],
    "archive_sha256": package["sha256"],
    "package_build_url": package["jenkins_build_url"],
    "deployment_build_url": os.environ["BUILD_URL"],
    "triggered_by": os.environ["TEST_REQUESTED_BY"],
    "dataset_cases": accuracy["dataset_cases"],
    "dataset_audio": accuracy["dataset_audio"],
    "deployed_at": datetime.now(timezone.utc).isoformat(),
}
Path(receipt).write_text(json.dumps(deployment, indent=2) + "\n", encoding="utf-8")
print("Read-only checks passed for the portal, backend, simulation status, build commit, accuracy health and records page.")
PY
printf '%s\n' "$release" > "$release/current-release"
mv "$release/current-release" "$current"
printf 'Test release %s is serving at %s\n' "$tag" "$url"
