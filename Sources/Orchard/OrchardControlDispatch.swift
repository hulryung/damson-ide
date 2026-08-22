import Foundation
import DamsonOrchestrator
import DamsonTerminal
import OrchardControl

extension Notification.Name {
    /// Posted by the control socket's `show-settings`; the app delegate owns the window.
    static let orchardShowSettings = Notification.Name("orchard.showSettings")
}

/// Maps an `OrchardCommand` (from orchard-cli) onto the live `WorkspaceStore`. Runs on the
/// main actor — the control server hops here from its worker thread. This is the surface an
/// external AI uses to drive Orchard: open workspaces, enqueue tasks, read/drive agents.
@MainActor
extension WorkspaceStore {
    func handle(_ cmd: OrchardCommand) -> OrchardResponse {
        switch cmd.cmd {
        case "list-workspaces":
            return OrchardResponse(ok: true, workspaces: workspaces.enumerated().map {
                WorkspaceInfo(index: $0.offset, name: $0.element.name,
                              path: $0.element.repo.path,
                              agentCount: $0.element.controller.agents.count,
                              worktreeCount: $0.element.controller.worktrees.count,
                              branchPrefix: $0.element.controller.branchPrefix,
                              baseRef: $0.element.controller.baseRef)
            })

        case "add-workspace":
            guard let path = cmd.path else { return .error("path required") }
            addWorkspace(repo: URL(fileURLWithPath: path), silent: true)
            guard workspaces.contains(where: { $0.repo.standardizedFileURL.path == URL(fileURLWithPath: path).standardizedFileURL.path }) else {
                return .error("could not open \(path) (not a git repo?)")
            }
            return .ok("opened \(path)")

        case "list-agents":
            return OrchardResponse(ok: true, agents: agentInfos(workspaceFilter: cmd.workspace))

        case "list-worktrees":
            return OrchardResponse(ok: true, worktrees: worktreeInfos(workspaceFilter: cmd.workspace))

        case "worktree-diff":
            guard let record = findWorktree(cmd.agent) else { return .error("worktree not found") }
            let service = GitService()
            let base = record.worktree.baseRef.isEmpty ? "HEAD" : record.worktree.baseRef
            return OrchardResponse(
                ok: true,
                output: service.diff(worktree: record.path, baseRef: base, path: cmd.text))

        case "delete-worktree":
            guard let record = findWorktree(cmd.agent) else { return .error("worktree not found") }
            guard let ws = workspaces.first(where: { w in
                w.controller.worktrees.contains { $0.id == record.id }
            }) else { return .error("worktree not found") }
            let force = cmd.text == "force"
            do {
                let removed = try ws.controller.deleteWorktree(record, force: force)
                return removed
                    ? .ok("deleted \(record.branch)")
                    : .error("worktree has uncommitted changes; pass force to discard them")
            } catch {
                return .error(String(describing: error))
            }

        case "set-concurrency":
            guard let wi = cmd.workspace, workspaces.indices.contains(wi) else {
                return .error("invalid workspace index")
            }
            guard let count = cmd.count, count >= 1 else { return .error("count >= 1 required") }
            workspaces[wi].controller.setMaxConcurrency(count)
            return .ok("maxConcurrency = \(count) for \(workspaces[wi].name)")

        case "add-task":
            guard let wi = cmd.workspace, workspaces.indices.contains(wi) else {
                return .error("invalid workspace index (see list-workspaces)")
            }
            guard let prompt = cmd.prompt, !prompt.isEmpty else { return .error("prompt required") }
            let ws = workspaces[wi]
            let engine = cmd.engine ?? "claude-code"
            guard AgentEngineRegistry.engine(id: engine) != nil else {
                return .error("unknown engine '\(engine)'")
            }
            // Refuse here rather than enqueuing work that will fail once it is scheduled —
            // a queued task that dies silently is much harder to understand than a rejection.
            if let reason = ws.controller.worktreeUnavailableReason { return .error(reason) }
            let title = cmd.title ?? String(prompt.prefix(40))
            ws.controller.enqueue(AgentTask(title: title, prompt: prompt,
                                            engineID: engine, baseRepoPath: ws.repo.path))
            return .ok("enqueued '\(title)' in \(ws.name)")

        case "set-terminal":
            // Mirrors `set-concurrency`: a scriptable way to drive an appearance setting,
            // which is also the only way to verify from outside that a live terminal picked
            // the change up.
            var changed: [String] = []
            if let font = cmd.text, !font.isEmpty {
                settings.fontFamily = font
                changed.append("font=\(font)")
            }
            if let size = cmd.count, size > 0 {
                settings.fontSize = Double(size)
                changed.append("size=\(size)")
            }
            if let theme = cmd.title, !theme.isEmpty {
                guard DamsonTheme.preset(named: theme) != nil else {
                    return .error("unknown theme '\(theme)'")
                }
                settings.themeName = theme
                changed.append("theme=\(theme)")
            }
            guard !changed.isEmpty else { return .error("nothing to set") }
            return .ok(changed.joined(separator: " "))

        case "terminal-info":
            return OrchardResponse(ok: true, output: terminalInfo().joined(separator: "\n"))

        case "show-settings":
            // Same path as ⌘, so the window can be verified on screen without synthesizing
            // a keystroke — mirrors `show-new-session`.
            NotificationCenter.default.post(name: .orchardShowSettings, object: nil)
            return .ok("opened settings")

        case "show-new-session":
            // Trigger exactly what Cmd-T does (requestNewSession → engine-picker sheet),
            // so the sheet can be verified on screen without synthesizing a keystroke.
            if selectedWorkspaceID == nil { selectedWorkspaceID = workspaces.first?.id }
            requestNewSession(mode: .tabs)
            return .ok("opened new-session picker")

        case "new-session":
            guard let wi = cmd.workspace, workspaces.indices.contains(wi) else {
                return .error("invalid workspace index")
            }
            let engine = cmd.engine ?? "claude-code"
            guard AgentEngineRegistry.engine(id: engine) != nil else {
                return .error("unknown engine '\(engine)'")
            }
            if let reason = workspaces[wi].controller.worktreeUnavailableReason {
                return .error(reason)
            }
            workspaces[wi].controller.newInteractiveAgent(engineID: engine)
            return .ok("opened \(engine) session in \(workspaces[wi].name)")

        case "agent-output":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            return OrchardResponse(ok: true, output: agent.gridText())

        case "view":
            switch (cmd.text ?? "").lowercased() {
            // "tabs" is the historical name for the single-worktree detail view, which is
            // now the default; it survives here so existing scripts keep working.
            case "grid": showsGridOverview = true
            case "tabs": showsGridOverview = false
            default: return .error("view requires grid|tabs")
            }
            return .ok("view = \(cmd.text ?? "")")

        case "focus":
            // Same effect as clicking the agent in the sidebar: open it large in the tabbed view.
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            for (wi, ws) in workspaces.enumerated() where ws.controller.agents.contains(where: { $0.id == agent.id }) {
                selectedWorkspaceID = ws.id
                _ = wi
            }
            focus(agent.id)
            return .ok("focused \(agent.shortID)")

        case "send-text":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            guard let text = cmd.text else { return .error("text required") }
            agent.sendText(text)
            return .ok()

        case "send-key":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            guard let keys = cmd.keys, !keys.isEmpty else { return .error("keys required") }
            for key in keys { agent.sendKey(key) }
            return .ok()

        case "interrupt":
            guard let agent = findAgent(cmd.agent) else { return .error("agent not found") }
            agent.interrupt()
            return .ok()

        default:
            return .error("unknown command: \(cmd.cmd)")
        }
    }

