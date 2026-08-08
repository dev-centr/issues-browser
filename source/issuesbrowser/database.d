module issuesbrowser.database;

import std.file;
import std.path;
import std.string;
import d2sqlite3;
import issuesbrowser.paths;

/// Open or create SQLite DB at archives/<host>/<owner>/<repo>/database.sqlite
Database openDb(string host, string owner, string name, string root = null) {
	ensureArchiveDirs(host, owner, name, root);
	return Database(databasePath(host, owner, name, root));
}

/// Migrate legacy DB locations into the central archive path.
void migrateLegacyDbIfNeeded(string host, string owner, string name, string repoPath = null, string root = null) {
	auto neu = databasePath(host, owner, name, root);
	if (exists(neu)) return;
	string[] candidates;
	if (repoPath.length) {
		candidates ~= buildPath(repoPath, ".issues", dbFileName);
		candidates ~= buildPath(dirName(repoPath), ".issues", name ~ ".sqlite");
	}
	foreach (c; candidates) {
		if (exists(c)) {
			ensureArchiveDirs(host, owner, name, root);
			rename(c, neu);
			return;
		}
	}
}

void initSchema(Database db) {
	db.run(
		"CREATE TABLE IF NOT EXISTS repos (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  path TEXT," ~
		"  remote TEXT," ~
		"  owner TEXT," ~
		"  name TEXT NOT NULL," ~
		"  host TEXT," ~
		"  updated_at TEXT," ~
		"  UNIQUE(host, owner, name)" ~
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
		"  updated_at TEXT," ~
		"  author TEXT," ~
		"  pr_accepted INTEGER DEFAULT 0," ~
		"  state_reason TEXT," ~
		"  is_pr INTEGER DEFAULT 0," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	// migrate older DBs missing columns
	tryAddColumn(db, "issues", "updated_at", "TEXT");
	tryAddColumn(db, "issues", "is_pr", "INTEGER DEFAULT 0");
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
		"CREATE TABLE IF NOT EXISTS discussions (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  repo_id INTEGER NOT NULL REFERENCES repos(id)," ~
		"  number INTEGER NOT NULL," ~
		"  title TEXT NOT NULL," ~
		"  category TEXT," ~
		"  body TEXT," ~
		"  url TEXT," ~
		"  created_at TEXT," ~
		"  author TEXT," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS discussion_comments (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  discussion_id INTEGER NOT NULL REFERENCES discussions(id)," ~
		"  body TEXT," ~
		"  author TEXT," ~
		"  created_at TEXT" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS pull_requests (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  repo_id INTEGER NOT NULL REFERENCES repos(id)," ~
		"  number INTEGER NOT NULL," ~
		"  title TEXT NOT NULL," ~
		"  state TEXT NOT NULL," ~
		"  body TEXT," ~
		"  url TEXT," ~
		"  created_at TEXT," ~
		"  closed_at TEXT," ~
		"  merged_at TEXT," ~
		"  updated_at TEXT," ~
		"  author TEXT," ~
		"  merged INTEGER DEFAULT 0," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS issue_pr_links (" ~
		"  issue_id INTEGER NOT NULL REFERENCES issues(id)," ~
		"  pr_id INTEGER NOT NULL REFERENCES pull_requests(id)," ~
		"  PRIMARY KEY (issue_id, pr_id)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS sync_meta (" ~
		"  repo_id INTEGER PRIMARY KEY REFERENCES repos(id)," ~
		"  last_sync TEXT," ~
		"  issues_updated_at TEXT," ~
		"  prs_updated_at TEXT," ~
		"  discussions_cursor TEXT" ~
		")"
	);
	tryAddColumn(db, "sync_meta", "issues_updated_at", "TEXT");
	tryAddColumn(db, "sync_meta", "prs_updated_at", "TEXT");
	tryAddColumn(db, "sync_meta", "discussions_cursor", "TEXT");
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_repo ON issues(repo_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_state ON issues(state)");
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_pr ON issues(is_pr)");
	db.run("CREATE INDEX IF NOT EXISTS idx_comments_issue ON comments(issue_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_discussions_repo ON discussions(repo_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_prs_repo ON pull_requests(repo_id)");
}

private void tryAddColumn(Database db, string table, string col, string decl) {
	try {
		db.run("ALTER TABLE " ~ table ~ " ADD COLUMN " ~ col ~ " " ~ decl);
	} catch (Exception) {}
}

long upsertRepo(Database db, string path, string remote, string owner, string name, string host) {
	auto stmt = db.prepare(
		"INSERT INTO repos (path, remote, owner, name, host, updated_at) VALUES (?1,?2,?3,?4,?5,datetime('now')) " ~
		"ON CONFLICT(host, owner, name) DO UPDATE SET path=?1, remote=?2, updated_at=datetime('now')");
	stmt.bind(1, path);
	stmt.bind(2, remote);
	stmt.bind(3, owner);
	stmt.bind(4, name);
	stmt.bind(5, host);
	stmt.execute();
	stmt.reset();
	auto sel = db.prepare("SELECT id FROM repos WHERE host=?1 AND owner=?2 AND name=?3");
	sel.bind(1, host);
	sel.bind(2, owner);
	sel.bind(3, name);
	long id = -1;
	foreach (row; sel.execute()) { id = row.peek!long(0); break; }
	sel.reset();
	return id;
}

void upsertIssue(Database db, long repoId, int number, string title, string state, string body, string url,
	string createdAt, string closedAt, string author, bool prAccepted, string stateReason, bool isPr, string updatedAt) {
	auto stmt = db.prepare(
		"INSERT INTO issues (repo_id, number, title, state, body, url, created_at, closed_at, updated_at, author, pr_accepted, state_reason, is_pr) " ~
		"VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=?3, state=?4, body=?5, url=?6, created_at=?7, closed_at=?8, updated_at=?9, author=?10, pr_accepted=?11, state_reason=?12, is_pr=?13");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	stmt.bind(3, title);
	stmt.bind(4, state);
	stmt.bind(5, body);
	stmt.bind(6, url);
	stmt.bind(7, createdAt);
	stmt.bind(8, closedAt);
	stmt.bind(9, updatedAt);
	stmt.bind(10, author);
	stmt.bind(11, prAccepted ? 1 : 0);
	stmt.bind(12, stateReason);
	stmt.bind(13, isPr ? 1 : 0);
	stmt.execute();
	stmt.reset();
}

void upsertPullRequest(Database db, long repoId, int number, string title, string state, string body, string url,
	string createdAt, string closedAt, string mergedAt, string updatedAt, string author, bool merged) {
	auto stmt = db.prepare(
		"INSERT INTO pull_requests (repo_id, number, title, state, body, url, created_at, closed_at, merged_at, updated_at, author, merged) " ~
		"VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=?3, state=?4, body=?5, url=?6, created_at=?7, closed_at=?8, merged_at=?9, updated_at=?10, author=?11, merged=?12");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	stmt.bind(3, title);
	stmt.bind(4, state);
	stmt.bind(5, body);
	stmt.bind(6, url);
	stmt.bind(7, createdAt);
	stmt.bind(8, closedAt);
	stmt.bind(9, mergedAt);
	stmt.bind(10, updatedAt);
	stmt.bind(11, author);
	stmt.bind(12, merged ? 1 : 0);
	stmt.execute();
	stmt.reset();
}

long getPrId(Database db, long repoId, int number) {
	auto stmt = db.prepare("SELECT id FROM pull_requests WHERE repo_id=?1 AND number=?2");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	long id = -1;
	foreach (row; stmt.execute()) { id = row.peek!long(0); break; }
	stmt.reset();
	return id;
}

void linkIssuePr(Database db, long issueId, long prId) {
	if (issueId < 0 || prId < 0) return;
	auto stmt = db.prepare("INSERT OR IGNORE INTO issue_pr_links (issue_id, pr_id) VALUES (?1,?2)");
	stmt.bind(1, issueId);
	stmt.bind(2, prId);
	stmt.execute();
	stmt.reset();
}

void deleteCommentsForIssue(Database db, long issueId) {
	auto stmt = db.prepare("DELETE FROM comments WHERE issue_id=?1");
	stmt.bind(1, issueId);
	stmt.execute();
	stmt.reset();
}

long getIssueId(Database db, long repoId, int number) {
	auto stmt = db.prepare("SELECT id FROM issues WHERE repo_id=?1 AND number=?2");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	long id = -1;
	foreach (row; stmt.execute()) { id = row.peek!long(0); break; }
	stmt.reset();
	return id;
}

void insertComment(Database db, long issueId, string body, string author, string createdAt) {
	auto stmt = db.prepare("INSERT INTO comments (issue_id, body, author, created_at) VALUES (?1,?2,?3,?4)");
	stmt.bind(1, issueId);
	stmt.bind(2, body);
	stmt.bind(3, author);
	stmt.bind(4, createdAt);
	stmt.execute();
	stmt.reset();
}

void upsertDiscussion(Database db, long repoId, int number, string title, string category, string body, string url,
	string createdAt, string author) {
	auto stmt = db.prepare("INSERT INTO discussions (repo_id, number, title, category, body, url, created_at, author) " ~
		"VALUES (?1,?2,?3,?4,?5,?6,?7,?8) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=?3, category=?4, body=?5, url=?6, created_at=?7, author=?8");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	stmt.bind(3, title);
	stmt.bind(4, category);
	stmt.bind(5, body);
	stmt.bind(6, url);
	stmt.bind(7, createdAt);
	stmt.bind(8, author);
	stmt.execute();
	stmt.reset();
}

long getDiscussionId(Database db, long repoId, int number) {
	auto stmt = db.prepare("SELECT id FROM discussions WHERE repo_id=?1 AND number=?2");
	stmt.bind(1, repoId);
	stmt.bind(2, number);
	long id = -1;
	foreach (row; stmt.execute()) { id = row.peek!long(0); break; }
	stmt.reset();
	return id;
}

void deleteCommentsForDiscussion(Database db, long discussionId) {
	auto stmt = db.prepare("DELETE FROM discussion_comments WHERE discussion_id=?1");
	stmt.bind(1, discussionId);
	stmt.execute();
	stmt.reset();
}

void insertDiscussionComment(Database db, long discussionId, string body, string author, string createdAt) {
	auto stmt = db.prepare("INSERT INTO discussion_comments (discussion_id, body, author, created_at) VALUES (?1,?2,?3,?4)");
	stmt.bind(1, discussionId);
	stmt.bind(2, body);
	stmt.bind(3, author);
	stmt.bind(4, createdAt);
	stmt.execute();
	stmt.reset();
}

void setLastSync(Database db, long repoId, string issuesUpdatedAt = null, string prsUpdatedAt = null, string discussionsCursor = null) {
	auto stmt = db.prepare(
		"INSERT INTO sync_meta (repo_id, last_sync, issues_updated_at, prs_updated_at, discussions_cursor) " ~
		"VALUES (?1, datetime('now'), ?2, ?3, ?4) " ~
		"ON CONFLICT(repo_id) DO UPDATE SET last_sync=datetime('now'), " ~
		"issues_updated_at=COALESCE(?2, issues_updated_at), " ~
		"prs_updated_at=COALESCE(?3, prs_updated_at), " ~
		"discussions_cursor=COALESCE(?4, discussions_cursor)");
	stmt.bind(1, repoId);
	stmt.bind(2, issuesUpdatedAt);
	stmt.bind(3, prsUpdatedAt);
	stmt.bind(4, discussionsCursor);
	stmt.execute();
	stmt.reset();
}

void getSyncWatermarks(Database db, long repoId, out string issuesUpdatedAt, out string prsUpdatedAt, out string discussionsCursor) {
	auto stmt = db.prepare("SELECT issues_updated_at, prs_updated_at, discussions_cursor FROM sync_meta WHERE repo_id=?1");
	stmt.bind(1, repoId);
	foreach (row; stmt.execute()) {
		issuesUpdatedAt = row.peek!string(0);
		prsUpdatedAt = row.peek!string(1);
		discussionsCursor = row.peek!string(2);
		break;
	}
	stmt.reset();
}
