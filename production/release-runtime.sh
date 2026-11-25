#!/bin/bash
# Shared by the production gate and the isolated rollback rehearsal.

compose_for() {
    local tag=$1
    shift
    IMAGE_TAG="$tag" docker compose --project-name "$PROJECT" \
        --project-directory "$DEPLOY_ROOT" --file "$COMPOSE_FILE" "$@"
}

runtime_up() {
    local tag=$1
    compose_for "$tag" up --detach --wait --wait-timeout 300 --no-build --pull never || return
    local service container
    for service in backend client-logs; do
        container=$(compose_for "$tag" ps -q "$service") || return
        [[ -n "$container" ]] || return 1
        [[ "$(docker inspect --format '{{.Config.Image}} {{.State.Health.Status}}' "$container")" \
            == "audio-translation-prod:$tag healthy" ]] || return 1
    done
}

frontend_to() {
    local tag=$1
    local link="$FRONTEND_ROOT/.dist.$BASHPID"
    [[ -L "$FRONTEND_ROOT/dist" && -s "$FRONTEND_ROOT/releases/$tag/index.html" ]] || return 1
    ln -s "releases/$tag" "$link" || return
    mv -Tf "$link" "$FRONTEND_ROOT/dist" || { rm -f -- "$link"; return 1; }
}

record_tag() {
    local file=$1 tag=$2 partial
    partial=$(mktemp "$file.XXXXXXXX") || return
    if printf '%s\n' "$tag" > "$partial" && mv -Tf "$partial" "$file"; then return 0; fi
    rm -f -- "$partial"
    return 1
}

activate_transaction() (
    target=$1 previous=$2 completed=0
    old_previous=""
    [[ ! -e "$DEPLOY_ROOT/.previous-image-tag" ]] || old_previous=$(<"$DEPLOY_ROOT/.previous-image-tag")

    restore_on_exit() {
        local result=$?
        trap - EXIT HUP INT TERM
        if [[ "$completed" == 0 ]]; then
            echo "Release failed; restoring $previous." >&2
            if runtime_up "$previous" && frontend_to "$previous" &&
               record_tag "$DEPLOY_ROOT/.image-tag" "$previous"; then
                if [[ -n "$old_previous" ]]; then
                    record_tag "$DEPLOY_ROOT/.previous-image-tag" "$old_previous" || exit 1
                else
                    rm -f -- "$DEPLOY_ROOT/.previous-image-tag"
                fi
                if verify_release "$previous"; then
                    echo "Restored and verified $previous." >&2
                else
                    echo "Previous containers and frontend restored; acceptance check failed." >&2
                    exit 1
                fi
            else
                echo "CRITICAL: production rollback failed for $previous." >&2
                exit 1
            fi
        fi
        exit "$result"
    }

    trap restore_on_exit EXIT
    trap 'exit 1' HUP INT TERM
    runtime_up "$target" || exit 1
    frontend_to "$target" || exit 1
    verify_release "$target" || exit 1
    record_tag "$DEPLOY_ROOT/.previous-image-tag" "$previous" || exit 1
    record_tag "$DEPLOY_ROOT/.image-tag" "$target" || exit 1
    completed=1
)
