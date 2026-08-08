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
import issuesbrowser.index;
import issuesbrowser.ipc;
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
	string setBackup;
	string setIndexOnly;
	string openRepo;
	string openHost = "github.com";
	bool monitorList;
	bool help;
	bool yes;
	bool noDiscussions;
	bool noPrs;
	bool backupMode;
	bool indexOnly;
	bool migrateBackupFlags;

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
		"set-backup", &setBackup,
		"set-index-only", &setIndexOnly,
		"open-repo", &openRepo,
		"host", &openHost,
		"backup", &backupMode,
		"index-only", &indexOnly,
		"migrate-backup-flags", &migrateBackupFlags,
		"yes|y", &yes,
		"no-discussions", &noDiscussions,
		"no-prs", &noPrs,
		"help", &help
	);

	auto root = archiveRoot(archiveRootOpt);
	loadForgeProfiles(root);

	if (migrateBackupFlags) {
		migrateArchivesAsBackup(root);
		writeln("Migrated existing archives to backup=true in monitor.sdl");
		return;
	}

	if (help || args.length == 1) {
		writeln("issues-browser — forge metadata index + opt-in backup");
		writeln("  Archive root: ", root);
		writeln("  --sync <path>           Sync (default: index cache; use --backup for full archive)");
		writeln("  --backup                Full backup mode for --sync / --monitor-add");
		writeln("  --index-only            Force index-only sync");
		writeln("  --set-backup <slug>     Enable full backup for a monitored repo");
		writeln("  --set-index-only <slug> Disable backup (keep index)");
		writeln("  --open-repo <owner/name> Queue GUI open (writes pending-open.json)");
		writeln("  --list <path|owner/name> List issues/PRs/discussions from backup DB");
		writeln("  --search <query>        Search (with --list)");
		writeln("  --monitor-add <slug>    Add monitored repo (index by default)");
		writeln("  --monitor-remove <slug> Remove monitored repo");
		writeln("  --monitor-list          List monitored repos (shows mode)");
		writeln("  --migrate-backup-flags  Mark existing archive DBs as backup-enabled");
		writeln("  --find-dbs [path]       Find database.sqlite archives");
		writeln("  --root <path>           Override archive root");
		writeln("  --yes                   Approve large/fork backup syncs");
		writeln("  --no-prs                Exclude pull requests");
		writeln("  --no-discussions        Skip discussions");
		writeln("  ?                       ProHelp progressive help");
		return;
	}

	if (openRepo.length) {
		string host = openHost, owner, name, remote;
		if (!parseRemoteOrSlug(openRepo, host, owner, name, remote)) {
			// allow owner/name with --host
			auto slash = openRepo.indexOf("/");
			if (slash > 0) {
				owner = openRepo[0 .. slash];
				name = openRepo[slash + 1 .. $];
				host = openHost;
			}
		}
		if (queueOpenRepo(host, owner, name, root))
			writeln("Opened/queued ", host, "/", owner, "/", name);
		else
			writeln("Failed to open ", openRepo);
		return;
	}

	if (setBackup.length) {
		if (setBackupMode(setBackup, true, root))
			writeln("Backup enabled for ", setBackup);
		else
			writeln("Failed: ", setBackup);
		return;
	}
	if (setIndexOnly.length) {
		if (setBackupMode(setIndexOnly, false, root))
			writeln("Index-only for ", setIndexOnly);
		else
			writeln("Failed: ", setIndexOnly);
		return;
	}

	if (monitorList) {
		foreach (m; loadMonitorList(root))
			writeln((m.enabled ? "[on] " : "[off] "),
				(m.backup ? "[backup] " : "[index] "),
				m.host, "/", m.owner, "/", m.name,
				" interval=", m.pollIntervalSec, "s");
		return;
	}
	if (monitorAdd.length) {
		if (addMonitored(monitorAdd, root, 300, backupMode && !indexOnly))
			writeln("Monitoring ", monitorAdd, backupMode && !indexOnly ? " (backup)" : " (index)");
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
		opts.mode = (backupMode && !indexOnly) ? RepoSyncMode.backup : RepoSyncMode.index;
		opts.confirm = (string msg) { return cliConfirm(msg); };

		if (exists(syncPath) && isDir(syncPath)) {
			auto repos = discoverRepos(syncPath);
			if (repos.length == 0) {
				auto gitPath = buildPath(syncPath, ".git");
				if (exists(gitPath)) {
					writeln("Syncing ", syncPath, " (", opts.mode == RepoSyncMode.backup ? "backup" : "index", ") ...");
					if (syncRepo(syncPath, opts)) {
						RepoInfo info; info.path = syncPath; getRemoteAndName(syncPath, info);
						if (opts.mode == RepoSyncMode.backup)
							writeln("Done. DB: ", databasePath(info.host, info.owner, info.name, root));
						else
							writeln("Done. Index: ", indexDbPath(root));
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
				writeln("Syncing ", info.owner, "/", info.name, " (", opts.mode == RepoSyncMode.backup ? "backup" : "index", ") ...");
				if (syncRepoInfo(info, opts)) {
					if (opts.mode == RepoSyncMode.backup)
						writeln("Done. DB: ", databasePath(info.host, info.owner, info.name, root));
					else
						writeln("Done. Index: ", indexDbPath(root));
				}
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
