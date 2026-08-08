#!/usr/bin/env rdmd
/** CLI for issues-browser: forge metadata backup with ProHelp. */
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
import issuesbrowser.paths;
import issuesbrowser.monitor;
import issuesbrowser.profiles;
import d2sqlite3;

import issuesbrowser.prohelpcompat;

void main(string[] args) {
	// ProHelp-compatible intercept (help.sdl). Swap to openshellorg/prohelp when DMD/LDC builds it here.
	if (intercept(args))
		return;

	string addFolder;
	string listRepos;
	string searchQuery;
	string syncPath;
	string findDbRoot;
	string archiveRootOpt;
	string monitorAdd;
	string monitorRemove;
	bool monitorList;
	bool help;
	bool yes;
	bool noDiscussions;
	bool noPrs;

	getopt(args,
		"add-folder", &addFolder,
		"list", &listRepos,
		"search", &searchQuery,
		"sync", &syncPath,
		"find-dbs", &findDbRoot,
		"root", &archiveRootOpt,
		"monitor-add", &monitorAdd,
		"monitor-remove", &monitorRemove,
		"monitor-list", &monitorList,
		"yes|y", &yes,
		"no-discussions", &noDiscussions,
		"no-prs", &noPrs,
		"help", &help
	);

	auto root = archiveRoot(archiveRootOpt);
	loadForgeProfiles(root);

	if (help || args.length == 1) {
		writeln("issues-browser — forge metadata backup");
		writeln("  Archive root: ", root);
		writeln("  --sync <path>           Sync repo(s) into archives/<host>/<owner>/<repo>/");
		writeln("  --list <path|owner/name> List issues/PRs/discussions");
		writeln("  --search <query>        Search (with --list)");
		writeln("  --monitor-add <owner/name>  Add monitored repo");
		writeln("  --monitor-remove <slug> Remove monitored repo");
		writeln("  --monitor-list          List monitored repos");
		writeln("  --find-dbs [path]       Find database.sqlite archives");
		writeln("  --root <path>           Override archive root");
		writeln("  --yes                   Approve large/fork syncs");
		writeln("  --no-prs                Exclude pull requests");
		writeln("  --no-discussions        Skip discussions");
		writeln("  ?                       ProHelp progressive help");
		return;
	}

	if (monitorList) {
		foreach (m; loadMonitorList(root))
			writeln((m.enabled ? "[on] " : "[off] "), m.host, "/", m.owner, "/", m.name,
				" interval=", m.pollIntervalSec, "s");
		return;
	}
	if (monitorAdd.length) {
		if (addMonitored(monitorAdd, root))
			writeln("Monitoring ", monitorAdd);
		else
			writeln("Failed to parse repo: ", monitorAdd);
		return;
	}
	if (monitorRemove.length) {
		if (removeMonitored(monitorRemove, root))
			writeln("Removed ", monitorRemove);
		else
			writeln("Not found: ", monitorRemove);
		return;
	}

	if (addFolder.length > 0) {
		auto repos = discoverRepos(addFolder);
		writeln("Discovered ", repos.length, " repo(s):");
		foreach (r; repos)
			writeln("  ", r.path, "  ", r.host.length ? r.host ~ "/" : "", r.owner, "/", r.name);
		return;
	}

	if (findDbRoot.length > 0 || (args.length > 1 && args[1] == "--find-dbs")) {
		auto search = findDbRoot.length ? findDbRoot : root;
		auto dbs = discoverIssueDatabases(search);
		writeln("Found ", dbs.length, " archive(s):");
		foreach (db; dbs) writeln("  ", db);
		return;
	}

	if (syncPath.length > 0) {
		SyncOptions opts;
		opts.force = yes;
		opts.includeDiscussions = !noDiscussions;
		opts.includePrs = !noPrs;
		opts.archiveRoot = root;
		opts.confirm = (string msg) { return cliConfirm(msg); };

		if (exists(syncPath) && isDir(syncPath)) {
			auto repos = discoverRepos(syncPath);
			if (repos.length == 0) {
				auto gitPath = buildPath(syncPath, ".git");
				if (exists(gitPath)) {
					writeln("Syncing ", syncPath, " ...");
					if (syncRepo(syncPath, opts)) {
						RepoInfo info; info.path = syncPath; getRemoteAndName(syncPath, info);
						writeln("Done. DB: ", databasePath(info.host, info.owner, info.name, root));
					}
				} else
					writeln("No git repos found.");
			} else {
				foreach (r; repos) {
					writeln("Syncing ", r.name, " ...");
					syncRepo(r.path, opts);
				}
				writeln("Done.");
			}
		} else if (syncPath.canFind("/")) {
			// owner/name without local path
			RepoInfo info;
			string remote;
			if (parseRemoteOrSlug(syncPath, info.host, info.owner, info.name, remote)) {
				info.remote = remote;
				writeln("Syncing ", info.owner, "/", info.name, " ...");
				if (syncRepoInfo(info, opts))
					writeln("Done. DB: ", databasePath(info.host, info.owner, info.name, root));
			} else
				writeln("Invalid path/slug: ", syncPath);
		}
		return;
	}

	if (listRepos.length > 0) {
		string host = "github.com", owner, name, remote, dbPath;
		if (exists(listRepos) && isDir(listRepos)) {
			RepoInfo info; info.path = listRepos; getRemoteAndName(listRepos, info);
			host = info.host.length ? info.host : "github.com";
			owner = info.owner; name = info.name;
			migrateLegacyDbIfNeeded(host, owner, name, listRepos, root);
			dbPath = databasePath(host, owner, name, root);
		} else if (parseRemoteOrSlug(listRepos, host, owner, name, remote)) {
			dbPath = databasePath(host, owner, name, root);
		} else {
			writeln("Path not found: ", listRepos);
			return;
		}
		if (!exists(dbPath)) {
			writeln("No DB at ", dbPath, ". Run --sync first.");
			return;
		}
		Database db = Database(dbPath);
		string q = searchQuery.replace("'", "''");
		writeln("Issues:");
		string sql = "SELECT number, title, state, is_pr FROM issues ORDER BY number DESC";
		if (q.length)
			sql = "SELECT number, title, state, is_pr FROM issues WHERE (title LIKE '%" ~ q ~ "%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		foreach (row; db.execute(sql)) {
			auto prefix = row.peek!int(3) ? "PR#" : "#";
			writeln(prefix, row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		}
		writeln("Pull requests:");
		string psql = "SELECT number, title, state, merged FROM pull_requests ORDER BY number DESC";
		if (q.length)
			psql = "SELECT number, title, state, merged FROM pull_requests WHERE (title LIKE '%" ~ q ~ "%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		foreach (row; db.execute(psql))
			writeln("PR#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]", row.peek!int(3) ? " merged" : "");
		writeln("Discussions:");
		string dsql = "SELECT number, title, category FROM discussions ORDER BY number DESC";
		if (q.length)
			dsql = "SELECT number, title, category FROM discussions WHERE (title LIKE '%" ~ q ~ "%' OR body LIKE '%" ~ q ~ "%') ORDER BY number DESC";
		foreach (row; db.execute(dsql))
			writeln("D#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		return;
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
