import Foundation

/// Version-matched `orchard guide get conflicts` prose. Lives next to CommandSpec so
/// the verbs an agent discovers and the guide that teaches them cannot drift.
public enum ConflictsGuide {
    public static let topic = "conflicts"

    public static let content = """
    # Orchard conflicts

    `orchard conflicts` is the agent-facing surface of the same UI-free git
    conflict service the conflict-review pane uses. It lists unmerged paths,
    shows hunks, takes a whole-file side, resolves one hunk, and stages a
    fully-decided file. It never finishes or aborts the merge, rebase,
    cherry-pick, or revert — those stay `git commit` / `git rebase --continue`
    / `git merge --abort` in a terminal.

    Address a worktree with `--worktree <selector>`. When the flag is omitted
    the CLI uses the current directory. A remote workspace is refused as
    `remote_unsupported`.

    ## Verbs

    `orchard conflicts list [--worktree <selector>]`
      Conflicted files plus the in-progress operation. An operation can be
      active with zero files (everything staged, waiting for the git
      continue/commit); `nextStepHint` then names the command to run.

    `orchard conflicts show --path <path> [--worktree <selector>]`
      Hunks for one unmerged path. `--hunk` on resolve is the 0-based `index`
      this prints, not a stable id: after a partial resolve the remaining
      hunks are re-indexed from 0. A delete/modify conflict or a binary file
      has no hunks — use `take`.

    `orchard conflicts take --path <path> --side ours|theirs [--worktree <selector>]`
      Whole-file resolution. Stages the chosen index stage, or deletes and
      stages the removal when that side has no stage. This is the only
      resolution route for binaries and for kinds without inline markers.

    `orchard conflicts resolve --path <path> --hunk <n> --choice ours|theirs|both [--worktree <selector>]`
      Rewrite one hunk. Other hunks keep their markers. Staging happens only
      when nothing remains undecided — the same gate the pane uses.

    `orchard conflicts stage --path <path> [--worktree <selector>]`
      Stage a path resolved by hand. Refuses with `conflict_markers_remain`
      while `<<<<<<<` / `>>>>>>>` markers are still in the file; staging then
      would bury them in a commit.

    ## Ours and theirs

    During a merge, ours is the current branch and theirs is the incoming
    commit. During a rebase git replays *your* commits onto the upstream, so
    the sides swap: ours is the upstream and theirs is the replayed commit.
    `list` and `show` print the operation's labels; do not invert them.

    `--choice both` writes ours then theirs, markers dropped.

    ## Typed errors

    `invalid_argument` missing or illegal `--path` / `--side` / `--hunk` /
    `--choice`. `not_conflicted` the path is not unmerged. `hunk_not_found`
    the index is out of range for the current working file. `cannot_read` the
    file is not text (binary or missing) so hunk resolve cannot run — use
    `take`. `conflict_markers_remain` stage refused. `remote_unsupported`
    the workspace is not local. `git_error` a git process failed.

    This surface resolves files. It does not run `merge --abort`,
    `rebase --continue`, or `commit`.
    """
}
