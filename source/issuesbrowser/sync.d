module issuesbrowser.sync;

import std.process;
import std.stdio;
import std.json;
import std.conv;
import std.string;
import std.algorithm;
import std.path;
import std.array;
import std.datetime;
import core.thread;
import d2sqlite3;
import issuesbrowser.types;
import issuesbrowser.database;
import issuesbrowser.gitdiscover;
import issuesbrowser.paths;
import issuesbrowser.profiles;
import issuesbrowser.index;

private long gLastApiMs;

/// Sync forge metadata for a local git repo path into the central archive.
bool syncRepo(string repoPath, SyncOptions opts = SyncOptions.init) {
	RepoInfo info;
	info.path = repoPath;
	getRemoteAndName(repoPath, info);
	return syncRepoInfo(info, opts);
}

/// Sync by owner/name/host (no local clone required).
bool syncRepoInfo(RepoInfo info, SyncOptions opts = SyncOptions.init) {
	if (info.owner.length == 0 || info.name.length == 0) {
		stderr.writeln("Cannot determine owner/name");
		return false;
	}
	if (info.host.length == 0) info.host = "github.com";

	loadForgeProfiles(opts.archiveRoot);
	auto forge = resolveForge(info.host);
	if (forge.name != "github") {
		stderr.writeln("Sync implementation currently complete for github; profile '", forge.name, "' is stubbed.");
		return false;
	}

	// Always refresh lightweight index first
	if (!syncIndexOnly(info, opts))
		stderr.writeln("Index sync warning for ", info.owner, "/", info.name);

	if (opts.mode != RepoSyncMode.backup)
		return true;

	auto pre = preflight(info);
	if (!approveSync(pre, opts)) {
		stderr.writeln("Backup sync cancelled for ", info.owner, "/", info.name);
		return false;
	}

	migrateLegacyDbIfNeeded(info.host, info.owner, info.name, info.path, opts.archiveRoot);
	auto db = openDb(info.host, info.owner, info.name, opts.archiveRoot);
	initSchema(db);
	long repoId = upsertRepo(db, info.path, info.remote, info.owner, info.name, info.host);

	string issuesWm, prsWm, discCursor;
	getSyncWatermarks(db, repoId, issuesWm, prsWm, discCursor);

	string maxIssueUpdated = issuesWm;
	syncIssuesAndComments(db, repoId, info, forge, opts.includePrs, issuesWm, maxIssueUpdated);

	string maxPrUpdated = prsWm;
	if (opts.includePrs)
		syncPullRequests(db, repoId, info, forge, prsWm, maxPrUpdated);

	if (opts.includeDiscussions)
		syncDiscussions(db, repoId, info, forge);

	setLastSync(db, repoId, maxIssueUpdated.length ? maxIssueUpdated : null,
		maxPrUpdated.length ? maxPrUpdated : null, null);
	return true;
}

SyncPreflight preflight(RepoInfo info) {
	SyncPreflight p;
	string q =
		"query($owner:String!,$name:String!){" ~
		"repository(owner:$owner,name:$name){" ~
		"isFork parent{nameWithOwner} " ~
		"issues{totalCount} pullRequests{totalCount} discussions{totalCount}" ~
		"}}";
	auto raw = runCli("gh", ["api", "graphql", "-f", "query=" ~ q, "-F", "owner=" ~ info.owner, "-F", "name=" ~ info.name], 60);
	if (raw.length == 0) {
		p.summaryMessage = "Could not query repository size via GraphQL; proceeding with caution.";
		p.needsConfirm = true;
		return p;
	}
	try {
		auto root = parseJSON(raw);
		auto repo = root["data"]["repository"];
		if (repo.type == JSONType.null_) {
			p.summaryMessage = "Repository not found or inaccessible.";
			p.needsConfirm = true;
			return p;
		}
		p.isFork = repo["isFork"].boolean;
		p.issueCount = cast(int) repo["issues"]["totalCount"].integer;
		p.prCount = cast(int) repo["pullRequests"]["totalCount"].integer;
		p.discussionCount = cast(int) repo["discussions"]["totalCount"].integer;
		if ("parent" in repo && repo["parent"].type != JSONType.null_)
			p.parentNameWithOwner = repo["parent"]["nameWithOwner"].str;
	} catch (Exception e) {
		p.summaryMessage = "Failed to parse size preflight: " ~ e.msg;
		p.needsConfirm = true;
		return p;
	}
	int units = p.issueCount + p.discussionCount + p.prCount;
	p.summaryMessage = info.owner ~ "/" ~ info.name ~
		": " ~ to!string(p.issueCount) ~ " issues, " ~
		to!string(p.prCount) ~ " PRs, " ~
		to!string(p.discussionCount) ~ " discussions";
	if (p.isFork) {
		p.summaryMessage ~= " (FORK";
		if (p.parentNameWithOwner.length)
			p.summaryMessage ~= " of " ~ p.parentNameWithOwner;
		p.summaryMessage ~= ")";
	}
	return p;
}

