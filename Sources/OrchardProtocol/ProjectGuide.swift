import Foundation

/// Version-matched `orchard guide get project` prose. Lives next to CommandSpec so
/// the verbs an agent discovers and the guide that teaches them cannot drift.
public enum ProjectGuide {
    public static let topic = "project"

    public static let content = """
    # Orchard project

    A project is a registered repo. The sidebar groups worktrees under these
    records. `orchard project` is the grouping view; `orchard repo add|remove`
    is how a checkout joins or leaves the registry.

    ## Verbs

    `orchard project list`
      Every registered repo: id, display name, path, host, kind, base ref, and
      worktree count (including the primary checkout).

    `orchard project show --project <selector>`
      One repo plus its worktrees. The selector is a repo id, display name, or
      path — the same vocabulary as `repo show`. `--repo` is an alias of
      `--project`.

    `orchard project current`
      Resolves the current directory to the enclosing project's repo and lists
      that project's worktrees. Typed `not_in_worktree` when `$PWD` is not
      inside a managed workspace.

    ## What this group does not do

    Orca's host-setup verbs (`project setups`, `setup-clone`, `setup-create`,
    `setup-update`, `setup-delete`, `setup-existing-folder`) are not
    implemented. Register a checkout with `repo add --path`, including
    `--host ssh:<name>` for a remote. Independent project-host-setup metadata
    is Orca's multi-host federation model, outside this surface.

    ## Typed errors

    `unknown_repo` no match for the selector. `not_in_worktree` current
    directory is not inside a managed workspace. `invalid_argument` missing
    `--project` on show.
    """
}
