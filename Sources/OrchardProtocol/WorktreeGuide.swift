import Foundation

/// Version-matched `orchard guide get worktree` prose. Lives next to CommandSpec so
/// the verbs an agent discovers and the guide that teaches them cannot drift.
public enum WorktreeGuide {
    public static let topic = "worktree"

    public static let content = """
    # Orchard worktree

    `orchard worktree` is the agent-facing surface for managed checkouts. Git
    worktrees and folder workspaces project into the same shape. Address one
    with `--worktree <selector>` (id, display name, or path). When the flag is
    omitted, `show`, `set`, and `rm` also accept a positional selector; `current`
    uses the current directory.

    ## Verbs

    `orchard worktree list [--repo <selector>] [--limit <n>]`
      Every managed workspace, newest activity first. Scope with `--repo`.
      `truncated` plus `totalCount` say when `--limit` held rows back. A remote
      repo that cannot be re-read still lists the last-known set and a warning.

    `orchard worktree show --worktree <selector>`
      One workspace: id, path, host, branch, HEAD, board column, comment, links,
      lineage.

    `orchard worktree current`
      Resolves the current directory to the longest enclosing managed workspace.
      Typed `not_in_worktree` when none encloses `$PWD`.

    `orchard worktree create --name <name> [--repo <selector>]`
      Forks a new checkout. `--repo` is inferred from the current worktree when
      omitted. `--no-parent` is lineage only; `--base-branch` is the git base —
      they are independent. `--agent` launches that engine in the first terminal;
      `--prompt` is its initial work. `--run-hooks` runs the repo's orchard.yaml
      setup script.

    `orchard worktree set --worktree <selector> [--display-name] [--status] [--comment] [--issue] [--pr]`
      User-authored metadata. `--status` / `--workspace-status` is the board
      column (todo, in-progress, in-review, completed, or a custom id), not
      derived live status.

    `orchard worktree rm --worktree <selector> [--force] [--delete-branch] [--force-branch]`
      Removes the worktree from git and the registry. Aliases: `remove`,
      `delete`. `--force` is required when dirty. `--delete-branch` runs
      `git branch -d` after a successful removal; `--force-branch` is `-D`.
      Refuses the repo primary checkout (`close the project instead`). Rmdirs
      the empty per-repo container; never recursively. A remote worktree's
      `rm` deletes the checkout on the host. To drop Orchard's view of a
      remote repo without touching the far side, use `repo remove --forget`.

    `orchard worktree ps [--repo <selector>] [--limit <n>]`
      Compact listing of live agent/shell processes and attributed listening
      ports per worktree. `workspace-ports` is the ports-only view.

    ## Typed errors

    `unknown_worktree` no match for the selector. `not_in_worktree` current
    directory is not inside a managed workspace. `invalid_argument` missing
    selector or repo. `worktree_dirty` rm refused a dirty checkout.
    `branch_not_merged` `--delete-branch` refused an unmerged branch.
    `remote_unsupported` a remote-only operation (for example deleting a
    remote branch).
    """
}