bool approveSync(SyncPreflight pre, SyncOptions opts) {
	int units = pre.issueCount + pre.discussionCount + pre.prCount;
	bool large = units >= opts.warnThreshold;
	bool huge = units >= opts.requireConfirmThreshold;
	bool forkRisk = pre.isFork && units >= opts.warnThreshold;
	if (!large && !forkRisk && !pre.needsConfirm)
		return true;
	string msg = pre.summaryMessage;
	if (huge)
		msg ~= "\nLarge archive (>= " ~ to!string(opts.requireConfirmThreshold) ~ " items).";
	else if (large)
		msg ~= "\n>= " ~ to!string(opts.warnThreshold) ~ " items; confirm before downloading.";
	if (forkRisk)
		msg ~= "\nFork of a busy upstream — confirm intentional full backup.";
	if (opts.force) return true;
	if (opts.confirm is null) {
		stderr.writeln(msg);
		stderr.writeln("Pass --yes to approve non-interactive sync.");
		return false;
	}
	return opts.confirm(msg);
}

/// Lightweight index-only sync (titles/states/urls; no comment bodies).
bool syncIndexOnly(RepoInfo info, SyncOptions opts = SyncOptions.init) {
	if (info.host.length == 0) info.host = "github.com";
	loadForgeProfiles(opts.archiveRoot);
	auto forge = resolveForge(info.host);
	if (forge.name != "github") {
		stderr.writeln("Index sync currently complete for github; profile '", forge.name, "' is stubbed.");
		return false;
	}
	auto idb = openIndexDb(opts.archiveRoot);
	initIndexSchema(idb);
	long repoId = upsertIndexRepo(idb, info.host, info.owner, info.name, info.remote, opts.mode == RepoSyncMode.backup);

	auto issueJson = runCli(forge.cli, interpolateCmd(forge.listIssuesCmd, info.owner, info.name, info.host, null), forge.on429BackoffS);
	if (issueJson.length) {
		try {
			auto arr = parseJSON(issueJson);
			if (arr.type == JSONType.array) {
				foreach (issue; arr.array) {
					bool isPr = ("pull_request" in issue) !is null;
					int num = issue["number"].integer.to!int;
					string title = issue["title"].str;
					string state = toUpper(issue["state"].str);
					string url = jsonStr(issue, "html_url");
					string updatedAt = jsonStr(issue, "updated_at");
					upsertIssueStub(idb, repoId, num, title, state, url, updatedAt, isPr);
				}
			}
		} catch (Exception e) {
			stderr.writeln("Index issues parse: ", e.msg);
		}
	}

	if (opts.includePrs) {
		auto prJson = runCli(forge.cli, interpolateCmd(forge.listPrsCmd, info.owner, info.name, info.host, null), forge.on429BackoffS);
		if (prJson.length) {
			try {
				auto arr = parseJSON(prJson);
				if (arr.type == JSONType.array) {
					foreach (pr; arr.array) {
						int num = pr["number"].integer.to!int;
						upsertPrStub(idb, repoId, num, pr["title"].str, toUpper(pr["state"].str),
							jsonStr(pr, "html_url"), jsonStr(pr, "updated_at"));
					}
				}
			} catch (Exception e) {
				stderr.writeln("Index PRs parse: ", e.msg);
			}
		}
	}

	if (opts.includeDiscussions) {
		// Minimal discussion stubs via GraphQL (numbers/titles/urls only)
		string q = "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){" ~
			"discussions(first:50){nodes{number title url updatedAt}}}}";
		auto raw = runCli("gh", ["api", "graphql", "-f", "query=" ~ q, "-F", "owner=" ~ info.owner, "-F", "name=" ~ info.name], 60);
		if (raw.length) {
			try {
				auto root = parseJSON(raw);
				auto nodes = root["data"]["repository"]["discussions"]["nodes"];
				foreach (d; nodes.array) {
					upsertDiscussionStub(idb, repoId, cast(int) d["number"].integer, d["title"].str,
						d["url"].str, ("updatedAt" in d) ? d["updatedAt"].str : "");
				}
			} catch (Exception) {}
		}
	}

	touchIndexMeta(idb, repoId);
	return true;
}

