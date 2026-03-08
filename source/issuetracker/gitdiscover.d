module issuetracker.gitdiscover;

import std.file;
import std.path;
import std.stdio;
import std.string;
import std.algorithm;
import issuetracker.types;

/// Recursively find all directories that contain a .git (file or directory).
/// Returns RepoInfo with path set; remote/owner/name filled from git config if possible.
RepoInfo[] discoverRepos(string rootPath) {
	RepoInfo[] result;
	auto root = absolutePath(rootPath);
	if (!exists(root) || !isDir(root)) return result;
	discoverRecurse(root, root, result);
	return result;
}

private void discoverRecurse(string root, string dir, ref RepoInfo[] result) {
	foreach (e; dirEntries(dir, SpanMode.shallow)) {
		auto name = e.name;
		if (name == "." || name == "..") continue;
		auto full = buildPath(dir, name);
		if (isDir(full)) {
			auto gitPath = buildPath(full, ".git");
			if (exists(gitPath)) {
				RepoInfo info;
				info.path = full;
				getRemoteAndName(full, info);
				result ~= info;
			} else {
				discoverRecurse(root, full, result);
			}
		}
	}
}

/// Fill remote, owner, name for a repo path by reading .git/config.
void getRemoteAndName(string repoPath, ref RepoInfo info) {
	import std.process;
	import std.conv;
	auto configPath = buildPath(repoPath, ".git", "config");
	if (!exists(configPath)) return;
	// Try to read [remote "origin"] url
	auto content = readText(configPath);
	auto lines = content.splitLines;
	string url;
	foreach (line; lines) {
		auto trimmed = line.strip();
		if (trimmed.startsWith("url = ")) {
			url = trimmed[6 .. $].strip();
			break;
		}
	}
	if (url.length == 0) {
		info.name = baseName(repoPath);
		return;
	}
	info.remote = url;
	// Parse owner/name from https://github.com/owner/repo or git@github.com:owner/repo.git
	if (url.canFind("github.com")) {
		string part;
		if (url.startsWith("https://") || url.startsWith("http://"))
			part = url[url.indexOf("github.com") + 10 .. $];
		else if (url.startsWith("git@github.com:"))
			part = url["git@github.com:".length .. $];
		else
			return;
		if (part.startsWith("/")) part = part[1 .. $];
		auto slash = part.indexOf("/");
		if (slash > 0) {
			info.owner = part[0 .. slash];
			info.name = part[slash + 1 .. $];
			if (info.name.endsWith(".git")) info.name = info.name[0 .. $-4];
		}
	}
	if (info.name.length == 0) info.name = baseName(repoPath);
}
