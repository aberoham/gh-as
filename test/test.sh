#!/usr/bin/env bash
# Exercises gh-as against a stub `gh`, so no account and no network is needed.
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
gh_as=$here/../gh-as

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail

host=github.com
user=
subcommand="${1:-} ${2:-}"
for arg in "$@"; do
  case $arg in
    --hostname=*) host=${arg#*=} ;;
    --user=*) user=${arg#*=} ;;
  esac
done
while [ $# -gt 0 ]; do
  case $1 in
    --hostname | -h) host=${2:-} ;;
    --user | -u) user=${2:-} ;;
  esac
  shift
done

# gh-as must clear inherited tokens before asking, or the answer is whatever
# the environment happened to carry.
if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ]; then
  echo "AMBIENT-TOKEN-LEAKED"
  exit 0
fi

case $subcommand in
  "auth status")
    if [ -z "${GH_STUB_ACCOUNTS:-}" ]; then
      echo "You are not logged into any GitHub hosts." >&2
      exit 1
    fi
    echo "$host"
    for account in ${GH_STUB_ACCOUNTS}; do
      echo "  ✓ Logged in to $host account $account (keyring)"
    done
    ;;
  "auth token")
    for account in ${GH_STUB_ACCOUNTS:-}; do
      if [ "$account" = "$user" ]; then
        echo "token-$account-$host"
        exit 0
      fi
    done
    echo "no oauth token found for $host account $user" >&2
    exit 1
    ;;
  *)
    echo "stub gh: unexpected call: $*" >&2
    exit 2
    ;;
esac
STUB
chmod +x "$tmp/bin/gh"

export PATH=$tmp/bin:$PATH
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL=$tmp/gitconfig
: >"$tmp/gitconfig"
export GH_STUB_ACCOUNTS="alice alice-work"
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN GH_HOST GH_AS_REMOTE GH_AS_QUIET

passed=0
failed=0

