module issuesbrowser.paths;

import std.file;
import std.path;
import std.process;
import std.string;
import std.algorithm;

enum string dbFileName = "database.sqlite";
enum string archivesDirName = "archives";
enum string contentsDirName = "contents";
enum string monitorFileName = "monitor.sdl";
enum ushort defaultIpcPort = 17365;

/// Resolve the central `.issues` root (submissions + archives).
/// Order: ISSUES_BROWSER_ROOT env, then CODE_ROOT/github.com/AMDphreak/.issues,
/// then ~/code/github.com/AMDphreak/.issues, then ./ .issues beside cwd.
string archiveRoot(string overrideRoot = null) {
	if (overrideRoot.length && exists(overrideRoot))
		return absolutePath(overrideRoot);
	auto envRoot = environment.get("ISSUES_BROWSER_ROOT", "");
	if (envRoot.length && exists(envRoot))
		return absolutePath(envRoot);
	auto codeRoot = environment.get("CODE_ROOT", "");
	if (codeRoot.length == 0) {
		auto z = `Z:\code`;
		auto c = buildPath(environment.get("USERPROFILE", environment.get("HOME", ".")), "code");
		if (exists(z)) codeRoot = z;
		else if (exists(c)) codeRoot = c;
	}
	if (codeRoot.length) {
		auto p = buildPath(codeRoot, "github.com", "AMDphreak", ".issues");
		if (exists(p) || exists(dirName(p)))
			return absolutePath(p);
	}
	auto local = absolutePath(".issues");
	return local;
}

string archivesDir(string root = null) {
	return buildPath(archiveRoot(root), archivesDirName);
}

string monitorPath(string root = null) {
	return buildPath(archiveRoot(root), monitorFileName);
}

/// `archives/<host>/<owner>/<repo>`
string repoArchiveDir(string host, string owner, string name, string root = null) {
	auto h = host.length ? host : "github.com";
	// Flatten nested GitLab groups: owner may contain '/'
	auto ownerPath = owner.replace("/", "_");
	return buildPath(archivesDir(root), h, ownerPath, name);
}

string databasePath(string host, string owner, string name, string root = null) {
	return buildPath(repoArchiveDir(host, owner, name, root), dbFileName);
}

string contentsPath(string host, string owner, string name, string root = null) {
	return buildPath(repoArchiveDir(host, owner, name, root), contentsDirName);
}

void ensureArchiveDirs(string host, string owner, string name, string root = null) {
	auto dir = repoArchiveDir(host, owner, name, root);
	mkdirRecurse(dir);
	mkdirRecurse(buildPath(dir, contentsDirName));
}

/// Discover `**/archives/<host>/<owner>/<repo>/database.sqlite` under a root.
string[] discoverIssueDatabases(string searchRoot) {
	string[] result;
	auto root = absolutePath(searchRoot);
	if (!exists(root) || !isDir(root)) return result;
	discoverDbRecurse(root, result);
	return result;
}

private void discoverDbRecurse(string dir, ref string[] result) {
	foreach (e; dirEntries(dir, SpanMode.shallow)) {
		auto name = baseName(e.name);
		if (name == "." || name == "..") continue;
		if (!e.isDir) continue;
		if (name == ".git" || name == "node_modules" || name == "submissions") continue;
		auto db = buildPath(e.name, dbFileName);
		if (name != "contents" && exists(db)) {
			result ~= db;
			continue;
		}
		discoverDbRecurse(e.name, result);
	}
}
