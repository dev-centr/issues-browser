module issuesbrowser.sync;

import std.process;
import std.stdio;
import std.json;
import std.conv;
import std.string;
import std.algorithm;
import std.path;
import std.array;
import issuesbrowser.types;
import issuesbrowser.database;
import issuesbrowser.gitdiscover;

/// Sync one repo's issues (and discussions by default) into `<repo>/.issues/database.sqlite`.
/// Returns false if aborted by guardrails / user decline.
bool syncRepo(string repoPath, SyncOptions opts = SyncOptions.init) {
	RepoInfo info;
	info.path = repoPath;
	getRemoteAndName(repoPath, info);
	if (info.owner.length == 0 || info.name.length == 0) {
		stderr.writeln("Cannot determine owner/name for ", repoPath);
		return false;
	}
	if (info.host.length == 0)
		info.host = "github.com";
	if (info.host != "github.com") {
		stderr.writeln("Sync currently supports github.com remotes only (got ", info.host, ").");
		return false;
	}

	auto pre = preflight(info);
	if (!approveSync(pre, opts)) {
		stderr.writeln("Sync cancelled for ", info.owner, "/", info.name);
		return false;
	}

	migrateLegacyDbIfNeeded(repoPath, info.name);
	ensureRepoGitignore(repoPath);

	auto db = openDb(repoPath);
	initSchema(db);
	long repoId = upsertRepo(db, repoPath, info.remote, info.owner, info.name, info.host);

	syncIssues(db, repoId, info, opts.includePrs);
	if (opts.includeDiscussions)
		syncDiscussions(db, repoId, info);

	setLastSync(db, repoId);
	return true;
}

