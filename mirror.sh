#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

set -a
# shellcheck disable=SC1091
source "$SCRIPT_DIR/.env"
set +a

: "${GH_USER:?GH_USER must be set in .env}"
: "${GH_TOKEN:?GH_TOKEN must be set in .env}"
: "${FORGEJO_URL:?FORGEJO_URL must be set in .env}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN must be set in .env}"

FORGEJO_USER="${FORGEJO_USER:-$GH_USER}"
MIRROR_PRIVATE="${MIRROR_PRIVATE:-false}"
MIRROR_INTERVAL="${MIRROR_INTERVAL:-480m}"
ORG_VISIBILITY="${ORG_VISIBILITY:-public}"
ORG_WHITELIST="${ORG_WHITELIST:-}"

PER_PAGE=100

DRY_RUN=false

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -n, --dry-run   Print what would be done without making any changes
  -h, --help      Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

ensure_org() {
    local org="$1"
    if curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
        "$FORGEJO_URL/api/v1/orgs/$org" >/dev/null; then
        return 0
    fi
    if [[ "$DRY_RUN" == true ]]; then
        log "  [dry-run] Would create org $org in Forgejo"
        return 0
    fi
    log "  Creating org $org in Forgejo"
    curl -s -f -X POST "$FORGEJO_URL/api/v1/orgs" \
        -H "Authorization: token $FORGEJO_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"username\": \"$org\",
          \"full_name\": \"$org\",
          \"visibility\": \"$ORG_VISIBILITY\"
        }" >/dev/null
}

log "Mirroring GitHub repositories to Forgejo ($FORGEJO_URL)"
log "Mirroring private repos: $MIRROR_PRIVATE"
[[ "$DRY_RUN" == true ]] && log "Dry run mode: no changes will be made"

process_repos() {
    local repos="$1"

    if ! echo "$repos" | jq -e 'type == "array"' >/dev/null; then
        log "ERROR: unexpected GitHub API response: $repos"
        exit 1
    fi

    echo "$repos" | jq -r '.[] | @base64' | while read -r repo; do
        _jq() { echo "$repo" | base64 --decode | jq -r "$1"; }

        NAME=$(_jq '.name')
        PRIVATE=$(_jq '.private')
        OWNER=$(_jq '.owner.login')
        OWNER_TYPE=$(_jq '.owner.type')

        if [[ "$OWNER_TYPE" == "Organization" ]]; then
            if [[ -n "$ORG_WHITELIST" ]]; then
                ALLOWED=false
                for allowed in $(echo "$ORG_WHITELIST" | tr ',' ' '); do
                    if [[ "$allowed" == "$OWNER" ]]; then
                        ALLOWED=true
                        break
                    fi
                done
                if [[ "$ALLOWED" != true ]]; then
                    log "  Skipping $OWNER/$NAME (org not in whitelist)"
                    continue
                fi
            fi
            TARGET="$OWNER"
            ensure_org "$TARGET"
        else
            TARGET="$FORGEJO_USER"
        fi

        if [[ "$PRIVATE" == "true" && "$MIRROR_PRIVATE" != true ]]; then
            log "  Skipping private repo $OWNER/$NAME"
            continue
        fi

        DESIRED_PRIVATE=false
        if [[ "$PRIVATE" == "true" ]]; then
            DESIRED_PRIVATE=true
        fi

        if FG_REPO=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
            "$FORGEJO_URL/api/v1/repos/$TARGET/$NAME"); then
            FG_PRIVATE=$(echo "$FG_REPO" | jq -r '.private')
            FG_MIRROR=$(echo "$FG_REPO" | jq -r '.mirror')
            if [[ "$FG_MIRROR" == "true" && "$FG_PRIVATE" != "$DESIRED_PRIVATE" ]]; then
                if [[ "$DRY_RUN" == true ]]; then
                    log "  [dry-run] Would update visibility: $TARGET/$NAME -> private=$DESIRED_PRIVATE"
                elif curl -s -f -X PATCH "$FORGEJO_URL/api/v1/repos/$TARGET/$NAME" \
                    -H "Authorization: token $FORGEJO_TOKEN" \
                    -H "Content-Type: application/json" \
                    -d "{\"private\": $DESIRED_PRIVATE}" >/dev/null; then
                    log "  Visibility updated: $TARGET/$NAME -> private=$DESIRED_PRIVATE"
                else
                    log "  ERROR: failed to update visibility of $TARGET/$NAME"
                fi
            else
                log "  Already exists: $TARGET/$NAME, skipping"
            fi
            continue
        fi

        log "Importing $OWNER/$NAME as mirror -> $TARGET"

        if [[ "$DRY_RUN" == true ]]; then
            log "  [dry-run] Would import as mirror"
            continue
        fi

        if [[ "$PRIVATE" == "true" ]]; then
            CLONE_URL="https://github.com/$OWNER/$NAME.git"
            MIGRATE_AUTH=$',
              "auth_username": "'"$GH_USER"'",
              "auth_password": "'"$GH_TOKEN"'"'
        else
            CLONE_URL="https://github.com/$OWNER/$NAME.git"
            MIGRATE_AUTH=""
        fi

        local migrate_body migrate_code
        migrate_body=$(curl -s -w $'\n%{http_code}' -X POST "$FORGEJO_URL/api/v1/repos/migrate" \
            -H "Authorization: token $FORGEJO_TOKEN" \
            -H "Content-Type: application/json" \
            -d "{
              \"clone_addr\": \"$CLONE_URL\",
              \"repo_name\": \"$NAME\",
              \"repo_owner\": \"$TARGET\",
              \"mirror\": true,
              \"mirror_interval\": \"$MIRROR_INTERVAL\"$MIGRATE_AUTH,
              \"private\": $DESIRED_PRIVATE
            }")
        migrate_code="${migrate_body##*$'\n'}"
        migrate_body="${migrate_body%$'\n'$migrate_code}"
        if [[ "$migrate_code" != "200" && "$migrate_code" != "201" ]]; then
            log "  ERROR: failed to import $OWNER/$NAME (HTTP $migrate_code): $migrate_body"
            continue
        fi

        log "  Imported as mirror"
    done
}

fetch_endpoint() {
    local url="$1"
    local page=1

    while :; do
        local response code body count
        response=$(curl -s -w $'\n%{http_code}' -H "Authorization: token $GH_TOKEN" \
            "$url&per_page=$PER_PAGE&page=$page")
        code="${response##*$'\n'}"
        body="${response%$'\n'$code}"

        if [[ "$code" != "200" ]]; then
            if [[ "$code" == "404" ]]; then
                log "  Skipping $url (404: org not found or not accessible)"
                return 0
            fi
            log "ERROR: GitHub API returned HTTP $code for $url: $body"
            exit 1
        fi

        count=$(echo "$body" | jq length)
        [[ "$count" -eq 0 ]] && break

        log "Processing page $page ($count repos) from $url"
        process_repos "$body"
        page=$((page + 1))
    done
}

if [[ -n "$ORG_WHITELIST" ]]; then
    fetch_endpoint "https://api.github.com/user/repos?affiliation=owner"
    for org in $(echo "$ORG_WHITELIST" | tr ',' ' '); do
        fetch_endpoint "https://api.github.com/orgs/$org/repos?type=all"
    done
else
    fetch_endpoint "https://api.github.com/user/repos?affiliation=owner,organization_member"
fi

log "Repository mirror import complete."
