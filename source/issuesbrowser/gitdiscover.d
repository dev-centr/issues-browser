module issuesbrowser.gitdiscover;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import issuesbrowser.types;
import issuesbrowser.paths;

/// Recursively find all directories that contain a `.git` (file or directory).
RepoInfo[] discoverRepos(string rootPath) {
	RepoInfo[] result;
	auto root = absolutePath(rootPath);
	if (!exists(root) || !isDir(root)) return result;
	discoverRecurse(root, result);
	return result;
}

/// Re-export archive discovery from paths.
alias discoverIssueDatabases = issuesbrowser.paths.discoverIssueDatabases;

private void discoverRecurse(string dir, ref RepoInfo[] result) {
	foreach (e; dirEntries(dir, SpanMode.shallow)) {
		auto name = baseName(e.name);
		if (name == "." || name == "..") continue;
		auto full = e.name;
		if (!e.isDir) continue;
		if (name == ".issues" || name == ".issue-submissions" || name == "archives" || name == "submissions")
			continue;
		auto gitPath = buildPath(full, ".git");
		if (exists(gitPath)) {
			RepoInfo info;
			info.path = full;
			getRemoteAndName(full, info);
			result ~= info;
		} else {
			discoverRecurse(full, result);
		}
	}
}

void getRemoteAndName(string repoPath, ref RepoInfo info) {
	auto configPath = buildPath(repoPath, ".git", "config");
	if (!exists(configPath)) {
		info.name = baseName(repoPath);
		return;
	}
	auto content = readText(configPath);
	string url;
	foreach (line; content.splitLines) {
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
	parseRemoteUrl(url, info);
	if (info.name.length == 0) info.name = baseName(repoPath);
}

void parseRemoteUrl(string url, ref RepoInfo info) {
	string host;
	string pathPart;
	if (url.startsWith("git@")) {
		auto colon = url.indexOf(":");
		if (colon <= 4) return;
		host = url[4 .. colon];
		pathPart = url[colon + 1 .. $];
	} else if (url.startsWith("https://") || url.startsWith("http://")) {
		auto rest = url[url.indexOf("://") + 3 .. $];
		auto slash = rest.indexOf("/");
		if (slash < 0) return;
		host = rest[0 .. slash];
		pathPart = rest[slash + 1 .. $];
	} else {
		return;
	}
	info.host = host;
	if (pathPart.endsWith(".git")) pathPart = pathPart[0 .. $ - 4];
	auto slash = pathPart.indexOf("/");
	if (slash > 0) {
		info.owner = pathPart[0 .. slash];
		info.name = pathPart[slash + 1 .. $];
		auto last = info.name.lastIndexOf("/");
		if (last >= 0) {
			info.owner = info.owner ~ "/" ~ info.name[0 .. last];
			info.name = info.name[last + 1 .. $];
		}
	}
}
