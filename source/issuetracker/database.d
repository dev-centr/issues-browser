module issuetracker.database;

import std.file;
import std.path;
import d2sqlite3;

/// Open or create the SQLite DB at parentDir/.issues/repoName.sqlite
Database openDb(string parentDir, string repoName) {
	auto issuesDir = buildPath(parentDir, ".issues");
	if (!exists(issuesDir))
		mkdir(issuesDir);
	auto dbPath = buildPath(issuesDir, repoName ~ ".sqlite");
	return Database(dbPath);
}

/// Ensure schema exists (repos, issues, comments, sync_meta).
void initSchema(Database db) {
	db.run(
		"CREATE TABLE IF NOT EXISTS repos (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  path TEXT UNIQUE NOT NULL," ~
		"  remote TEXT," ~
		"  owner TEXT," ~
		"  name TEXT NOT NULL," ~
		"  updated_at TEXT" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS issues (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  repo_id INTEGER NOT NULL REFERENCES repos(id)," ~
		"  number INTEGER NOT NULL," ~
		"  title TEXT NOT NULL," ~
		"  state TEXT NOT NULL," ~
		"  body TEXT," ~
		"  url TEXT," ~
		"  created_at TEXT," ~
		"  closed_at TEXT," ~
		"  author TEXT," ~
		"  pr_accepted INTEGER DEFAULT 0," ~
		"  state_reason TEXT," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS comments (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  issue_id INTEGER NOT NULL REFERENCES issues(id)," ~
		"  body TEXT," ~
		"  author TEXT," ~
		"  created_at TEXT" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS sync_meta (" ~
		"  repo_id INTEGER PRIMARY KEY REFERENCES repos(id)," ~
		"  last_sync TEXT" ~
		")"
	);
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_repo ON issues(repo_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_state ON issues(state)");
	db.run("CREATE INDEX IF NOT EXISTS idx_comments_issue ON comments(issue_id)");
}

/// Insert or replace repo; returns repo id.
long upsertRepo(Database db, string path, string remote, string owner, string name) {
	auto stmt = db.prepare("INSERT INTO repos (path, remote, owner, name, updated_at) VALUES (?1,?2,?3,?4,datetime('now')) ON CONFLICT(path) DO UPDATE SET remote=?2, owner=?3, name=?4, updated_at=datetime('now')");
	stmt.bind(1, path);
	stmt.bind(2, remote);
	stmt.bind(3, owner);
	stmt.bind(4, name);
	stmt.execute();
	stmt.reset();
	auto sel = db.prepare("SELECT id FROM repos WHERE path=?1");
	sel.bind(1, path);
	auto result = sel.execute();
	long id = -1;
	foreach (row; result) { id = row.peek!long(0); break; }
	sel.reset();
	return id;
}

/// Insert or replace issue.
void upsertIssue(Database db, long repoId, int number, string title, string state, string body, string url,
	string createdAt, string closedAt, string author, bool prAccepted, string stateReason) {
	auto stmt = db.prepare("INSERT INTO issues (repo_id, number, title, state, body, url, created_at, closed_at, author, pr_accepted, state_reason) " ~
		"VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=?3, state=?4, body=?5, url=?6, created_at=?7, closed_at=?8, author=?9, pr_accepted=?10, state_reason=?11");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	stmt.bind(3, title);
	stmt.bind(4, state);
	stmt.bind(5, body);
	stmt.bind(6, url);
	stmt.bind(7, createdAt);
	stmt.bind(8, closedAt);
	stmt.bind(9, author);
	stmt.bind(10, prAccepted ? 1 : 0);
	stmt.bind(11, stateReason);
	stmt.execute();
	stmt.reset();
}

/// Delete comments for an issue (before re-sync).
void deleteCommentsForIssue(Database db, long issueId) {
	auto stmt = db.prepare("DELETE FROM comments WHERE issue_id=?1");
	stmt.bind(1, issueId);
	stmt.execute();
	stmt.reset();
}

/// Get issue id by repo_id and number.
long getIssueId(Database db, long repoId, int number) {
	auto stmt = db.prepare("SELECT id FROM issues WHERE repo_id=?1 AND number=?2");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	auto result = stmt.execute();
	long id = -1;
	foreach (row; result) { id = row.peek!long(0); break; }
	stmt.reset();
	return id;
}

/// Insert comment.
void insertComment(Database db, long issueId, string body, string author, string createdAt) {
	auto stmt = db.prepare("INSERT INTO comments (issue_id, body, author, created_at) VALUES (?1,?2,?3,?4)");
	stmt.bind(1, issueId);
	stmt.bind(2, body);
	stmt.bind(3, author);
	stmt.bind(4, createdAt);
	stmt.execute();
	stmt.reset();
}
