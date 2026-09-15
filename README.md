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
writes the checkout's path into the global git config, so edits take effect
on the next `gh as` or `git fetch`.

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

`gh auth setup-git` makes `gh` git's credential helper. That helper answers
with the active account's token (or with `GH_TOKEN` when one is set), and
when git asks for a different username it declines, so git prompts. A
per-URL `credential.username` therefore cannot select the other account on
its own. `gh-as --setup-git` replaces gh's helper:

```console
$ gh as --setup-git
gh-as: git will now resolve credentials for github.com through /usr/local/bin/gh-as
```

It writes three lines to the global git config for the host: a blank helper
that clears anything inherited from the system config, `gh-as
--git-credential` as the helper, and `useHttpPath = true` so git passes the
repository path. From then on every HTTPS fetch and push to that host
resolves through the list above and takes the token from gh's storage.
`gh-as` ignores git's `store` and `erase`, so it never writes a credential
anywhere. SSH remotes are untouched.

A username git has already resolved, from `credential.username` or a
`https://alice-work@github.com/...` remote, is honoured as given.

`gh auth setup-git` resets the host's helper list before adding gh's own
helper, so running it again later removes `gh-as`; rerun `gh as --setup-git`
afterwards. The same applies to any tool that rewrites that list.

## GitHub Enterprise

The host comes from the remote URL in resolution mode, from `--host` or
`GH_HOST` otherwise. The token is passed as `GH_TOKEN` for `github.com` and
Enterprise Cloud hosts under `*.ghe.com`, and as `GH_ENTERPRISE_TOKEN` for
GitHub Enterprise Server. The resolved host is always passed as `GH_HOST`,
including when `--host github.com` overrides an inherited enterprise host.

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

Wrapping `git` in `gh-as` is not the way to pick git's account: the
credential helper decides that, and `gh-as --git-credential` deliberately
ignores any `GH_TOKEN` it inherits. Use `--setup-git` for git and `gh-as` for
everything else.

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
./test/host-isolation.sh       # real gh with temporary dummy credentials; no network
shellcheck gh-as test/*.sh
shfmt -d gh-as test/*.sh    # style comes from .editorconfig
```

When the clone is also the installed helper, the clone's working tree is the
machine's git authentication: a syntax error mid-edit, or a checkout of a
branch that lacks `--git-credential`, makes every HTTPS fetch fall back to a
username prompt. To detach git from it while you work:

```console
git config --global --unset-all credential.https://github.com.helper
gh auth setup-git
```

and `gh as --setup-git` again when the script is whole.

## License

MIT
