import Foundation

/// Human copy for the app delete sheet — the same choice and result the CLI
/// `worktree rm --delete-branch` / `--force-branch` path advertises (T40/T53).
public enum WorktreeDeleteFormatter {
    /// Predicted outcome of the current checkbox state, shown in the preflight so
    /// the user sees the result before confirming.
    public static func predictedOutcome(
        branch: String,
        branchMerged: Bool,
        deleteBranch: Bool,
        forceBranch: Bool
    ) -> String {
        if !deleteBranch {
            return "The branch '\(branch)' will be kept."
        }
        if branchMerged {
            return "The branch '\(branch)' will be deleted (merged)."
        }
        if forceBranch {
            return "The branch '\(branch)' will be force-deleted (not fully merged)."
        }
        return "The branch '\(branch)' is not fully merged. Enable force-delete or the removal will be refused."
    }

    public static func predictedOutcome(
        preflight: WorktreeDeletionPreflight,
        deleteBranch: Bool,
        forceBranch: Bool
    ) -> String {
        predictedOutcome(
            branch: preflight.worktree.branch,
            branchMerged: preflight.branchMerged,
            deleteBranch: deleteBranch,
            forceBranch: forceBranch)
    }

    /// Result line matching CLI `branchDeleted` versus a kept branch.
    public static func resultMessage(branch: String, removed: Bool, branchDeleted: Bool) -> String {
        guard removed else { return "Worktree was not removed." }
        if branchDeleted {
            return "Removed worktree. Deleted branch '\(branch)'."
        }
        if branch.isEmpty {
            return "Removed worktree."
        }
        return "Removed worktree. Branch '\(branch)' was kept."
    }
}
