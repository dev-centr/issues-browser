module issuesbrowser.gitignore;

import std.file;
import std.path;
import std.string;

/// Ensure the target repo ignores the local archive directory.
void ensureIssuesGitignore(string repoPath) {
	auto giPath = buildPath(repoPath, ".gitignore");
	string existing = exists(giPath) ? readText(giPath) : "";
	foreach (line; existing.splitLines) {
		auto t = line.strip();
		if (t == ".issues/" || t == ".issues" || t == "**/.issues/" || t == "/.issues/")
			return;
	}
	auto block = "\n# Local issues-browser archive (SQLite; do not commit)\n.issues/\n";
	if (existing.length > 0 && !existing.endsWith("\n"))
		existing ~= "\n";
	write(giPath, existing ~ block);
}
