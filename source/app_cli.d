#!/usr/bin/env rdmd
/** CLI for issues-browser: discover repos, sync issues/discussions, list and search. */
module app_cli;

import std.stdio;
import std.getopt;
import std.path;
import std.file;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import issuesbrowser.gitdiscover;
import issuesbrowser.sync;
import issuesbrowser.database;
import issuesbrowser.types;
import d2sqlite3;

void main(string[] args) {
	string addFolder;
	string listRepos;
	string searchQuery;
	string syncPath;
	string findDbRoot;
	bool help;
	bool yes;
	bool noDiscussions;
	bool includePrs;

	getopt(args,
		"add-folder", &addFolder,
		"list", &listRepos,
		"search", &searchQuery,
		"sync", &syncPath,
		"find-dbs", &findDbRoot,
		"yes|y", &yes,
		"no-discussions", &noDiscussions,
		"include-prs", &includePrs,
		"help", &help
	);

	if (help || args.length == 1) {
		writeln("issues-browser CLI");
		writeln("  --add-folder <path>     Discover git repos under path");
		writeln("  --find-dbs <path>       Find **/.issues/database.sqlite archives");
		writeln("  --sync <path>           Sync repo(s): path to repo or parent folder");
		writeln("  --yes                   Approve large/fork syncs without prompting");
		writeln("  --no-discussions        Skip GitHub Discussions");
		writeln("  --include-prs           Include pull requests in issue sync");
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

	if (findDbRoot.length > 0) {
		auto dbs = discoverIssueDatabases(findDbRoot);
		writeln("Found ", dbs.length, " archive(s):");
		foreach (db; dbs)
			writeln("  ", db);
		return;
	}

	if (syncPath.length > 0) {
		SyncOptions opts;
		opts.force = yes;
		opts.includeDiscussions = !noDiscussions;
		opts.includePrs = includePrs;
		opts.confirm = &cliConfirm;

		if (exists(syncPath) && isDir(syncPath)) {
			auto repos = discoverRepos(syncPath);
			if (repos.length == 0) {
				auto gitPath = buildPath(syncPath, ".git");
				if (exists(gitPath)) {
					RepoInfo info;
					info.path = syncPath;
					getRemoteAndName(syncPath, info);
					string rname = info.name.length > 0 ? info.name : baseName(syncPath);
					writeln("Syncing ", rname, " ...");
					if (syncRepo(syncPath, opts))
						writeln("Done. DB: ", databasePath(syncPath));
				} else
					writeln("No git repos found.");
			} else {
				foreach (r; repos) {
					writeln("Syncing ", r.name, " ...");
					syncRepo(r.path, opts);
				}
				writeln("Done.");
			}
		}
		return;
	}

	if (listRepos.length > 0) {
		string repoPath = listRepos;
		string dbPath;
		if (exists(listRepos) && isDir(listRepos)) {
			dbPath = databasePath(listRepos);
			migrateLegacyDbIfNeeded(listRepos, baseName(listRepos));
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
			sql = "SELECT number, title, state FROM issues WHERE (title LIKE '%" ~ q ~ "%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		}
		writeln("Issues:");
		foreach (row; db.execute(sql))
			writeln("#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		writeln("Discussions:");
		string dsql = "SELECT number, title, category FROM discussions ORDER BY number DESC";
		if (searchQuery.length > 0) {
			string q = searchQuery.replace("'", "''");
			dsql = "SELECT number, title, category FROM discussions WHERE (title LIKE '%" ~ q ~ "%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		}
		foreach (row; db.execute(dsql))
			writeln("D#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		return;
	}

	if (searchQuery.length > 0 && listRepos.length == 0) {
		writeln("Use --list <repo> with --search <query>.");
	}
}

bool cliConfirm(string message) {
	stderr.writeln(message);
	stderr.write("Continue sync? [y/N] ");
	stderr.flush();
	auto line = readln();
	if (line is null) return false;
	line = line.strip().toLower;
	return line == "y" || line == "yes";
}
