# Forestr

Forestr is a Linux and macOS plugin for [Herdr](https://herdr.dev/) that manages Git branch worktrees in one fast, modal `fzf` popup. It discovers repositories represented by Herdr workspaces, lists existing worktrees and available branches, opens or creates a checkout, focuses the matching workspace, and safely removes selected worktrees.

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
- A session-detach launcher for removal workers: `setsid` on Linux, or Perl with `POSIX::setsid` (provided by macOS's system Perl)

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
| `p` | Toggle the selected worktree's commit log preview |
| `/`, `Ctrl-R`, `q` | Search, refresh, quit |
| `h` / `Esc` | Go back or close |

The create wizard is repository-first: choose a repository, then choose an existing source or type a new branch. On the source screen, `l`, `r`, and `b` show local, remote, or both branch scopes; `n` starts exact branch-name input. `C` requests clobber-create when the selected backend supports it. The default source scope is local. All keys and the default scope can be changed in `config.toml`; the complete defaults are in [`config.example.toml`](config.example.toml).

## Backend behavior

`backend = "auto"` is the default. It selects Worktrunk when an executable `wt` is available and otherwise uses native Git. Set `backend = "git"` or `backend = "worktrunk"` to make selection explicit.

- **Git:** uses Git porcelain directly. It opens existing worktrees, materializes exact local or remote branches, creates new branches, and removes selected secondary worktrees. New checkout paths are siblings of the primary checkout, named `.<repository>-<sanitized-branch>`.
- **Worktrunk:** delegates switch/create/remove semantics to `wt`. Enrichment adds Worktrunk head and status data in the background and passes its collection budget to Worktrunk's built-in `list.timeout-ms` setting. Status symbols retain Worktrunk's seven aligned positions—three working-tree flags, worktree condition, default branch, remote, and marker—and each semantic icon can be overridden with the `status_icon_*` settings in [`config.example.toml`](config.example.toml). The final marker remains branch data managed by `wt config state marker`. Enrichment can be disabled with `enrich_backend = false`.

The budget covers Worktrunk's collection phase. If broader `wt list` setup stalls, the existing Git rows remain usable; refreshing or closing the popup terminates the background producer.

The initial active-repository row is rendered before global Herdr discovery finishes. Refresh work is generation-scoped, and stale background output cannot replace a newer snapshot. Operation results use a fixed two-row footer status area, so their fzf transforms do not synchronously rebuild the candidate list.

Removals are durable asynchronous jobs. Pressing `d` or `D` approves and queues the operation, immediately reports that safety checks, hooks, and file deletion are running, and leaves the row visible until an authoritative refresh. Closing the popup, pressing `q`/`Esc`, or closing the source workspace does **not** cancel an approved removal. There is deliberately no post-approval cancel key because neither backend exposes a reliable irreversible boundary. Final results are sent as Herdr notifications and shown when Forestr is next opened.

Removal records and logs are retained under `${XDG_STATE_HOME:-$HOME/.local/state}/forestr/removals`. Set `FORESTR_REMOVAL_STATE_DIR` to override this location (especially in tests). On startup, Forestr reconciles interrupted queued/running jobs against `git worktree list`: registered worktrees, surviving checkout paths, and unknown topology are retained. Only a missing registration plus a missing original path can close an exactly revalidated stale Herdr workspace.

The manager shows a bounded commit-log preview for the selected worktree. It follows only that worktree's `HEAD` ancestry—never `--all`—uses one fixed-width line per commit, and is capped at 25 commits to remain readable in busy repositories. Change statistics are compacted (for example, `4k`) and the author column is omitted when space is tight. Press `p` to toggle the preview. It moves below the list when the side panel would be too narrow and stays hidden in the create wizard.

## Git safety

Forestr intentionally validates selected repositories, refs, and canonical checkout paths again immediately before mutation. The native Git backend:

- never removes the primary worktree, runs `git worktree prune`, deletes arbitrary directories, or rewrites unrelated refs;
- refuses path collisions, ambiguous/missing refs, cross-repository paths, and changed selections;
- does not infer tracking for newly typed branches; remote selections create an exact tracking branch;
- uses normal deletion for `d`, retaining unmerged or newly checked-out branches with a warning;
- uses force worktree/branch deletion only for explicit `D`;
- does not support branch clobber in Git mode and leaves a newly created checkout in place if post-create verification fails, so it can be inspected rather than destructively rolled back.

Worktrunk operations preserve Worktrunk's own hooks and safety checks; Forestr does not pass hook-disabling flags. Removal workers run in a separate OS session with redirected standard streams, so Herdr can shut down the popup terminal runtime without terminating an approved job. Workers use the stable primary checkout as their working directory, never the linked checkout being removed.

## Configuration

Find the plugin configuration directory with:

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
