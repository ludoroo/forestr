# Forestr

Forestr is a private Linux and macOS plugin for [Herdr](https://herdr.dev/) that manages Git branch worktrees in one fast, modal `fzf` popup. It discovers repositories represented by Herdr workspaces, lists existing worktrees and available branches, opens or creates a checkout, focuses the matching workspace, and safely removes selected worktrees.

- Plugin ID: `ludoroo.forestr`
- Action: `ludoroo.forestr.open`
- Version: `0.1.1`

## Screenshot

> **Screenshot placeholder:** add a capture of the Forestr manager popup here.

## Requirements

Forestr supports **Linux and macOS** and requires:

- Bash 4 or newer (associative arrays). macOS's system Bash is too old; install a current Bash with `brew install bash`.
- Herdr 0.9 or newer
- Git
- `jq`
- `fzf` 0.74 or newer, including `--track`, `--id-nth`, `--listen-unsafe`, transform actions, input/footer borders, and component color options
- `curl` built with Unix-socket support (`--unix-socket`)

Optional backend tooling:

- [Worktrunk](https://worktrunk.dev/) (`wt`) enables the Worktrunk backend, including clobber-create, relocation-aware operations, and richer status symbols.

Forestr searches common executable locations, including Apple Silicon and Intel Homebrew prefixes. Explicit `BASH_BIN`, `HERDR_BIN`, `FZF_BIN`, `GIT_BIN`, `JQ_BIN`, `CURL_BIN`, and `WORKTRUNK_BIN` overrides are also supported. Because fzf accepts its shell as a whitespace-split command, the Bash executable path must not contain whitespace or shell metacharacters.

On macOS, install the non-system runtime dependencies with:

```bash
brew install bash jq fzf
```

## Install

```bash
herdr plugin install ludoroo/forestr
```

This repository is private. Herdr installs GitHub plugins over Git, so configure HTTPS authentication first if the repository is not already accessible:

```bash
gh auth login --hostname github.com --git-protocol https
gh auth setup-git
herdr plugin install ludoroo/forestr
```

`gh auth setup-git` installs the Git credential helper used for private HTTPS clones. It does not make the repository public.

To develop from a local clone, run this from the repository root:

```bash
herdr plugin link "$(pwd)" --enabled
```

Open Forestr from Herdr's action picker with `ludoroo.forestr.open`.

## Controls and create wizard

The popup begins in the worktree manager. Default keys are:

| Key | Action |
| --- | --- |
| `j` / `k`, `g` / `G` | Move down/up, first/last |
| `Enter` | Open or choose the selected item |
| `c` | Start the create wizard |
| `d` / `D` | Remove / force-remove the selected worktree |
| `/`, `Ctrl-R`, `q` | Search, refresh, quit |
| `h` / `Esc` | Go back or close |

The create wizard is repository-first: choose a repository, then choose an existing source or type a new branch. On the source screen, `l`, `r`, and `b` show local, remote, or both branch scopes; `n` starts exact branch-name input. `C` requests clobber-create when the selected backend supports it. The default source scope is local. All keys and the default scope can be changed in `config.toml`; the complete defaults are in [`config.example.toml`](config.example.toml).

## Backend behavior

`backend = "auto"` is the default. It selects Worktrunk when an executable `wt` is available and otherwise uses native Git. Set `backend = "git"` or `backend = "worktrunk"` to make selection explicit.

- **Git:** uses Git porcelain directly. It opens existing worktrees, materializes exact local or remote branches, creates new branches, and removes selected secondary worktrees. New checkout paths are siblings of the primary checkout, named `.<repository>-<sanitized-branch>`.
- **Worktrunk:** delegates switch/create/remove semantics to `wt`. Enrichment adds Worktrunk head and status symbols in the background and passes its collection budget to Worktrunk's built-in `list.timeout-ms` setting. It can be disabled with `enrich_backend = false`.

The budget covers Worktrunk's collection phase. If broader `wt list` setup stalls, the existing Git rows remain usable; refreshing or closing the popup terminates the background producer.

The initial active-repository row is rendered before global Herdr discovery finishes. Refresh work is generation-scoped, and stale background output cannot replace a newer snapshot. Operation results use a fixed two-row footer status area, so their fzf transforms do not synchronously rebuild the candidate list. Successful removals hide the selected row immediately; background discovery may later reload candidates to reconcile partial mutations and authoritative state.

## Git safety

Forestr intentionally validates selected repositories, refs, and canonical checkout paths again immediately before mutation. The native Git backend:

- never removes the primary worktree, runs `git worktree prune`, deletes arbitrary directories, or rewrites unrelated refs;
- refuses path collisions, ambiguous/missing refs, cross-repository paths, and changed selections;
- does not infer tracking for newly typed branches; remote selections create an exact tracking branch;
- uses normal deletion for `d`, retaining unmerged or newly checked-out branches with a warning;
- uses force worktree/branch deletion only for explicit `D`;
- does not support branch clobber in Git mode and leaves a newly created checkout in place if post-create verification fails, so it can be inspected rather than destructively rolled back.

Worktrunk operations preserve Worktrunk's own hooks and safety checks; Forestr does not pass hook-disabling flags.

## Configuration

Find the private configuration directory with:

```bash
herdr plugin config-dir ludoroo.forestr
```

Copy [`config.example.toml`](config.example.toml) to `config.toml` in that directory and edit only the values you want to change. Forestr parses configuration as data and never sources or evaluates it as shell code.

## Development

Runtime plugin code lives in [`src/`](src/), while behavior tests live in [`tests/`](tests/). The Herdr manifest and user-facing example configuration remain at the repository root.

On Linux or macOS, run all behavior tests, Bash syntax checks, TOML parsing, stale-name checks, and Git whitespace checks with:

```bash
./test.sh
```

## License

Forestr is available under the [MIT License](LICENSE).