    private func agentInfos(workspaceFilter: Int?) -> [AgentInfo] {
        var out: [AgentInfo] = []
        for (wi, ws) in workspaces.enumerated() {
            if let filter = workspaceFilter, filter != wi { continue }
            for agent in ws.controller.agents {
                out.append(AgentInfo(
                    id: agent.shortID, workspace: wi,
                    title: agent.task?.title ?? "agent",
                    engine: agent.engine.id, state: agent.state.cliToken,
                    branch: agent.worktree?.branch))
            }
        }
        return out
    }

    private func worktreeInfos(workspaceFilter: Int?) -> [WorktreeInfo] {
        var out: [WorktreeInfo] = []
        for (wi, ws) in workspaces.enumerated() {
            if let filter = workspaceFilter, filter != wi { continue }
            for record in ws.controller.worktrees {
                let stat = record.status.stat
                out.append(WorktreeInfo(
                    id: String(record.id.uuidString.prefix(8)).lowercased(),
                    workspace: wi,
                    title: record.title,
                    branch: record.branch,
                    path: record.path.path,
                    state: record.displayState.label,
                    agent: record.agent?.shortID,
                    filesChanged: stat.fileCount,
                    added: stat.added,
                    deleted: stat.deleted,
                    commitsAhead: record.status.commitsAhead))
            }
        }
        return out
    }

    private func findWorktree(_ shortID: String?) -> WorktreeRecord? {
        guard let sid = shortID?.lowercased() else { return nil }
        for ws in workspaces {
            for record in ws.controller.worktrees
            where String(record.id.uuidString.prefix(8)).lowercased() == sid {
                return record
            }
        }
        return nil
    }

    private func findAgent(_ shortID: String?) -> AgentSession? {
        guard let sid = shortID?.lowercased() else { return nil }
        for ws in workspaces {
            for agent in ws.controller.agents where agent.shortID == sid { return agent }
        }
        return nil
    }
}
