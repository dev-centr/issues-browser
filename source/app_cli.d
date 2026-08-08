#!/usr/bin/env rdmd
/** CLI for issues-browser: discover repos/archives, sync issues+discussions, list and search. */
module app_cli;

import std.stdio;
import std.getopt;
import std.path;
import std.file;
import std.string;
import std.algorithm;
import std.array;
import issuesbrowser;
import d2sqlite3;

void main(string[] args) {
	string addFolder;
	string listRepos;
	string searchQuery;
	string syncPath;
	string findDbPath;
	bool force;
	bool noDiscussions;
	bool includePrs;
	bool help;

	getopt(args,
		"add-folder", &addFolder,
		"list", &listRepos,
		"search", &searchQuery,
		"sync", &syncPath,
		"find-db", &findDbPath,
		"yes|y", &force,
		"no-discussions", &noDiscussions,
		"include-prs", &includePrs,
		"help|h", &help
	);

	if (help || args.length == 1) {
		writeln("issues-browser CLI");
		writeln("  --add-folder <path>     Discover git repos under path");
		writeln("  --find-db <path>        Find **/\\.issues/database.sqlite under path");
		writeln("  --sync <path>           Sync repo(s): path to repo or parent folder");
		writeln("  --yes / -y              Allow large or fork syncs without prompt");
		writeln("  --no-discussions        Skip GitHub Discussions");
		writeln("  --include-prs           Include pull requests from issues API");
		writeln("  --list <path>           List issues from <repo>/.issues/database.sqlite");
		writeln("  --search <query>        Search issues (with --list)");
		return;
	}

	if (addFolder.length > 0) {
		auto repos = discoverRepos(addFolder);
		writeln("Discovered ", repos.length, " repo(s):");
		foreach (r; repos)
			writeln("  ", r.path, "  ", r.host.length ? r.host ~ "/" : "", r.owner, "/", r.name);
		return;
	}

	if (findDbPath.length > 0) {
		auto dbs = discoverDatabases(findDbPath);
		writeln("Found ", dbs.length, " archive(s):");
		foreach (p; dbs) writeln("  ", p);
		return;
	}

	if (syncPath.length > 0) {
		SyncOptions opt;
		opt.force = force;
		opt.includeDiscussions = !noDiscussions;
		opt.includePrs = includePrs;

		if (!(exists(syncPath) && isDir(syncPath))) {
			writeln("Path not found: ", syncPath);
			return;
		}
		auto repos = discoverRepos(syncPath);
		if (repos.length == 0) {
			auto gitPath = buildPath(syncPath, ".git");
			if (exists(gitPath)) {
				RepoInfo info;
				info.path = syncPath;
				getRemoteAndName(syncPath, info);
				repos ~= info;
			} else {
				writeln("No git repos found.");
				return;
			}
		}
		foreach (r; repos) {
			writeln("Syncing ", r.owner, "/", r.name, " ...");
			auto res = syncRepo(r.path, opt);
			writeln(res.message);
			if (res.skipped && !force) {
				stderr.writeln("Hint: pass --yes to confirm large/fork syncs.");
			}
		}
		writeln("Done.");
		return;
	}

	if (listRepos.length > 0) {
		string dbPath;
		if (exists(listRepos) && isDir(listRepos)) {
			dbPath = databasePath(listRepos);
		} else if (exists(listRepos) && isFile(listRepos)) {
			dbPath = listRepos;
		} else {
			writeln("Path not found: ", listRepos);
			return;
		}
		if (!exists(dbPath)) {
			writeln("No DB at ", dbPath, ". Run --sync first.");
			return;
		}
		Database db = Database(dbPath);
		string sql = "SELECT number, title, state FROM issues ORDER BY number DESC";
		if (searchQuery.length > 0) {
			string q = searchQuery.replace("'", "''");
			sql = "SELECT number, title, state FROM issues WHERE (title LIKE '%" ~ q ~
				"%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		}
		writeln("Issues:");
		foreach (row; db.execute(sql))
			writeln("#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		writeln("Discussions:");
		string dsql = "SELECT number, title, category FROM discussions ORDER BY number DESC";
		if (searchQuery.length > 0) {
			string q = searchQuery.replace("'", "''");
			dsql = "SELECT number, title, category FROM discussions WHERE (title LIKE '%" ~ q ~
				"%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		}
		foreach (row; db.execute(dsql))
			writeln("D#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		return;
	}

	if (searchQuery.length > 0)
		writeln("Use --list <repo> with --search <query>.");
}
