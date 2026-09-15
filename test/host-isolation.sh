#!/usr/bin/env bash
# Exercise real gh's credential selection using only dummy tokens, offline.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
gh_as=$here/../gh-as
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

command -v gh >/dev/null
export GH_CONFIG_DIR=$tmp
export GIT_CONFIG_GLOBAL=$tmp/gitconfig
export GIT_CONFIG_NOSYSTEM=1
export GH_PROMPT_DISABLED=1
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_AS_REMOTE GH_AS_QUIET
: >"$GIT_CONFIG_GLOBAL"

for host in github.com example.ghe.com ghe.example.com github.localhost; do
  cat >>"$tmp/hosts.yml" <<CONFIG
$host:
    user: active
    oauth_token: dummy-active-$host
    users:
        active:
            oauth_token: dummy-active-$host
        selected:
            oauth_token: dummy-selected-$host
CONFIG
done

# A shell lets us inspect gh's token selection without the wrapper's direct
# `gh auth` guard. auth token reads local storage and makes no API requests.
for host in github.com example.ghe.com ghe.example.com github.localhost; do
  actual=$("$gh_as" --quiet --host "$host" selected -- sh -c 'gh auth token')
  [[ $actual == "dummy-selected-$host" ]] || {
    printf 'FAIL selected account on %s\n' "$host" >&2
    exit 1
  }
  printf 'ok   selected account on %s\n' "$host"
done

actual=$(GH_HOST=ghe.example.com "$gh_as" --quiet --host github.com selected -- sh -c 'gh auth token')
[[ $actual == dummy-selected-github.com ]] || {
  printf 'FAIL explicit host overrides inherited GH_HOST\n' >&2
  exit 1
}
printf 'ok   explicit host overrides inherited GH_HOST\n'
