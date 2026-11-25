#!/bin/bash
set -euo pipefail
umask 077

root=$(cd "$(dirname "$0")" && pwd -P)
archives=$1
receipt=$2
url=http://192.168.11.147:18100
export PATH="/Applications/Docker.app/Contents/Resources/bin:$PATH"

docker() { command docker --context desktop-linux "$@"; }
compose() {
    local settings=$1
    shift
    docker compose --project-name audio-translation-test --project-directory "$root" \
        --env-file "$settings" --file "$root/compose.yaml" "$@"
}

metadata=$(/usr/bin/python3 - "$archives/build.json" "$PACKAGE_BUILD_NUMBER" <<'PY'
import json
import re
import sys
from pathlib import Path

manifest = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
commit, number = manifest["git_commit"], sys.argv[2]
assert re.fullmatch(r"[0-9a-f]{40}", commit)
assert re.fullmatch(r"[1-9][0-9]*", number)
tag = "amd64-" + commit[:12] + "-b" + number
assert manifest["platform"] == "linux/amd64"
assert manifest["image"] == "audio-translation-prod:" + tag
assert manifest["artifact"] == "audio-translation-prod-" + tag + ".tar.gz"
assert re.fullmatch(r"sha256:[0-9a-f]{64}", manifest["image_id"])
assert re.fullmatch(r"[0-9a-f]{64}", manifest["sha256"])
print(tag, manifest["image_id"], manifest["sha256"], manifest["artifact"], commit)
PY
)
read -r tag expected_id expected_hash archive commit <<< "$metadata"
archive_path="$archives/$archive"
actual_hash=$(shasum -a 256 "$archive_path" | awk '{print $1}')
read -r checksum checksum_name < "$archive_path.sha256"
[[ "$actual_hash" == "$expected_hash" && "$checksum" == "$expected_hash" && "$checksum_name" == "$archive" ]]

mkdir -p "$root/releases"
release_dir=$(mktemp -d "$root/releases/$tag.XXXXXXXX")
candidate="$release_dir/compose.env"
current="$root/current.env"
source_image="audio-translation-prod:$tag"
test_image="audio-translation-test:$tag"
container=
switched=0
accepted=0

finish() {
    local result=$?
    trap - EXIT
    if [[ -n "$container" ]]; then docker rm "$container" >/dev/null || true; fi
    if [[ "$switched" == 1 && "$accepted" == 0 ]]; then
        compose "$candidate" logs --tail 25 || true
        if [[ -f "$current" ]]; then
            compose "$current" up --detach --wait --wait-timeout 120 ||
                echo 'The previous test release could not be restored.' >&2
        else
            compose "$candidate" down || true
        fi
    fi
    exit "$result"
}
trap finish EXIT

docker load --input "$archive_path"
[[ "$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$source_image")" == "$expected_id linux/amd64" ]]
docker tag "$source_image" "$test_image"
mkdir -p "$release_dir/frontend/_test"
container=$(docker create --platform linux/amd64 "$test_image")
docker cp "$container:/workspace/server/frontend/dist/." "$release_dir/frontend"
test -s "$release_dir/frontend/index.html"

/usr/bin/python3 - "$archives/build.json" "$release_dir/frontend/_test/version.json" "$test_image" "$url" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

source, destination, image, url = sys.argv[1:]
package = json.loads(Path(source).read_text(encoding="utf-8"))
version = {
    "environment": "test",
    "url": url,
    "git_commit": package["git_commit"],
    "image": image,
    "image_id": package["image_id"],
    "archive_sha256": package["sha256"],
    "package_build_url": package["jenkins_build_url"],
    "deployment_build_url": os.environ["BUILD_URL"],
    "triggered_by": os.environ["TEST_REQUESTED_BY"],
    "deployed_at": datetime.now(timezone.utc).isoformat(),
}
Path(destination).write_text(json.dumps(version, indent=2) + "\n", encoding="utf-8")
PY

chmod 755 "$release_dir/frontend" "$release_dir/frontend/_test"
chmod 644 "$release_dir/frontend/_test/version.json"
printf "TEST_IMAGE='%s'\nTEST_FRONTEND_DIR='%s'\n" "$test_image" "$release_dir/frontend" > "$candidate"
compose "$candidate" config --quiet
switched=1
compose "$candidate" up --detach --wait --wait-timeout 150

/usr/bin/python3 - "$url" "$commit" <<'PY'
import json
import re
import sys
from urllib.request import ProxyHandler, build_opener

url, commit = sys.argv[1:]
client = build_opener(ProxyHandler({}))

def fetch(path):
    with client.open(url + path, timeout=8) as response:
        assert response.headers["X-AudioTranslation-Environment"] == "test"
        return response.headers, response.read()

_, homepage = fetch("/")
asset = re.search(rb'src="(/assets/[^"]+\.js)"', homepage)
assert asset, "The test frontend did not return a built JavaScript entry"
headers, script = fetch(asset.group(1).decode())
assert script and "javascript" in headers["Content-Type"]
_, health = fetch("/api/health")
assert json.loads(health) == {"status": "ok", "provider": "mock"}
_, logs = fetch("/_test/client-logs-health")
assert json.loads(logs) == {"status": "ok", "service": "client-logs"}
_, version = fetch("/_test/version.json")
assert json.loads(version)["git_commit"] == commit
print("Verified test frontend, JavaScript, backend, client diagnostics and deployed commit.")
PY
cp "$release_dir/frontend/_test/version.json" "$receipt"
mv "$candidate" "$current"
accepted=1
printf 'Test release %s is serving at %s\n' "$test_image" "$url"
