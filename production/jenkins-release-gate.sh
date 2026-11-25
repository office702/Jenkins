#!/bin/bash
set -euo pipefail
umask 077

if [[ "$(id -u)" != 0 ]]; then
    [[ "$#" == 0 ]] || exit 64
    exec sudo -n SSH_ORIGINAL_COMMAND="${SSH_ORIGINAL_COMMAND:-}" "$0"
fi

DEPLOY_ROOT=/opt/audioTranslation/container
FRONTEND_ROOT=/opt/audioTranslation/frontend
COMPOSE_FILE="$DEPLOY_ROOT/compose.prod.yaml"
PROJECT=audio-prod
cd "$DEPLOY_ROOT"
source "$DEPLOY_ROOT/release-runtime.sh"

die() { echo "Production release stopped: $*" >&2; exit 1; }

if [[ "$#" -gt 0 && -z "${SSH_ORIGINAL_COMMAND:-}" ]]; then
    [[ "$#" == 5 && "$1" == activate-staged ]] || die 'invalid administrator action'
    action=$1 tag=$2 digest=$3 commit=$4 image_id=$5
else
    [[ "$#" == 0 ]] || die 'invalid SSH arguments'
    read -r action tag digest commit image_id extra <<< "${SSH_ORIGINAL_COMMAND:-}"
    if [[ "$action" == status && -z "$tag" ]]; then
        printf 'Live image: %s\n' "$(<.image-tag)"
        exit 0
    fi
    [[ "$action" == release-verified && -z "$extra" ]] || die 'invalid release request'
fi
[[ "$commit" =~ ^[0-9a-f]{40}$ && "$digest" =~ ^[0-9a-f]{64}$ &&
   "$image_id" =~ ^sha256:[0-9a-f]{64}$ && "$tag" =~ ^amd64-[0-9a-f]{12}-b[1-9][0-9]*$ &&
   "$tag" == "amd64-${commit:0:12}-b"* ]] || die 'invalid release metadata'

exec 9>/run/lock/audio-deploy-gate.lock
flock -n 9 || die 'another production deployment holds the lock'
previous=$(<.image-tag)
[[ "$previous" =~ ^amd64-[0-9A-Za-z.-]+$ && "$previous" != "$tag" ]] || die 'invalid current release'

current_ok() {
    [[ "$(<.image-tag)" == "$previous" && "$(readlink "$FRONTEND_ROOT/dist")" == "releases/$previous" ]] || return 1
    [[ -s "$FRONTEND_ROOT/releases/$previous/index.html" ]] || return 1
    docker image inspect "audio-translation-prod:$previous" >/dev/null || return
    local service
    for service in backend client-logs; do
        [[ "$(docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' "audio-prod-$service-1")" \
            == "audio-translation-prod:$previous healthy" ]] || return 1
    done
}
current_ok || die 'cannot establish a known healthy rollback target'

archive="$DEPLOY_ROOT/images/$tag.tar.gz"
partial=""
trap '[[ -z "$partial" ]] || rm -f -- "$partial"' EXIT
if [[ "$action" == release-verified ]]; then
    [[ "$(df --output=avail -k "$DEPLOY_ROOT" | tail -1)" -gt $((3 * 1024 * 1024)) ]] || die 'less than 3 GiB free'
    partial=$(mktemp "$DEPLOY_ROOT/images/.$tag.release.XXXXXXXX")
    cat > "$partial"
    [[ "$(sha256sum "$partial" | awk '{print $1}')" == "$digest" ]] || die 'uploaded SHA-256 does not match'
    gzip -t "$partial" || die 'invalid gzip archive'
    /usr/bin/python3 - "$partial" "$tag" <<'PY'
import json, sys, tarfile
with tarfile.open(sys.argv[1], "r:gz") as archive:
    manifest = archive.getmember("manifest.json")
    if not manifest.isfile() or manifest.size > 1_048_576:
        sys.exit("Invalid Docker archive manifest.")
    entries = json.load(archive.extractfile(manifest))
