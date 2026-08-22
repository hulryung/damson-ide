import Foundation

/// Schema for `orchestration.db`, ported from Orca's create-table SQL
/// (~/dev/orca/src/main/runtime/orchestration/db/schema/create-core-tables-sql.ts and
/// create-graph-tables-sql.ts) with the legacy-contract/federation columns dropped —
/// legacy-contract migration is explicitly out of scope for v2 foundation
/// (docs/REBUILD-PLAN.md "Product decisions").
///
/// Versioned via `PRAGMA user_version`; v1 is the first real schema. All enum-valued
/// columns are CHECK-constrained to the verbatim enum strings (§1.3) so a bad writer
/// fails loudly at the DB layer, not silently at the next read.
enum OrchestrationSchema {
    static let version = 1

    static let createTablesSQL = """
    CREATE TABLE IF NOT EXISTS runs (
      id                    TEXT PRIMARY KEY,
      objective             TEXT NOT NULL,
      coordinator_handle    TEXT,
      coordinator_pane_key  TEXT,
      consumer_generation   INTEGER NOT NULL DEFAULT 0,
      created_at            TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at            TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS messages (
      id            TEXT NOT NULL,
      run_id        TEXT NOT NULL,
      from_handle   TEXT NOT NULL,
      to_handle     TEXT NOT NULL,
      subject       TEXT NOT NULL,
      body          TEXT NOT NULL DEFAULT '',
      type          TEXT NOT NULL DEFAULT 'status'
        CHECK(type IN (
          'status', 'dispatch', 'worker_done', 'merge_ready',
          'escalation', 'handoff', 'decision_gate', 'question', 'heartbeat'
        )),
      priority      TEXT NOT NULL DEFAULT 'normal'
        CHECK(priority IN ('normal', 'high', 'urgent')),
      thread_id     TEXT,
      payload       TEXT,
      read          INTEGER NOT NULL DEFAULT 0,
      sequence      INTEGER PRIMARY KEY AUTOINCREMENT,
      created_at    TEXT NOT NULL DEFAULT (datetime('now')),
      delivered_at  TEXT,
      sender_pane_key TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_messages_id ON messages(id);
    CREATE INDEX IF NOT EXISTS idx_inbox ON messages(to_handle, read);
    CREATE INDEX IF NOT EXISTS idx_thread ON messages(thread_id);
    CREATE INDEX IF NOT EXISTS idx_messages_run_sequence ON messages(run_id, sequence);

    CREATE TABLE IF NOT EXISTS deliveries (
      id                    TEXT PRIMARY KEY,
      run_id                TEXT NOT NULL,
      consumer_generation   INTEGER NOT NULL,
      message_ids           TEXT NOT NULL,
      status                TEXT NOT NULL DEFAULT 'outstanding'
        CHECK(status IN ('outstanding', 'acknowledged', 'fenced')),
      created_at            TEXT NOT NULL DEFAULT (datetime('now')),
      acknowledged_at       TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_deliveries_one_outstanding
      ON deliveries(run_id) WHERE status = 'outstanding';
    CREATE INDEX IF NOT EXISTS idx_deliveries_run_created
      ON deliveries(run_id, created_at);

    CREATE TABLE IF NOT EXISTS tasks (
      id            TEXT PRIMARY KEY,
      run_id        TEXT NOT NULL,
      parent_id     TEXT,
      created_by_terminal_handle TEXT,
      created_by_pane_key TEXT,
      created_by_process_incarnation TEXT,
      created_by_run_generation INTEGER,
      task_title    TEXT,
      display_name  TEXT,
      spec          TEXT NOT NULL,
      status        TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN (
          'pending', 'ready', 'dispatched',
          'completed', 'failed', 'blocked'
        )),
      deps          TEXT NOT NULL DEFAULT '[]',
      result        TEXT,
      created_at    TEXT NOT NULL DEFAULT (datetime('now')),
      completed_at  TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);
    CREATE INDEX IF NOT EXISTS idx_tasks_parent ON tasks(parent_id);
    CREATE INDEX IF NOT EXISTS idx_tasks_run_status ON tasks(run_id, status);

    CREATE TABLE IF NOT EXISTS dispatch_contexts (
      id                  TEXT PRIMARY KEY,
      run_id              TEXT NOT NULL,
      task_id             TEXT NOT NULL,
      launch_token_hash   TEXT,
      assignee_handle     TEXT,
      assignee_pane_key   TEXT,
      capability_hash     TEXT,
      process_incarnation TEXT,
      capability_revoked_at TEXT,
      status              TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'dispatched', 'completed', 'failed', 'circuit_broken')),
      failure_count       INTEGER NOT NULL DEFAULT 0,
      last_failure        TEXT,
      termination_reason  TEXT,
      dispatched_at       TEXT,
      completed_at        TEXT,
      created_at          TEXT NOT NULL DEFAULT (datetime('now')),
      last_heartbeat_at   TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_dispatch_task ON dispatch_contexts(task_id);
    CREATE INDEX IF NOT EXISTS idx_dispatch_status ON dispatch_contexts(status);
    CREATE INDEX IF NOT EXISTS idx_dispatch_assignee_handle ON dispatch_contexts(assignee_handle);
    CREATE INDEX IF NOT EXISTS idx_dispatch_run_status ON dispatch_contexts(run_id, status);

    CREATE TABLE IF NOT EXISTS decision_gates (
      id            TEXT PRIMARY KEY,
      run_id        TEXT NOT NULL,
      task_id       TEXT NOT NULL,
      question      TEXT NOT NULL,
      options       TEXT NOT NULL DEFAULT '[]',
      status        TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'resolved', 'timeout')),
      resolution    TEXT,
      created_at    TEXT NOT NULL DEFAULT (datetime('now')),
      resolved_at   TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_gates_task ON decision_gates(task_id);
    CREATE INDEX IF NOT EXISTS idx_gates_status ON decision_gates(status);

    CREATE TABLE IF NOT EXISTS worker_dispatches (
      dispatch_id            TEXT PRIMARY KEY,
      state                  TEXT NOT NULL DEFAULT 'starting'
        CHECK(state IN (
          'starting', 'ready', 'start_unknown', 'failed', 'succeeded',
          'stopping', 'stop_unknown', 'stopped', 'abandoned'
        )),
      stage                  TEXT NOT NULL DEFAULT 'accepted',
      worktree_id            TEXT,
      agent_terminal_handle  TEXT,
      setup_state            TEXT NOT NULL DEFAULT 'not_applicable',
      effects                TEXT NOT NULL DEFAULT '[]',
      residual_resources     TEXT NOT NULL DEFAULT '[]',
      start_options          TEXT NOT NULL DEFAULT '{}',
      last_error             TEXT,
      created_at             TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at             TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS worker_terminal_resources (
      id                       TEXT PRIMARY KEY,
      origin_dispatch_id       TEXT NOT NULL,
      owner_dispatch_id        TEXT NOT NULL,
      worktree_id              TEXT,
      terminal_handle          TEXT NOT NULL,
      pane_key                 TEXT,
      process_incarnation      TEXT,
      ownership_state          TEXT NOT NULL DEFAULT 'owned'
        CHECK(ownership_state IN ('owned', 'transferred', 'user_owned', 'external', 'released')),
      release_state            TEXT NOT NULL DEFAULT 'not_requested'
        CHECK(release_state IN (
          'not_requested', 'retained', 'requested', 'releasing', 'released', 'unknown'
        )),
      retained_reason          TEXT,
      release_requested_at     TEXT,
      release_completed_at     TEXT,
      release_error            TEXT,
      created_at               TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at               TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE UNIQUE INDEX IF NOT EXISTS idx_worker_terminal_resources_owner
      ON worker_terminal_resources(owner_dispatch_id);
    CREATE INDEX IF NOT EXISTS idx_worker_terminal_resources_handle
      ON worker_terminal_resources(terminal_handle);
    CREATE INDEX IF NOT EXISTS idx_worker_terminal_resources_pane
      ON worker_terminal_resources(pane_key);

    CREATE TABLE IF NOT EXISTS worker_terminal_archives (
      dispatch_id   TEXT PRIMARY KEY,
      resource_id   TEXT NOT NULL,
      kind          TEXT NOT NULL CHECK(kind IN ('transcript_pin', 'terminal_tail')),
      content       TEXT NOT NULL,
      created_at    TEXT NOT NULL DEFAULT (datetime('now'))
    );

    CREATE TABLE IF NOT EXISTS mutation_receipts (
      caller_fingerprint  TEXT NOT NULL,
      request_id          TEXT NOT NULL,
      method              TEXT NOT NULL,
      payload_hash        TEXT NOT NULL,
      state               TEXT NOT NULL DEFAULT 'pending'
        CHECK(state IN ('pending', 'completed')),
      receipt             TEXT,
      created_at          TEXT NOT NULL DEFAULT (datetime('now')),
      updated_at          TEXT NOT NULL DEFAULT (datetime('now')),
      PRIMARY KEY (caller_fingerprint, request_id)
    );

    CREATE TABLE IF NOT EXISTS mutation_caller_identities (
      transport           TEXT PRIMARY KEY,
      caller_fingerprint  TEXT NOT NULL UNIQUE
    );

    CREATE TABLE IF NOT EXISTS questions (
      message_id                TEXT PRIMARY KEY,
      run_id                    TEXT NOT NULL,
      dispatch_id               TEXT NOT NULL,
      asker_handle              TEXT NOT NULL,
      status                    TEXT NOT NULL DEFAULT 'pending'
        CHECK(status IN ('pending', 'answered', 'closed')),
      answer_message_id         TEXT,
      answer_body               TEXT,
      answered_by_generation    INTEGER,
      created_at                TEXT NOT NULL DEFAULT (datetime('now')),
      answered_at               TEXT,
      closed_at                 TEXT
    );

    CREATE INDEX IF NOT EXISTS idx_questions_dispatch_status
      ON questions(dispatch_id, status);
    """

    /// Create tables on a fresh DB or verify/stamp the version on an existing one.
    static func migrate(_ db: SQLiteDatabase) throws {
        let current = try (db.queryOne("PRAGMA user_version")?.int("user_version")) ?? 0
        if current > version {
            throw OrchestrationError(
                "schema_version_skew",
                "orchestration.db is schema v\(current); this build understands up to v\(version)."
            )
        }
        try db.inTransaction {
            try db.exec(createTablesSQL)
        }
        // PRAGMA cannot be parameterized; version is a compile-time constant.
        try db.exec("PRAGMA user_version = \(version)")
    }
}
