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
# the environment happened to carry. API calls are the exception: those are
# made with the chosen account's token on purpose.
case $subcommand in
  auth*)
    if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}${GH_ENTERPRISE_TOKEN:-}${GITHUB_ENTERPRISE_TOKEN:-}" ]; then
      echo "AMBIENT-TOKEN-LEAKED"
      exit 0
    fi
    ;;
esac

case $subcommand in
  "api user/orgs"*)
    if [ "${GH_TOKEN:-}" != "token-${GH_STUB_ORGS_OF:-}-github.com" ]; then
      echo "stub gh: api called with the wrong token: ${GH_TOKEN:-none}" >&2
      exit 2
    fi
    for org in ${GH_STUB_ORGS:-}; do echo "$org"; done
    ;;
  "api orgs/"*)
    org=${subcommand#api orgs/}
    org=${org%%/*}
    case " ${GH_STUB_API_FAILS:-} " in
      *" $org "*)
        echo "HTTP 403: Resource protected by organization SAML enforcement" >&2
        exit 1
        ;;
    esac
    case " ${GH_STUB_PUBLIC_ONLY:-} " in
      *" $org "*) ;;
      *) echo secret ;;
    esac
    ;;
  "auth status")
    if [ -z "${GH_STUB_ACCOUNTS:-}" ]; then
      echo "You are not logged into any GitHub hosts." >&2
      exit 1
    fi
    echo "$host"
    for account in ${GH_STUB_ACCOUNTS}; do
      echo "  ✓ Logged in to $host account $account (keyring)"
    done
    for account in ${GH_STUB_INVALID_ACCOUNTS:-}; do
      echo "  X Failed to log in to $host account $account (keyring)" >&2
    done
    exit "${GH_STUB_STATUS_EXIT:-0}"
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

# Stands in for GitHub's SSH endpoint. With no remote command it greets the
# key's owner as `ssh -T` does; for git-upload-pack it serves an empty
# repository when the organization is in GH_STUB_SSH_OK, and refuses otherwise.
cat >"$tmp/bin/ssh" <<'STUB'
#!/usr/bin/env bash
last=${*: -1}
case $last in
  git-upload-pack*)
    org=${last#*\'}
    org=${org#/}
    org=${org%%/*}
    case " ${GH_STUB_SSH_REFUSED:-} " in
      *" $org "*)
        # A server notice that happens to mention single sign-on must not
        # turn an agent failure into an authorization verdict.
        [ -z "${GH_STUB_SSH_BANNER:-}" ] ||
          echo "ERROR: The '$org' organization has enabled or enforced SAML SSO." >&2
        echo 'sign_and_send_pubkey: signing failed for ED25519 "key" from agent: agent refused operation' >&2
        echo 'git@github.com: Permission denied (publickey).' >&2
        exit 255
        ;;
    esac
    case " ${GH_STUB_SSH_OK:-} " in
      *" $org "*)
        # git answers the advertisement with a flush packet; reading it before
        # exiting keeps git's write from hitting a closed pipe on Windows.
        printf '0000'
        cat >/dev/null
        ;;
      *)
        echo "ERROR: The '$org' organization has enabled or enforced SAML SSO." >&2
        exit 128
        ;;
    esac
    ;;
  *)
    if [ -n "${GH_STUB_SSH_LOGIN:-}" ]; then
      echo "Hi $GH_STUB_SSH_LOGIN! You've successfully authenticated, but GitHub does not provide shell access." >&2
    else
      echo "git@github.com: Permission denied (publickey)." >&2
    fi
    exit 1
    ;;
esac
STUB
chmod +x "$tmp/bin/ssh"

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
  'alice-work|token-alice-work-github.com||github.com' \
  "$(cd "$personal" && run alice-work -- sh -c "$show_env")"

git -C "$work" config 'gh-as.https://github.com/acme.account' alice-work
check 'gh-as.account resolves the account' \
  'alice-work|token-alice-work-github.com||github.com' \
  "$(cd "$work" && run sh -c "$show_env")"

git -C "$scp_style" config 'credential.https://github.com/acme.username' alice-work
check 'scp-style remote resolves through credential.username' \
  'alice-work|token-alice-work-github.com||github.com' \
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

# A delimiter after the command's first argument belongs to the command.
check 'command arguments preserve a later separator and an empty argument' \
  '<--><><two words>' \
  "$(cd "$personal" && run sh -c 'printf "<%s>" "$@"' _ -- '' 'two words')"

# `<account> --` stays reserved; a leading -- disambiguates command names.
check 'a leading separator permits a command immediately followed by --' \
  'hello' "$(cd "$personal" && run -- printf -- hello)"

check 'an explicit account preserves separators in command arguments' \
  '<--><><two words>' \
  "$(cd "$personal" && run alice-work -- sh -c 'printf "<%s>" "$@"' _ -- '' 'two words')"

check 'account discovery survives a failed authentication check' \
  'solo|token-solo-github.com||github.com' \
  "$(cd "$unmapped" && GH_STUB_ACCOUNTS=solo GH_STUB_STATUS_EXIT=1 run sh -c "$show_env")"

check 'an exact .git URL mapping overrides the organization mapping' \
  'alice' \
  "$(cd "$work" && git config 'gh-as.https://github.com/acme/service.git.account' alice && run --print)"
git -C "$work" config --unset 'gh-as.https://github.com/acme/service.git.account'

check 'an exact .git credential mapping works for an scp-style remote' \
  'alice' \
  "$(cd "$scp_style" && git config 'credential.https://github.com/acme/service.git.username' alice && run --print)"
git -C "$scp_style" config --unset 'credential.https://github.com/acme/service.git.username'

suffixless=$(repo suffixless https://github.com/nobody/thing)
git -C "$suffixless" config 'gh-as.https://github.com/nobody/thing.account' alice-work
check 'an exact mapping still works for a remote without .git' \
  'alice-work' "$(cd "$suffixless" && run --print)"

check 'inherited tokens are cleared before asking gh' \
  'alice-work|token-alice-work-github.com||github.com' \
  "$(cd "$personal" && GH_TOKEN=ambient run alice-work -- sh -c "$show_env")"

check 'an enterprise host gets GH_ENTERPRISE_TOKEN and GH_HOST' \
  'alice||token-alice-ghe.example.com|ghe.example.com' \
  "$(cd "$personal" && run --host ghe.example.com alice -- sh -c "$show_env")"

check 'Enterprise Cloud gets GH_TOKEN and GH_HOST' \
  'alice|token-alice-example.ghe.com||example.ghe.com' \
  "$(cd "$personal" && run --host example.ghe.com alice -- sh -c "$show_env")"

check 'an explicit public host replaces an inherited enterprise host' \
  'alice|token-alice-github.com||github.com' \
  "$(cd "$personal" && GH_HOST=ghe.example.com run --host github.com alice -- sh -c "$show_env")"

check 'a lookalike cloud suffix remains Enterprise Server' \
  'alice||token-alice-example.ghe.com.evil.test|example.ghe.com.evil.test' \
  "$(cd "$personal" && run --host example.ghe.com.evil.test alice -- sh -c "$show_env")"

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

check '--list returns all stored names despite authentication errors' \
  'alice
alice-work
|ok' \
  "$(GH_STUB_ACCOUNTS=alice GH_STUB_INVALID_ACCOUNTS=alice-work GH_STUB_STATUS_EXIT=1 run --list && printf '|ok')"

check 'a failed account check still prevents guessing between accounts' \
  'gh-as: cannot tell which account this repository belongs to; name one of: alice alice-work' \
  "$(cd "$unmapped" && GH_STUB_ACCOUNTS=alice GH_STUB_INVALID_ACCOUNTS=alice-work GH_STUB_STATUS_EXIT=1 "$gh_as" --print 2>&1)"

fails 'empty account discovery remains an error' \
  at "$unmapped" env GH_STUB_ACCOUNTS= "$gh_as" --print

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

# A copy of the script at an awkward path must still produce a helper line
# that sh -c can parse, under whichever bash runs the suite.
odd_dir="$tmp/it's a dir"
mkdir -p "$odd_dir"
cp "$gh_as" "$odd_dir/gh-as"

# Runs --setup-git from the odd path under the given bash, then parses the
# helper line the way git will, as sh words, and prints word one and two.
odd_helper_words() {
  local shell=$1 config=$tmp/odd-gitconfig-${1##*/} helper
  : >"$config"
  GIT_CONFIG_GLOBAL=$config "$shell" "$odd_dir/gh-as" --setup-git >/dev/null 2>&1
  helper=$(GIT_CONFIG_GLOBAL=$config git config --global --get-all credential.https://github.com.helper | tail -1)
  sh -c 'eval "set -- $1"; printf "%s|%s" "$1" "$2"' _ "${helper#!}"
}
check '--setup-git quotes a path with a space and a single quote' \
  "$odd_dir/gh-as|--git-credential" "$(odd_helper_words bash)"
if [ -x /bin/bash ]; then
  check '--setup-git quoting also holds under /bin/bash (3.2 on macOS)' \
    "$odd_dir/gh-as|--git-credential" "$(odd_helper_words /bin/bash)"
fi

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

GIT_CONFIG_GLOBAL=$setup_config git config --global 'gh-as.https://github.com/acme/service.git.account' alice
check 'git credential fill applies an exact .git mapping over an organization default' \
  'alice' "$(fill https://github.com/acme/service.git)"
check 'an exact .git mapping does not affect a sibling repository' \
  'alice-work' "$(fill https://github.com/acme/other.git)"
check 'an exact .git mapping does not match a remote without that suffix' \
  'alice-work' "$(fill https://github.com/acme/service)"

# --- --setup-ssh --------------------------------------------------------------

ssh_config=$tmp/ssh-gitconfig
# acme accepts the key, beta refuses it, pub has nothing but public repositories.
setup_ssh() {
  GIT_CONFIG_GLOBAL=$ssh_config GH_STUB_ORGS_OF=alice GH_STUB_ORGS='acme beta pub' \
    GH_STUB_PUBLIC_ONLY=pub GH_STUB_SSH_OK=acme GH_STUB_SSH_LOGIN=${GH_STUB_SSH_LOGIN-alice} \
    "$gh_as" --setup-ssh "$@" 2>"$tmp/ssh-stderr"
}
control_dirs() {
  # The trailing slash follows /tmp where it is a symlink, as on macOS.
  find /tmp/ -maxdepth 1 -name 'gh-as.*' 2>/dev/null | wc -l | tr -d ' '
}
dirs_before=$(control_dirs)
rules() {
  GIT_CONFIG_GLOBAL=$ssh_config git config --global --get-regexp '^url\.' | tr '\n' ';'
}

: >"$ssh_config"
before=$failed
check '--setup-ssh reports each organization' \
  'ssh     acme;https   beta (key not authorized for single sign-on);skipped pub (no non-public repository to test against);' \
  "$(setup_ssh alice | tr '\n' ';')"
# Every later check depends on this run, so show why it went wrong.
[ "$failed" -eq "$before" ] || sed 's/^/     stderr: /' "$tmp/ssh-stderr"
check '--setup-ssh rewrites only the organization the key reaches' \
  'url.git@github.com:acme/.insteadof https://github.com/acme/;' "$(rules)"

first=$(cat "$ssh_config")
setup_ssh alice >/dev/null
check '--setup-ssh is idempotent' "$first" "$(cat "$ssh_config")"

GIT_CONFIG_GLOBAL=$ssh_config git config --global 'url.git@github.com:beta/.insteadOf' https://github.com/beta/
setup_ssh alice >/dev/null
check '--setup-ssh removes a rule the key can no longer use' \
  'url.git@github.com:acme/.insteadof https://github.com/acme/;' "$(rules)"

# A refused signature says nothing about authorization, so the run must stop
# and leave the rule it was about to judge exactly where it was.
agent_refuses_acme() { GH_STUB_SSH_REFUSED=acme setup_ssh alice; }
fails '--setup-ssh stops when the SSH agent refuses to sign' agent_refuses_acme
check '--setup-ssh keeps the rule of an organization it could not judge' \
  'url.git@github.com:acme/.insteadof https://github.com/acme/;' "$(rules)"
check '--setup-ssh says why it stopped' 'ok' \
  "$(grep -q 'failed for a reason other than single sign-on' "$tmp/ssh-stderr" && echo ok)"
check '--setup-ssh removes its control directory after stopping' "$dirs_before" "$(control_dirs)"

agent_refuses_with_banner() { GH_STUB_SSH_BANNER=1 GH_STUB_SSH_REFUSED=acme setup_ssh alice; }
fails '--setup-ssh stops on an agent failure that mentions single sign-on' agent_refuses_with_banner
check '--setup-ssh keeps the rule when single sign-on is mentioned beside a key failure' \
  'url.git@github.com:acme/.insteadof https://github.com/acme/;' "$(rules)"

# A repository listing that fails must not look like an organization with
# nothing to test: its rule stays, the line says why, and the run fails.
GIT_CONFIG_GLOBAL=$ssh_config git config --global 'url.git@github.com:beta/.insteadOf' https://github.com/beta/
api_fails_for_beta() { GH_STUB_API_FAILS=beta setup_ssh alice; }
fails '--setup-ssh fails when a repository listing fails' api_fails_for_beta
check '--setup-ssh reports the failed listing' \
  'error   beta (could not list repositories: HTTP 403: Resource protected by organization SAML enforcement)' \
  "$(api_fails_for_beta | grep '^error')"
check '--setup-ssh keeps the rule of an organization it could not list' \
  'url.git@github.com:acme/.insteadof https://github.com/acme/;url.git@github.com:beta/.insteadof https://github.com/beta/;' \
  "$(rules)"
GIT_CONFIG_GLOBAL=$ssh_config git config --global --unset-all 'url.git@github.com:beta/.insteadOf'

setup_ssh alice >/dev/null
check '--setup-ssh removes its control directory after succeeding' "$dirs_before" "$(control_dirs)"

check 'git follows the rewrite over SSH' 'ok' \
  "$(GIT_CONFIG_GLOBAL=$ssh_config GH_STUB_SSH_OK=acme GIT_TERMINAL_PROMPT=0 \
    git ls-remote https://github.com/acme/secret.git >/dev/null 2>&1 && echo ok)"

: >"$ssh_config"
key_of_bob() { GH_STUB_SSH_LOGIN=bob setup_ssh alice; }
no_key() { GH_STUB_SSH_LOGIN='' setup_ssh alice; }
fails '--setup-ssh refuses a key that belongs to another account' key_of_bob
check '--setup-ssh writes nothing when the key is another account'"'"'s' '' "$(rules)"
fails '--setup-ssh refuses when no key is accepted' no_key
fails '--setup-ssh needs an account when several are logged in' setup_ssh
check '--setup-ssh uses the only logged-in account' 'ssh     acme' \
  "$(GH_STUB_ACCOUNTS=alice setup_ssh | sed -n 1p)"
fails '--setup-ssh refuses a second account' "$gh_as" --setup-ssh alice bob
fails '--setup-ssh refuses a second account after a separator' "$gh_as" --setup-ssh bob -- alice
fails '--setup-ssh refuses --print' "$gh_as" --setup-ssh --print alice
fails '--setup-ssh and --setup-git cannot be combined' "$gh_as" --setup-ssh --setup-git
check '--setup-ssh accepts an account before a bare separator' 'ssh     acme' \
  "$(setup_ssh alice -- | sed -n 1p)"

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
