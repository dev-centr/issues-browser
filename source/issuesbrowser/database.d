module issuesbrowser.database;

import std.file;
import std.path;
import std.string;
import d2sqlite3;

/// Relative marker path used for recursive discovery.
enum string dbFileName = "database.sqlite";
enum string issuesDirName = ".issues";

/// `<repo>/.issues`
string issuesDir(string repoPath) {
	return buildPath(repoPath, issuesDirName);
}

/// `<repo>/.issues/database.sqlite`
string databasePath(string repoPath) {
	return buildPath(issuesDir(repoPath), dbFileName);
}

/// Open or create the SQLite DB at `<repo>/.issues/database.sqlite`.
Database openDb(string repoPath) {
	auto dir = issuesDir(repoPath);
	if (!exists(dir))
		mkdir(dir);
	return Database(databasePath(repoPath));
}

/// Ensure `.issues/` is gitignored in the target repo (with a short comment).
void ensureRepoGitignore(string repoPath) {
	auto giPath = buildPath(repoPath, ".gitignore");
	string content;
	if (exists(giPath))
		content = readText(giPath);
	foreach (line; content.splitLines) {
		auto t = line.strip;
		if (t == ".issues/" || t == ".issues" || t == "**/.issues/" || t.startsWith(".issues/"))
			return;
	}
	auto block =
		"\n# Local issues-browser archive (issues + discussions SQLite; do not commit)\n" ~
		".issues/\n";
	if (content.length > 0 && !content.endsWith("\n"))
		content ~= "\n";
	content ~= block;
	std.file.write(giPath, content);
}

/// Migrate legacy `parent/.issues/<reponame>.sqlite` → `<repo>/.issues/database.sqlite`.
void migrateLegacyDbIfNeeded(string repoPath, string repoName) {
	auto neu = databasePath(repoPath);
	if (exists(neu))
		return;
	auto legacy = buildPath(dirName(repoPath), ".issues", repoName ~ ".sqlite");
	if (!exists(legacy))
		return;
	auto dir = issuesDir(repoPath);
	if (!exists(dir))
		mkdir(dir);
	rename(legacy, neu);
}

/// Ensure schema exists.
void initSchema(Database db) {
	db.run(
		"CREATE TABLE IF NOT EXISTS repos (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  path TEXT UNIQUE NOT NULL," ~
		"  remote TEXT," ~
		"  owner TEXT," ~
		"  name TEXT NOT NULL," ~
		"  host TEXT," ~
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
		"CREATE TABLE IF NOT EXISTS sync_meta (" ~
		"  repo_id INTEGER PRIMARY KEY REFERENCES repos(id)," ~
		"  last_sync TEXT" ~
		")"
	);
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_repo ON issues(repo_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_issues_state ON issues(state)");
	db.run("CREATE INDEX IF NOT EXISTS idx_comments_issue ON comments(issue_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_discussions_repo ON discussions(repo_id)");
	db.run("CREATE INDEX IF NOT EXISTS idx_discussion_comments ON discussion_comments(discussion_id)");
}

long upsertRepo(Database db, string path, string remote, string owner, string name, string host) {
	auto stmt = db.prepare(
		"INSERT INTO repos (path, remote, owner, name, host, updated_at) VALUES (?1,?2,?3,?4,?5,datetime('now')) " ~
		"ON CONFLICT(path) DO UPDATE SET remote=?2, owner=?3, name=?4, host=?5, updated_at=datetime('now')");
	stmt.bind(1, path);
	stmt.bind(2, remote);
	stmt.bind(3, owner);
	stmt.bind(4, name);
	stmt.bind(5, host);
	stmt.execute();
	stmt.reset();
	auto sel = db.prepare("SELECT id FROM repos WHERE path=?1");
	sel.bind(1, path);
	long id = -1;
	foreach (row; sel.execute()) { id = row.peek!long(0); break; }
	sel.reset();
	return id;
}

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

void setLastSync(Database db, long repoId) {
	auto stmt = db.prepare("INSERT INTO sync_meta (repo_id, last_sync) VALUES (?1, datetime('now')) " ~
		"ON CONFLICT(repo_id) DO UPDATE SET last_sync=datetime('now')");
	stmt.bind(1, repoId);
	stmt.execute();
	stmt.reset();
}
