#!/usr/bin/env rdmd
/** CLI for issue-tracker: discover repos, sync issues/comments, list and search. */
module app_cli;

import std.stdio;
import std.getopt;
import std.path;
import std.file;
import std.string;
import std.algorithm;
import std.array;
import issuetracker.gitdiscover;
import issuetracker.sync;
import issuetracker.database;
import issuetracker.types;
import d2sqlite3;

void main(string[] args) {
	string addFolder;
	string listRepos;
	string searchQuery;
	string syncPath;
	bool help;

	getopt(args,
		"add-folder", &addFolder,
		"list", &listRepos,
		"search", &searchQuery,
		"sync", &syncPath,
		"help", &help
	);

	if (help || args.length == 1) {
		writeln("issue-tracker CLI");
		writeln("  --add-folder <path>   Discover repos and show list");
		writeln("  --sync <path>         Sync repo(s): path to repo or parent folder");
		writeln("  --list <path|owner/name>  List issues from DB");
		writeln("  --search <query>      Search issues (requires --list context)");
		return;
	}

	if (addFolder.length > 0) {
		auto repos = discoverRepos(addFolder);
		writeln("Discovered ", repos.length, " repo(s):");
		foreach (r; repos)
			writeln("  ", r.path, "  ", r.owner, "/", r.name);
		return;
	}

	if (syncPath.length > 0) {
		if (exists(syncPath) && isDir(syncPath)) {
			auto repos = discoverRepos(syncPath);
			if (repos.length == 0) {
				// Single repo?
				auto gitPath = buildPath(syncPath, ".git");
				if (exists(gitPath)) {
					RepoInfo info;
					info.path = syncPath;
					getRemoteAndName(syncPath, info);
					string parentDir = dirName(syncPath);
					string rname = info.name.length > 0 ? info.name : baseName(syncPath);
					writeln("Syncing ", rname, " ...");
					syncRepo(syncPath, parentDir, rname);
					writeln("Done.");
				} else
					writeln("No git repos found.");
			} else {
				foreach (r; repos) {
					string parentDir = dirName(r.path);
					writeln("Syncing ", r.name, " ...");
					syncRepo(r.path, parentDir, r.name);
				}
				writeln("Done.");
			}
		}
		return;
	}

	if (listRepos.length > 0) {
		string parentDir, repoName;
		if (canFind(listRepos, "/") && !exists(listRepos)) {
			auto parts = split(listRepos, "/");
			if (parts.length >= 2) {
				repoName = parts[1];
				parentDir = "."; // current dir .issues
			}
		} else {
			parentDir = dirName(listRepos);
			RepoInfo info;
			info.path = listRepos;
			getRemoteAndName(listRepos, info);
			repoName = info.name.length > 0 ? info.name : baseName(listRepos);
		}
		auto dbPath = buildPath(parentDir, ".issues", repoName ~ ".sqlite");
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
		foreach (row; db.execute(sql))
			writeln("#", row.peek!int(0), " ", row.peek!string(1), " [", row.peek!string(2), "]");
		return;
	}

	if (searchQuery.length > 0 && listRepos.length == 0) {
		writeln("Use --list <repo> with --search <query>.");
	}
}