private void syncIssuesAndComments(Database db, long repoId, RepoInfo info, ForgeProfile forge,
	bool includePrsAsIssues, string since, ref string maxUpdated) {
	auto args = interpolateCmd(forge.listIssuesCmd, info.owner, info.name, info.host, since);
	auto issueJson = runCli(forge.cli, args, forge.on429BackoffS);
	if (issueJson.length == 0) return;
	JSONValue[] issues;
	try {
		auto arr = parseJSON(issueJson);
		if (arr.type == JSONType.array)
			foreach (e; arr.array) issues ~= e;
	} catch (Exception) { return; }

	foreach (issue; issues) {
		bool isPr = ("pull_request" in issue) !is null;
		if (isPr && !includePrsAsIssues) continue;
		int num = issue["number"].integer.to!int;
		string title = issue["title"].str;
		string state = toUpper(issue["state"].str);
		string body = jsonStr(issue, "body");
		string url = jsonStr(issue, "html_url");
		string createdAt = jsonStr(issue, "created_at");
		string closedAt = jsonStr(issue, "closed_at");
		string updatedAt = jsonStr(issue, "updated_at");
		string author = "";
		if ("user" in issue && issue["user"].type != JSONType.null_)
			author = issue["user"]["login"].str;
		bool prAccepted = false;
		string stateReason = "";
		if (state == "CLOSED" && !isPr) {
			auto timelineJson = runCli(forge.cli, [
				"api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues/" ~ to!string(num) ~ "/timeline"
			], forge.on429BackoffS);
			if (timelineJson.length) {
				try {
					foreach (ev; parseJSON(timelineJson).array) {
						if (ev["event"].str == "closed") {
							if ("commit_id" in ev && ev["commit_id"].type != JSONType.null_ && ev["commit_id"].str.length)
								prAccepted = true;
							if ("state_reason" in ev && ev["state_reason"].type != JSONType.null_)
								stateReason = ev["state_reason"].str;
							break;
						}
					}
				} catch (Exception) {}
			}
		}
		upsertIssue(db, repoId, num, title, state, body, url, createdAt, closedAt, author, prAccepted, stateReason, isPr, updatedAt);
		if (updatedAt > maxUpdated) maxUpdated = updatedAt;
		long issueId = getIssueId(db, repoId, num);
		deleteCommentsForIssue(db, issueId);
		auto commentsJson = runCli(forge.cli, [
			"api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues/" ~ to!string(num) ~ "/comments"
		], forge.on429BackoffS);
		if (commentsJson.length && commentsJson != "[]") {
			try {
				foreach (c; parseJSON(commentsJson).array) {
					insertComment(db, issueId,
						jsonStr(c, "body"),
						("user" in c && c["user"].type != JSONType.null_) ? c["user"]["login"].str : "",
						jsonStr(c, "created_at"));
				}
			} catch (Exception) {}
		}
	}
}

private void syncPullRequests(Database db, long repoId, RepoInfo info, ForgeProfile forge,
	string since, ref string maxUpdated) {
	auto args = interpolateCmd(forge.listPrsCmd, info.owner, info.name, info.host, since);
	auto raw = runCli(forge.cli, args, forge.on429BackoffS);
	if (raw.length == 0) return;
	try {
		auto arr = parseJSON(raw);
		if (arr.type != JSONType.array) return;
		foreach (pr; arr.array) {
			int num = cast(int) pr["number"].integer;
			string title = pr["title"].str;
			string state = toUpper(pr["state"].str);
			string body = jsonStr(pr, "body");
			string url = jsonStr(pr, "html_url");
			string createdAt = jsonStr(pr, "created_at");
			string closedAt = jsonStr(pr, "closed_at");
			string mergedAt = jsonStr(pr, "merged_at");
			string updatedAt = jsonStr(pr, "updated_at");
			string author = ("user" in pr && pr["user"].type != JSONType.null_) ? pr["user"]["login"].str : "";
			bool merged = mergedAt.length > 0;
			upsertPullRequest(db, repoId, num, title, state, body, url, createdAt, closedAt, mergedAt, updatedAt, author, merged);
			if (updatedAt > maxUpdated) maxUpdated = updatedAt;
			long prId = getPrId(db, repoId, num);
			if (body.length) {
				import std.regex;
				foreach (m; matchAll(body, regex(`#(\d+)`))) {
					try {
						int inum = to!int(m[1]);
						long iid = getIssueId(db, repoId, inum);
						linkIssuePr(db, iid, prId);
					} catch (Exception) {}
				}
			}
		}
	} catch (Exception) {}
}