check() {
  local desc=$1 expected=$2 actual=$3
  if [ "$expected" = "$actual" ]; then
    passed=$((passed + 1))
    printf 'ok   %s\n' "$desc"
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

run() {
  "$gh_as" "$@" 2>/dev/null
}

repo() {
  local dir=$tmp/repos/$1 url=$2
  rm -rf "$dir"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" remote add origin "$url"
  printf '%s\n' "$dir"
}

# shellcheck disable=SC2016  # the command runs in the child shell, not here
show_env='printf %s "$GH_AS_ACCOUNT|$GH_TOKEN|${GH_ENTERPRISE_TOKEN:-}|${GH_HOST:-}"'

personal=$(repo personal https://github.com/alice/blog.git)
work=$(repo work https://github.com/acme/service.git)
scp_style=$(repo scp git@github.com:acme/service.git)
other=$(repo other https://gitlab.com/alice/thing.git)
unmapped=$(repo unmapped https://github.com/nobody/thing.git)

check 'explicit account wins' \
  'alice-work|token-alice-work-github.com||' \
  "$(cd "$personal" && run alice-work -- sh -c "$show_env")"

git -C "$work" config 'gh-as.https://github.com/acme.account' alice-work
check 'gh-as.account resolves the account' \
  'alice-work|token-alice-work-github.com||' \
  "$(cd "$work" && run sh -c "$show_env")"

git -C "$scp_style" config 'credential.https://github.com/acme.username' alice-work
check 'scp-style remote resolves through credential.username' \
  'alice-work|token-alice-work-github.com||' \
  "$(cd "$scp_style" && run sh -c "$show_env")"

git -C "$work" config 'credential.https://github.com/acme.username' alice
check 'gh-as.account takes precedence over credential.username' \
  'alice-work' \
  "$(cd "$work" && run --print)"

check 'owner matching a logged-in account resolves it' \
  'alice' \
  "$(cd "$personal" && run --print)"

check 'the only logged-in account is used when nothing else matches' \
  'solo' \
  "$(cd "$unmapped" && GH_STUB_ACCOUNTS=solo "$gh_as" --print 2>/dev/null)"

check 'inherited tokens are cleared before asking gh' \
  'alice-work|token-alice-work-github.com||' \
  "$(cd "$personal" && GH_TOKEN=ambient run alice-work -- sh -c "$show_env")"

check 'an enterprise host gets GH_ENTERPRISE_TOKEN and GH_HOST' \
  'alice||token-alice-ghe.example.com|ghe.example.com' \
  "$(cd "$personal" && run --host ghe.example.com alice -- sh -c "$show_env")"

check 'GH_AS_REMOTE selects the remote' \
  'alice-work' \
  "$(cd "$personal" && git remote add work https://github.com/acme/service.git && git config 'gh-as.https://github.com/acme.account' alice-work && GH_AS_REMOTE=work "$gh_as" --print 2>/dev/null)"

check 'quiet suppresses the announcement' \
  '' \
  "$(cd "$personal" && "$gh_as" --quiet alice -- true 2>&1)"

check 'the account is announced on stderr' \
  'gh-as: running as alice' \
  "$(cd "$personal" && "$gh_as" alice -- true 2>&1 1>/dev/null)"

fails() {
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then
    failed=$((failed + 1))
    printf 'FAIL %s\n     expected a non-zero exit\n' "$desc"
  else
    passed=$((passed + 1))
    printf 'ok   %s\n' "$desc"
  fi
}

at() {
  local dir=$1
  shift
  (cd "$dir" && "$@")
}

fails 'a repository matching no account is an error' \
  at "$unmapped" env "$gh_as" --print
fails 'a remote on an unknown host is an error' \
  at "$other" env GH_STUB_ACCOUNTS= "$gh_as" --print
fails 'an unknown account is an error' \
  env "$gh_as" nobody -- true
fails 'no command is an error' "$gh_as" alice --
fails 'wrapping gh auth is an error' "$gh_as" alice -- gh auth status
fails 'an unknown option is an error' "$gh_as" --nope

check 'help exits successfully' 'ok' "$("$gh_as" --help >/dev/null && echo ok)"
check '--list enumerates the accounts' \
  'alice alice-work' \
  "$("$gh_as" --list | tr '\n' ' ' | perl -pe 's/ $//')"

# --- git credential helper ---------------------------------------------------

# Feeds the credential protocol to the helper and returns username|password.
cred() {
  local op=$1
  shift
  printf '%s\n' "$@" '' | "$gh_as" --git-credential "$op" 2>/dev/null |
    perl -ne 'print "$1|" if /^username=(.*)/; print "$1" if /^password=(.*)/'
}

git config --global 'gh-as.https://github.com/acme.account' alice-work
check 'helper resolves a mapped organization from the path' \
  'alice-work|token-alice-work-github.com' \
  "$(cred get protocol=https host=github.com path=acme/service.git)"

check 'helper falls back to the owner when the path is unmapped' \
  'alice|token-alice-github.com' \
  "$(cred get protocol=https host=github.com path=alice/blog.git)"

check 'helper ignores capability lines and a leading slash on the path' \
  'alice-work|token-alice-work-github.com' \
  "$(cred get 'capability[]=authtype' protocol=https host=github.com path=/acme/service.git)"

check 'helper accepts the url= form' \
  'alice-work|token-alice-work-github.com' \
  "$(cred get url=https://github.com/acme/service.git)"

check 'helper honours a username git already resolved' \
  'alice-work|token-alice-work-github.com' \
  "$(cred get protocol=https host=github.com path=alice/blog.git username=alice-work)"

git config --global 'gh-as.https://github.com.account' alice
check 'helper uses the host-wide default when git sends no path' \
  'alice|token-alice-github.com' \
  "$(cred get protocol=https host=github.com)"
git config --global --unset 'gh-as.https://github.com.account'

check 'helper strips an ambient token before asking gh' \
  'alice-work|token-alice-work-github.com' \
  "$(GH_TOKEN=ambient cred get protocol=https host=github.com path=acme/service.git)"

check 'helper answers a non-https request with nothing' \
  '' \
  "$(cred get protocol=ssh host=github.com path=acme/service.git)"

check 'helper accepts store silently' 'ok' \
  "$(printf 'protocol=https\nhost=github.com\n\n' | "$gh_as" --git-credential store && echo ok)"
check 'helper accepts erase silently' 'ok' \
  "$(printf 'protocol=https\nhost=github.com\n\n' | "$gh_as" --git-credential erase && echo ok)"

fails 'helper rejects an unknown operation' \
  env "$gh_as" --git-credential frobnicate </dev/null
fails 'helper prints nothing on stdout when no account matches' \
  sh -c "printf 'protocol=https\nhost=github.com\npath=nobody/thing.git\n\n' | '$gh_as' --git-credential get | grep -q ."

# --- --setup-git --------------------------------------------------------------

setup_config=$tmp/setup-gitconfig
: >"$setup_config"
check '--setup-git succeeds' 'ok' \
  "$(GIT_CONFIG_GLOBAL=$setup_config "$gh_as" --setup-git >/dev/null 2>&1 && echo ok)"
first=$(cat "$setup_config")
check '--setup-git is idempotent' 'ok' \
  "$(GIT_CONFIG_GLOBAL=$setup_config "$gh_as" --setup-git >/dev/null 2>&1 && [ "$first" = "$(cat "$setup_config")" ] && echo ok)"

check '--setup-git resets the helper list before adding gh-as' \
  "2" \
  "$(GIT_CONFIG_GLOBAL=$setup_config git config --global --get-all credential.https://github.com.helper | wc -l | tr -d ' ')"

check '--setup-git turns on useHttpPath' \
  'true' \
  "$(GIT_CONFIG_GLOBAL=$setup_config git config --global credential.https://github.com.useHttpPath)"

check '--setup-git --host targets that host only' \
  'true' \
  "$(GIT_CONFIG_GLOBAL=$setup_config "$gh_as" --setup-git --host ghe.example.com >/dev/null 2>&1 && GIT_CONFIG_GLOBAL=$setup_config git config --global credential.https://ghe.example.com.useHttpPath)"

fails '--setup-git refuses extra arguments' "$gh_as" --setup-git alice -- true

# End to end through git itself: the config --setup-git wrote must make
# `git credential fill` reach the helper and pick the account by organization.
GIT_CONFIG_GLOBAL=$setup_config git config --global 'gh-as.https://github.com/acme.account' alice-work
fill() {
  printf 'url=%s\n\n' "$1" | GIT_CONFIG_GLOBAL=$setup_config GIT_TERMINAL_PROMPT=0 git credential fill 2>/dev/null |
    perl -ne 'print "$1" if /^username=(.*)/'
}
check 'git credential fill picks the mapped organization account' \
  'alice-work' "$(fill https://github.com/acme/service.git)"
# acme-labs shares a prefix with the mapped acme; with two accounts logged in
# and no rule for it, the only correct answer is no answer.
check 'git credential fill does not match a lookalike organization prefix' \
  '' "$(fill https://github.com/acme-labs/thing.git)"
check 'git credential fill honours a user in the remote URL' \
  'alice-work' "$(fill https://alice-work@github.com/alice/blog.git)"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
