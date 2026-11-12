#!/bin/bash
# Usage: scripts/merge_prs.sh <github repo, e.g. CocoaPods/Xcodeproj> <dir> <PR number>...
# Clones (or resets) <dir> to the repo's master and merges the PRs' heads in the order given.
# CHANGELOG.md merges by union. A conflict is taken from a resolution recorded under resolutions/<repo name>/
# (git rerere's cache, see resolutions/README.md); one confined to spec/ keeps the side already merged
# (only lib/ is used); any other conflict stops with the files listed.
set -eo pipefail
repo=$1 dir=$2; shift 2
here=$(cd "$(dirname "$0")/.." && pwd)
name=${repo#*/}
attrs="$here/resolutions/union.attributes"
cache="$here/resolutions/$name"
[ -e "$dir/.git" ] || git clone --quiet "https://github.com/$repo.git" "$dir"
G=(git -C "$dir" -c core.attributesFile="$attrs" -c rerere.enabled=true -c user.name=corpus -c user.email=corpus@localhost)
git -C "$dir" fetch --quiet origin master
git -C "$dir" merge --abort 2>/dev/null || true
git -C "$dir" checkout --quiet --detach origin/master
git -C "$dir" reset --quiet --hard origin/master
rr=$(git -C "$dir" rev-parse --git-path rr-cache)
rr=$(cd "$dir" && mkdir -p "$rr" && cd "$rr" && pwd)
[ -d "$cache" ] && cp -R "$cache"/. "$rr"/
for n in "$@"; do
  [[ $n =~ ^[0-9]+$ ]] || { echo "not a PR number: $n"; exit 1; }
  git -C "$dir" fetch --quiet --force origin "pull/${n}/head:refs/pr/${n}"
  sha=$(git -C "$dir" rev-parse --short "refs/pr/${n}")
  if "${G[@]}" merge --quiet --no-edit -m "Merge #${n}" "refs/pr/${n}" > /dev/null 2>&1; then
    echo "$name #${n} ${sha}: merged"
    continue
  fi
  left=$("${G[@]}" rerere remaining)
  how=""
  [ -n "$left" ] || how="recorded resolution"
  if [ -n "$left" ] && ! grep -qv '^spec/' <<< "$left"; then
    while IFS= read -r f; do git -C "$dir" checkout --ours -- "$f"; done <<< "$left"
    how="spec conflicts kept the side already merged"
  fi
  if [ -z "$how" ]; then
    echo "$name #${n} ${sha}: conflicts with the PRs merged before it in: $(tr '\n' ' ' <<< "$left")"
    git -C "$dir" merge --abort
    exit 1
  fi
  git -C "$dir" add -u
  "${G[@]}" commit --quiet --no-edit
  echo "$name #${n} ${sha}: merged ($how)"
done
echo "$name: master $(git -C "$dir" rev-parse --short origin/master) + ${*/#/#}"
