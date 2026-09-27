#!/usr/bin/env bash
set -Eeuo pipefail

workflow="build-debs.yml"
minimum_major=7

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) is required" >&2; exit 1; }

mapfile -t versions < <(
    git ls-remote --refs --tags https://github.com/mongodb/mongo.git 'refs/tags/r*' \
        | sed -nE 's#^[^[:space:]]+[[:space:]]+refs/tags/r([0-9]+\.[0-9]+\.[0-9]+)$#\1#p' \
        | sort -Vu
)

declare -A latest_by_major=()
for version in "${versions[@]}"; do
    major="${version%%.*}"
    if (( 10#$major >= minimum_major )); then
        latest_by_major["$major"]="$version"
    fi
done

if (( ${#latest_by_major[@]} == 0 )); then
    echo "No stable MongoDB tags found for major $minimum_major or newer" >&2
    exit 1
fi

default_branch="${DEFAULT_BRANCH:-$(gh repo view --json defaultBranchRef --jq '.defaultBranchRef.name')}"
mapfile -t majors < <(printf '%s\n' "${!latest_by_major[@]}" | sort -n)

for major in "${majors[@]}"; do
    version="${latest_by_major[$major]}"
    release_tag="mongodb-noavx-$version"
    if gh release view "$release_tag" >/dev/null 2>&1; then
        printf 'MongoDB %s: already published\n' "$version"
        continue
    fi

    printf 'Dispatching MongoDB %s\n' "$version"
    gh workflow run "$workflow" --ref "$default_branch" -f "mongo_version=$version"
done