private void syncDiscussions(Database db, long repoId, RepoInfo info, ForgeProfile forge) {
	if (!forge.graphql) return;
	string cursor;
	bool hasNext = true;
	while (hasNext) {
		string afterClause = cursor.length ? ", after: $after" : "";
		string varDecl = cursor.length ? ", $after:String" : "";
		string q =
			"query($owner:String!,$name:String!" ~ varDecl ~ "){" ~
			"repository(owner:$owner,name:$name){" ~
			"discussions(first:50" ~ afterClause ~ "){" ~
			"pageInfo{hasNextPage endCursor} " ~
			"nodes{number title body url createdAt author{login} category{name} " ~
			"comments(first:100){nodes{body createdAt author{login}}}}" ~
			"}}}";
		string[] args = ["api", "graphql", "-f", "query=" ~ q, "-F", "owner=" ~ info.owner, "-F", "name=" ~ info.name];
		if (cursor.length) args ~= ["-F", "after=" ~ cursor];
		auto raw = runCli(forge.cli, args, forge.on429BackoffS);
		if (raw.length == 0) return;
		try {
			auto root = parseJSON(raw);
			if ("errors" in root) return;
			auto conn = root["data"]["repository"]["discussions"];
			hasNext = conn["pageInfo"]["hasNextPage"].boolean;
			cursor = conn["pageInfo"]["endCursor"].type == JSONType.null_ ? "" : conn["pageInfo"]["endCursor"].str;
			foreach (node; conn["nodes"].array) {
				int num = cast(int) node["number"].integer;
				string title = node["title"].str;
				string body = node["body"].type == JSONType.null_ ? "" : node["body"].str;
				string url = node["url"].str;
				string createdAt = node["createdAt"].str;
				string author = ("author" in node && node["author"].type != JSONType.null_) ? node["author"]["login"].str : "";
				string category = ("category" in node && node["category"].type != JSONType.null_) ? node["category"]["name"].str : "";
				upsertDiscussion(db, repoId, num, title, category, body, url, createdAt, author);
				long did = getDiscussionId(db, repoId, num);
				deleteCommentsForDiscussion(db, did);
				if ("comments" in node) {
					foreach (c; node["comments"]["nodes"].array) {
						insertDiscussionComment(db, did,
							c["body"].type == JSONType.null_ ? "" : c["body"].str,
							("author" in c && c["author"].type != JSONType.null_) ? c["author"]["login"].str : "",
							c["createdAt"].str);
					}
				}
			}
		} catch (Exception) { return; }
	}
}

private string jsonStr(JSONValue obj, string key) {
	if (key !in obj || obj[key].type == JSONType.null_) return "";
	return obj[key].str;
}

private string toUpper(string s) {
	string o;
	foreach (c; s) {
		if (c >= 'a' && c <= 'z') o ~= cast(char)(c - 32);
		else o ~= c;
	}
	return o;
}

private string runCli(string cli, string[] args, int backoffS) {
	throttle();
	try {
		auto result = execute([cli] ~ args);
		gLastApiMs = Clock.currStdTime() / 10_000;
		if (result.status != 0) {
			auto combined = result.output.toLower;
			if (combined.canFind("rate limit") || combined.canFind("403") || combined.canFind("429")) {
				stderr.writeln("Rate limited; sleeping ", backoffS, "s");
				Thread.sleep(dur!"seconds"(backoffS));
				auto retry = execute([cli] ~ args);
				gLastApiMs = Clock.currStdTime() / 10_000;
				return retry.status == 0 ? retry.output : "";
			}
			return "";
		}
		return result.output;
	} catch (Exception) { return ""; }
}

private void throttle() {
	auto forge = resolveForge("github.com");
	auto now = Clock.currStdTime() / 10_000;
	auto elapsed = now - gLastApiMs;
	if (gLastApiMs > 0 && elapsed < forge.minIntervalMs)
		Thread.sleep(dur!"msecs"(forge.minIntervalMs - cast(int) elapsed));
}
