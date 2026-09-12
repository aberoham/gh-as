# gh-as

Run a command as one of the GitHub accounts `gh` is logged in with, without
switching the account the rest of the machine sees. Once installed as git's
credential helper, `git fetch` and `git push` pick the account the same way.

```console
$ cd ~/src/acme/service
$ gh pr list
GraphQL: Could not resolve to a Repository with the name 'acme/service'. (repository)

$ gh as -- gh pr list
gh-as: running as alice-work
Showing 3 of 3 open pull requests in acme/service
```

This is a fork of [lambdalisue/gh-as](https://github.com/lambdalisue/gh-as)
that adds the git credential helper and `--setup-git`.

## The problem

`gh` keeps one active account per host in `~/.config/gh/hosts.yml`. With a
personal and a work account both logged in, every command aimed at a
repository the active account cannot see fails as if the repository did not
exist — the error names the repository, never the authentication.

The documented cure is `gh auth switch`, and it is a bad fit for the situation
that causes the error. `hosts.yml` is global: the switch reaches every shell,
editor, agent and background job on the machine. Two terminals working on
different accounts race over it, and a command that dies between the switch and
the switch back leaves the machine pointing somewhere its owner did not choose.

`gh-as` resolves the account, injects its token into the environment of one
command, and touches nothing else. Concurrent runs cannot interfere, and there
is no state to restore when a command fails.

## Install

As a `gh` extension:

```console
gh extension install aberoham/gh-as
```

Or drop the single script anywhere on `PATH`:

```console
curl -fsSLo ~/.local/bin/gh-as https://raw.githubusercontent.com/aberoham/gh-as/main/gh-as
chmod +x ~/.local/bin/gh-as
```

Both forms take the same arguments; the extension is spelled `gh as`, the
script `gh-as`.

Then, once, let git resolve credentials the same way:

```console
gh as --setup-git
```

To work on the script itself, install the clone rather than the release:
`gh extension install .` inside the checkout symlinks it, and `--setup-git`
writes the checkout's path into `~/.gitconfig`, so edits take effect on the
next `gh as` or `git fetch`.

## Usage

```console
gh-as <command> [args...]                # account resolved from the repository
gh-as <account> -- <command> [args...]   # account named explicitly
gh-as --print [<account>]                # print the account, run nothing
gh-as --list                             # accounts logged in on the host
```

The command is not limited to `gh` — anything that reads `GH_TOKEN` works:
`gh` extensions, a `curl` call against the API, your own release scripts.

```console
gh-as gh pr create
gh-as alice-work -- gh api user --jq .login
gh-as alice -- ./scripts/publish-release.ts
```

`GH_AS_ACCOUNT` carries the chosen account into the command, which makes it
easy to show in a prompt or assert in a script.

## Account resolution

Without an explicit account, the first of these that answers wins:

1. `git config --get-urlmatch gh-as.account <remote url>`
2. `git config --get-urlmatch credential.username <remote url>`
3. the repository owner, when it is itself a logged-in account
4. the only account logged in on the host

Steps 3 and 4 cover the common cases with no configuration at all: personal
repositories under your own name, and machines with a single login.

For anything else, declare the account per URL. git resolves the most specific
section, so an organization overrides the host-wide default:

```ini
[gh-as "https://github.com"]
  account = alice

[gh-as "https://github.com/acme"]
  account = alice-work
```

If you already pin credentials per URL, step 2 reads the account straight out
of that mapping and no `gh-as` section is needed.

### Enterprise managed users

The common shape is a personal account plus an enterprise managed user, both
on `github.com`. A managed user can only belong to organizations inside its
own enterprise, so its own membership list is exactly the set of
organizations it should be used for:

```console
gh as alice-work -- gh api user/orgs --paginate --jq '.[].login'
```

Declare the personal account as the host-wide default and one line per
managed organization. Rerun the listing when the enterprise gains one.

```ini
[gh-as "https://github.com"]
  account = alice

[gh-as "https://github.com/acme"]
  account = alice-work
```

## Plain git

`gh auth setup-git` makes `gh` git's credential helper, and that helper only
ever hands out the active account's token. Asked for any other username it
returns nothing, so a per-URL `credential.username` on its own still pushes
as whoever happens to be active. `gh-as --setup-git` replaces it:

```console
$ gh as --setup-git
gh-as: git will now resolve credentials for github.com through /usr/local/bin/gh-as
```

It writes three lines to `~/.gitconfig` for the host: a blank helper that
clears anything inherited from the system config, `gh-as --git-credential` as
the helper, and `useHttpPath = true` so git passes the repository path. From
then on every fetch and push resolves through the list above and takes the
token from gh's keyring. Nothing is stored in git's own credential store.

A username git has already resolved, from `credential.username` or a
`https://alice-work@github.com/...` remote, is honoured as given. Running
`gh auth setup-git` again later re-adds gh's helper after `gh-as`, which is
harmless because helpers are tried in order.

## GitHub Enterprise

The host comes from the remote URL in resolution mode, from `--host` or
`GH_HOST` otherwise. Off `github.com` the token is passed as
`GH_ENTERPRISE_TOKEN` and `GH_HOST` is set for the command, matching how `gh`
itself reads enterprise credentials.

## Reference

| Option | |
| --- | --- |
| `-l`, `--list` | List the accounts logged in on the host |
| `-p`, `--print` | Print the account that would be used, then exit |
| `-q`, `--quiet` | Do not announce the account on stderr |
| `--host HOST` | Host to take the account from |
| `--setup-git` | Install gh-as as git's credential helper for the host |
| `--git-credential OP` | The git credential helper entry point; git calls it, you do not |
| `-h`, `--help` | Show help |

| Environment | |
| --- | --- |
| `GH_AS_REMOTE` | Remote to resolve the account from (default: `origin`) |
| `GH_AS_QUIET` | Non-empty implies `--quiet` |
| `GH_HOST` | Default host, as elsewhere in `gh` |

`gh auth login`, `switch` and `logout` refuse to run while a token is injected,
so `gh-as` rejects them with that explanation instead of letting `gh` fail
obscurely. Run those directly.

Wrapping `git` in `gh-as` changes nothing; git never reads `GH_TOKEN`. Use
`--setup-git` for git and `gh-as` for everything else.

## Claude Code

The repository doubles as a Claude Code plugin marketplace. The plugin carries
one skill that teaches Claude to recognize the wrong-account failure and rerun
the command through `gh-as`, instead of reaching for `gh auth switch` and
changing the account every other session on the machine shares.

```
/plugin marketplace add aberoham/gh-as
/plugin install gh-as@gh-as
```

The skill resolves `gh-as` from `PATH` or from `gh extension list`, so install
one of them as above.

## Development

```console
./test/test.sh                 # runs against a stub gh; no account, no network
shellcheck gh-as test/test.sh
shfmt -d gh-as test/test.sh    # style comes from .editorconfig
```

## License

MIT
