module issuetracker.sync;

import std.process;
import std.stdio;
import std.json;
import std.conv;
import std.string;
import std.algorithm;
import std.path;
import issuetracker.types;
import issuetracker.database;
import issuetracker.gitdiscover;

/// Sync one repo's issues and comments into .issues/reponame.sqlite using gh CLI.
/// parentDir = directory containing the repo folder (so .issues is sibling to repo).
void syncRepo(string repoPath, string parentDir, string repoName) {
	auto db = openDb(parentDir, repoName);
	initSchema(db);
	RepoInfo info;
	info.path = repoPath;
	getRemoteAndName(repoPath, info);
	if (info.owner.length == 0 || info.name.length == 0) return;
	long repoId = upsertRepo(db, repoPath, info.remote, info.owner, info.name);
	// Fetch issues: gh api repos/owner/repo/issues --paginate
	string[] args = ["api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues", "--paginate", "--state", "all"];
	auto issueJson = runGh(args);
	if (issueJson.length == 0) return;
	JSONValue[] issues;
	try {
		auto arr = parseJSON(issueJson);
		if (arr.type == JSONType.array)
			foreach (e; arr.array) issues ~= e;
	} catch (Exception) { return; }
	foreach (issue; issues) {
		int num = issue["number"].integer.to!int;
		string title = issue["title"].str;
		string state = toUpper(issue["state"].str);
		string body = "body" in issue ? issue["body"].str : "";
		string url = "html_url" in issue ? issue["html_url"].str : "";
		string createdAt = "created_at" in issue ? issue["created_at"].str : "";
		string closedAt = "";
		if ("closed_at" in issue && issue["closed_at"].type != JSONType.null_)
			closedAt = issue["closed_at"].str;
		string author = "";
		if ("user" in issue)
			author = issue["user"]["login"].str;
		bool prAccepted = false;
		string stateReason = "";
		if (state == "closed") {
			auto timelineJson = runGh(["api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues/" ~ to!string(num) ~ "/timeline"]);
			if (timelineJson.length > 0) {
				try {
					auto timeline = parseJSON(timelineJson);
					foreach (ev; timeline.array) {
						if (ev["event"].str == "closed") {
							if ("commit_id" in ev && ev["commit_id"].str.length > 0)
								prAccepted = true;
							if ("state_reason" in ev)
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
		auto commentsJson = runGh(["api", "repos/" ~ info.owner ~ "/" ~ info.name ~ "/issues/" ~ to!string(num) ~ "/comments"]);
		if (commentsJson.length > 0 && commentsJson != "[]") {
			try {
				auto comments = parseJSON(commentsJson);
				foreach (c; comments.array) {
					string cbody = "body" in c ? c["body"].str : "";
					string cauthor = "user" in c ? c["user"]["login"].str : "";
					string ccreated = "created_at" in c ? c["created_at"].str : "";
					insertComment(db, issueId, cbody, cauthor, ccreated);
				}
			} catch (Exception) {}
		}
	}
}

private string runGh(string[] args) {
	import std.exception;
	try {
		auto result = execute(["gh"] ~ args);
		return result.output;
	} catch (Exception) { return ""; }
}
