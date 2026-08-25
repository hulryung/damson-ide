import Foundation

/// Version-matched `orchard guide get repo` prose. Lives next to CommandSpec so
/// the verbs an agent discovers and the guide that teaches them cannot drift.
public enum RepoGuide {
    public static let topic = "repo"

    public static let content = """
    # Orchard repo

    `orchard repo` is the registry of checkouts Orchard knows about. A project
    is one of these records. `project list|show|current` is the grouping view;
    `repo add|remove` is how a checkout joins or leaves.

    ## Verbs

    `orchard repo list`
      Every registered repo: id, display name, path, host, kind, base ref.

    `orchard repo add --path <path> [--display-name <name>] [--base-ref <ref>] [--host ssh:<name>]`
      Register a checkout. `--host ssh:<name>` probes the remote path over a
      bounded ssh run *before* the row exists. `--host local` is the same as
      omitting `--host`. An unparseable host id is refused rather than read
      as local.

    `orchard repo show --repo <selector>`
      One repo record. The selector is an id, display name, or path.

    `orchard repo remove --repo <selector>`
      Drop the registry row and orchard-data owned by the repo (folder
      workspaces, meta, lineage, retired names, remote-worktree projection
      rows). Git checkouts on disk are left intact. Extra worktrees or
      automations that still name the repo are a typed `repo_in_use` (the
      message names them). There is no `--force`.

    `orchard repo remove --repo <selector> --forget`
      Registry-only unregister of a *remote* repo. This is the spelling
      (a flag on `remove`, not a `repo forget` subverb). It drops the repo
      row and the local rows projecting its remote worktrees, and touches
      nothing on the host — it does not `ssh`, does not `git worktree
      remove`, and does not delete far-side files. `worktree rm` of those
      projections would delete the host's real worktrees, which is not what
      un-registering a view means.

      A local repo refuses `--forget` as typed `forget_local_refused`
      rather than silently dropping worktrees that live on this machine.
      Remove extra local worktrees, then `repo remove` without `--forget`.
      Automations that still target the repo (or one of its workspaces)
      still block, even under `--forget`.

    ## Typed errors

    `unknown_repo` no match for the selector. `invalid_argument` missing
    `--repo` on show/remove, or `--path` on add, or an unparseable `--host`.
    `repo_in_use` extra worktrees or automations still name the repo.
    `forget_local_refused` `--forget` on a local repo. `unknown_host`,
    `remote_not_a_repo`, `host_unverifiable` from a remote add.
    """
}