/// Count issues/discussions and detect forks before downloading bodies.
SyncPreflight preflight(RepoInfo info) {
	SyncPreflight p;
	string q =
		"query($owner:String!,$name:String!){" ~
		"repository(owner:$owner,name:$name){" ~
		"isFork " ~
		"parent{nameWithOwner issues{totalCount}} " ~
		"issues{totalCount} " ~
		"pullRequests{totalCount} " ~
		"discussions{totalCount}" ~
		"}}";
	auto raw = runGh([
		"api", "graphql",
		"-f", "query=" ~ q,
		"-F", "owner=" ~ info.owner,
		"-F", "name=" ~ info.name
	]);
	if (raw.length == 0) {
		p.summaryMessage = "Could not query repository size via GraphQL; proceeding with caution.";
		p.needsConfirm = true;
		return p;
	}
	try {
		auto root = parseJSON(raw);
		auto repo = root["data"]["repository"];
		if (repo.type == JSONType.null_) {
			p.summaryMessage = "Repository not found or Discussions/Issues inaccessible.";
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

	int archiveUnits = p.issueCount + p.discussionCount;
	p.summaryMessage = info.owner ~ "/" ~ info.name ~
		": " ~ to!string(p.issueCount) ~ " issues, " ~
		to!string(p.discussionCount) ~ " discussions, " ~
		to!string(p.prCount) ~ " PRs";
	if (p.isFork) {
		p.summaryMessage ~= " (FORK";
		if (p.parentNameWithOwner.length)
			p.summaryMessage ~= " of " ~ p.parentNameWithOwner;
		p.summaryMessage ~= ")";
	}
	return p;
}

bool approveSync(SyncPreflight pre, SyncOptions opts) {
	int units = pre.issueCount + pre.discussionCount;
	bool large = units >= opts.warnThreshold;
	bool huge = units >= opts.requireConfirmThreshold;
	bool forkRisk = pre.isFork && units >= opts.warnThreshold;

	if (!large && !forkRisk && !pre.needsConfirm)
		return true;

	string msg = pre.summaryMessage;
	if (huge)
		msg ~= "\nThis is a large archive (>= " ~ to!string(opts.requireConfirmThreshold) ~
			" issues+discussions). Syncing may take a long time and hit API rate limits.";
	else if (large)
		msg ~= "\nThis repo has >= " ~ to!string(opts.warnThreshold) ~
			" issues+discussions. Confirm before downloading everything.";
	if (forkRisk)
		msg ~= "\nForks of busy upstreams often share huge issue trackers — confirm this is intentional.";

	if (opts.force)
		return true;
	if (opts.confirm is null) {
		stderr.writeln(msg);
		stderr.writeln("Pass --yes to approve non-interactive sync.");
		return false;
	}
	return opts.confirm(msg);
}

private void syncIssues(Database db, long repoId, RepoInfo info, bool includePrs) {
	string[] args = [
		"api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues",
		"--paginate", "--state", "all"
	];
	auto issueJson = runGh(args);
	if (issueJson.length == 0) return;
	JSONValue[] issues;
	try {
		auto arr = parseJSON(issueJson);
		if (arr.type == JSONType.array)
			foreach (e; arr.array) issues ~= e;
	} catch (Exception) { return; }

	foreach (issue; issues) {
		if (!includePrs && "pull_request" in issue)
			continue;
		int num = issue["number"].integer.to!int;
		string title = issue["title"].str;
		string state = toUpper(issue["state"].str);
		string body = "body" in issue && issue["body"].type != JSONType.null_ ? issue["body"].str : "";
		string url = "html_url" in issue ? issue["html_url"].str : "";
		string createdAt = "created_at" in issue ? issue["created_at"].str : "";
		string closedAt = "";
		if ("closed_at" in issue && issue["closed_at"].type != JSONType.null_)
			closedAt = issue["closed_at"].str;
		string author = "";
		if ("user" in issue && issue["user"].type != JSONType.null_)
			author = issue["user"]["login"].str;
		bool prAccepted = false;
		string stateReason = "";
		if (state == "CLOSED") {
			auto timelineJson = runGh([
				"api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues/" ~ to!string(num) ~ "/timeline"
			]);
			if (timelineJson.length > 0) {
				try {
					auto timeline = parseJSON(timelineJson);
					foreach (ev; timeline.array) {
						if (ev["event"].str == "closed") {
							if ("commit_id" in ev && ev["commit_id"].type != JSONType.null_ && ev["commit_id"].str.length > 0)
								prAccepted = true;
							if ("state_reason" in ev && ev["state_reason"].type != JSONType.null_)
								stateReason = ev["state_reason"].str;
							break;
						}
					}
				} catch (Exception) {}
			}
		}
		upsertIssue(db, repoId, num, title, state, body, url, createdAt, closedAt, author, prAccepted, stateReason);
		long issueId = getIssueId(db, repoId, num);
		deleteCommentsForIssue(db, issueId);
		auto commentsJson = runGh([
			"api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues/" ~ to!string(num) ~ "/comments"
		]);
		if (commentsJson.length > 0 && commentsJson != "[]") {
			try {
				auto comments = parseJSON(commentsJson);
				foreach (c; comments.array) {
					string cbody = "body" in c && c["body"].type != JSONType.null_ ? c["body"].str : "";
					string cauthor = ("user" in c && c["user"].type != JSONType.null_) ? c["user"]["login"].str : "";
					string ccreated = "created_at" in c ? c["created_at"].str : "";
					insertComment(db, issueId, cbody, cauthor, ccreated);
				}
			} catch (Exception) {}
		}
	}
}

private void syncDiscussions(Database db, long repoId, RepoInfo info) {
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
			"nodes{number title body url createdAt " ~
			"author{login} category{name} " ~
			"comments(first:100){nodes{body createdAt author{login}}}}" ~
			"}}}";
		string[] args = [
			"api", "graphql",
			"-f", "query=" ~ q,
			"-F", "owner=" ~ info.owner,
			"-F", "name=" ~ info.name
		];
		if (cursor.length)
			args ~= ["-F", "after=" ~ cursor];
		auto raw = runGh(args);
		if (raw.length == 0) return;
		try {
			auto root = parseJSON(raw);
			if ("errors" in root) {
				// Discussions often disabled — not fatal.
				return;
			}
			auto conn = root["data"]["repository"]["discussions"];
			hasNext = conn["pageInfo"]["hasNextPage"].boolean;
			cursor = conn["pageInfo"]["endCursor"].type == JSONType.null_ ? "" : conn["pageInfo"]["endCursor"].str;
			foreach (node; conn["nodes"].array) {
				int num = cast(int) node["number"].integer;
				string title = node["title"].str;
				string body = node["body"].type == JSONType.null_ ? "" : node["body"].str;
				string url = node["url"].str;
				string createdAt = node["createdAt"].str;
				string author = "";
				if ("author" in node && node["author"].type != JSONType.null_)
					author = node["author"]["login"].str;
				string category = "";
				if ("category" in node && node["category"].type != JSONType.null_)
					category = node["category"]["name"].str;
				upsertDiscussion(db, repoId, num, title, category, body, url, createdAt, author);
				long did = getDiscussionId(db, repoId, num);
				deleteCommentsForDiscussion(db, did);
				if ("comments" in node) {
					foreach (c; node["comments"]["nodes"].array) {
						string cbody = c["body"].type == JSONType.null_ ? "" : c["body"].str;
						string cauthor = ("author" in c && c["author"].type != JSONType.null_) ? c["author"]["login"].str : "";
						string ccreated = c["createdAt"].str;
						insertDiscussionComment(db, did, cbody, cauthor, ccreated);
					}
				}
			}
		} catch (Exception) { return; }
	}
}

private string runGh(string[] args) {
	try {
		auto result = execute(["gh"] ~ args);
		if (result.status != 0)
			return "";
		return result.output;
	} catch (Exception) { return ""; }
}
