module issuesbrowser.index;

import std.file;
import std.path;
import std.string;
import std.conv;
import std.datetime;
import d2sqlite3;
import issuesbrowser.paths;
import issuesbrowser.types;

/// Open cross-repo lightweight index DB.
Database openIndexDb(string root = null) {
	auto dir = indexDir(root);
	mkdirRecurse(dir);
	return Database(indexDbPath(root));
}

void initIndexSchema(Database db) {
	db.run(
		"CREATE TABLE IF NOT EXISTS repos (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  host TEXT," ~
		"  owner TEXT," ~
		"  name TEXT NOT NULL," ~
		"  remote TEXT," ~
		"  backup INTEGER DEFAULT 0," ~
		"  updated_at TEXT," ~
		"  UNIQUE(host, owner, name)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS issue_stubs (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  repo_id INTEGER NOT NULL REFERENCES repos(id)," ~
		"  number INTEGER NOT NULL," ~
		"  title TEXT," ~
		"  state TEXT," ~
		"  url TEXT," ~
		"  updated_at TEXT," ~
		"  is_pr INTEGER DEFAULT 0," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS pr_stubs (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  repo_id INTEGER NOT NULL REFERENCES repos(id)," ~
		"  number INTEGER NOT NULL," ~
		"  title TEXT," ~
		"  state TEXT," ~
		"  url TEXT," ~
		"  updated_at TEXT," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS discussion_stubs (" ~
		"  id INTEGER PRIMARY KEY AUTOINCREMENT," ~
		"  repo_id INTEGER NOT NULL REFERENCES repos(id)," ~
		"  number INTEGER NOT NULL," ~
		"  title TEXT," ~
		"  url TEXT," ~
		"  updated_at TEXT," ~
		"  UNIQUE(repo_id, number)" ~
		")"
	);
	db.run(
		"CREATE TABLE IF NOT EXISTS index_meta (" ~
		"  repo_id INTEGER PRIMARY KEY REFERENCES repos(id)," ~
		"  etag TEXT," ~
		"  cursor TEXT," ~
		"  last_index_at TEXT" ~
		")"
	);
}

long upsertIndexRepo(Database db, string host, string owner, string name, string remote, bool backup) {
	db.execute(
		"INSERT INTO repos (host, owner, name, remote, backup, updated_at) VALUES (?, ?, ?, ?, ?, ?) " ~
		"ON CONFLICT(host, owner, name) DO UPDATE SET remote=excluded.remote, backup=excluded.backup, updated_at=excluded.updated_at",
		host, owner, name, remote, backup ? 1 : 0, Clock.currTime.toISOExtString()
	);
	auto rows = db.execute("SELECT id FROM repos WHERE host=? AND owner=? AND name=?", host, owner, name);
	foreach (row; rows)
		return row.peek!long(0);
	return 0;
}

void upsertIssueStub(Database db, long repoId, int number, string title, string state, string url, string updatedAt, bool isPr) {
	db.execute(
		"INSERT INTO issue_stubs (repo_id, number, title, state, url, updated_at, is_pr) VALUES (?,?,?,?,?,?,?) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=excluded.title, state=excluded.state, url=excluded.url, " ~
		"updated_at=excluded.updated_at, is_pr=excluded.is_pr",
		repoId, number, title, state, url, updatedAt, isPr ? 1 : 0
	);
}

void upsertPrStub(Database db, long repoId, int number, string title, string state, string url, string updatedAt) {
	db.execute(
		"INSERT INTO pr_stubs (repo_id, number, title, state, url, updated_at) VALUES (?,?,?,?,?,?) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=excluded.title, state=excluded.state, url=excluded.url, updated_at=excluded.updated_at",
		repoId, number, title, state, url, updatedAt
	);
}

void upsertDiscussionStub(Database db, long repoId, int number, string title, string url, string updatedAt) {
	db.execute(
		"INSERT INTO discussion_stubs (repo_id, number, title, url, updated_at) VALUES (?,?,?,?,?) " ~
		"ON CONFLICT(repo_id, number) DO UPDATE SET title=excluded.title, url=excluded.url, updated_at=excluded.updated_at",
		repoId, number, title, url, updatedAt
	);
}

void touchIndexMeta(Database db, long repoId) {
	db.execute(
		"INSERT INTO index_meta (repo_id, last_index_at) VALUES (?, ?) " ~
		"ON CONFLICT(repo_id) DO UPDATE SET last_index_at=excluded.last_index_at",
		repoId, Clock.currTime.toISOExtString()
	);
}

bool indexHasRepo(string host, string owner, string name, string root = null) {
	if (!exists(indexDbPath(root))) return false;
	auto db = openIndexDb(root);
	initIndexSchema(db);
	foreach (row; db.execute("SELECT 1 FROM repos WHERE host=? AND owner=? AND name=? LIMIT 1", host, owner, name))
		return true;
	return false;
}

bool backupPresent(string host, string owner, string name, string root = null) {
	return exists(databasePath(host, owner, name, root));
}

/// Public helper for RepoDrive / other consumers.
string repoModeLabel(string host, string owner, string name, string root = null) {
	if (backupPresent(host, owner, name, root)) return "backup";
	if (indexHasRepo(host, owner, name, root)) return "index";
	return "none";
}