assert len(entries) == 1 and entries[0]["RepoTags"] == ["audio-translation-prod:" + sys.argv[2]]
PY
    if [[ -e "$archive" ]]; then
        [[ "$(sha256sum "$archive" | awk '{print $1}')" == "$digest" ]] || die 'archive already exists with different content'
    else
        mv "$partial" "$archive"
    fi
fi
[[ -f "$archive" && "$(sha256sum "$archive" | awk '{print $1}')" == "$digest" ]] ||
    die 'server archive full SHA-256 does not match'
echo "Verified full SHA-256 for $tag: $digest" >&2

if docker container inspect audio-preflight >/dev/null 2>&1; then die 'a preflight container already exists'; fi
[[ -z "$(ss -H -ltn '( sport = :18000 )')" ]] || die 'isolated port is occupied'
preflight_log=$(mktemp "$DEPLOY_ROOT/images/.$tag.release-preflight.XXXXXXXX")
if ! {
    IMAGE_TAG="$tag" bash "$DEPLOY_ROOT/deploy-prod.sh" load "$archive" &&
    [[ "$(docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "audio-translation-prod:$tag")" == "$image_id linux/amd64" ]] &&
    IMAGE_TAG="$tag" bash "$DEPLOY_ROOT/deploy-prod.sh" preflight
} > "$preflight_log" 2>&1; then
    if [[ "$(docker inspect --format '{{.Config.Image}}' audio-preflight 2>/dev/null || true)" == "audio-translation-prod:$tag" ]]; then
        docker rm -f audio-preflight >/dev/null || true
    fi
    die "isolated preflight failed; local diagnostics: $preflight_log"
fi
rm -f -- "$preflight_log"
echo 'Isolated startup and frontend staging passed.' >&2

verify_release() {
    local selected=$1
    /usr/bin/python3 - "$FRONTEND_ROOT/releases/$selected/index.html" <<'PY'
import json
import re
import sys
from pathlib import Path
from urllib.request import ProxyHandler, build_opener

client = build_opener(ProxyHandler({}))
base = "https://43.136.77.153"

def get(url):
    with client.open(url, timeout=10) as response:
        assert response.status == 200, url
        return response.headers, response.read()

assert json.loads(get("http://127.0.0.1:8000/api/health")[1])["status"] == "ok"
assert json.loads(get("http://127.0.0.1:8001/health")[1])["service"] == "client-logs"
assert json.loads(get(base + "/api/health")[1])["status"] == "ok"
_, html = get(base + "/?mode=records")
assert html == Path(sys.argv[1]).read_bytes(), "public frontend does not match the selected release"
asset = re.search(rb'src="(/assets/[^"]+\.js)"', html)
assert asset, "frontend entry was not found"
headers, entry = get(base + asset.group(1).decode("ascii"))
assert entry and ("javascript" in headers.get("Content-Type", ""))
PY
}

wait_idle() {
    local deadline=$((SECONDS + 300)) result
    while (( SECONDS < deadline )); do
        if /usr/bin/python3 "$DEPLOY_ROOT/check-call-idle.py"; then
            sleep 2
            if /usr/bin/python3 "$DEPLOY_ROOT/check-call-idle.py"; then return 0; else result=$?; fi
        else
            result=$?
        fi
        [[ "$result" == 75 ]] || return "$result"
        sleep 12
    done
    return 75
}

verify_release "$previous" || die 'current public production checks failed before cutover'
wait_idle || die 'both capture paths did not become idle and verifiable'
current_ok || die 'live release changed while preparing cutover'
/usr/bin/python3 "$DEPLOY_ROOT/check-call-idle.py" || die 'capture status changed immediately before cutover'
activate_transaction "$tag" "$previous" >&2
/usr/bin/python3 - "$tag" "$previous" "$digest" "$commit" <<'PY'
import json, sys
tag, previous, digest, commit = sys.argv[1:]
print(json.dumps({
    "live_tag": tag, "previous_tag": previous, "sha256": digest, "commit": commit,
    "preflight": "passed", "capture_idle": True, "public_https": "passed",
}))
PY
