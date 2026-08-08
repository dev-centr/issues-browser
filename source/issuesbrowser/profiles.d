module issuesbrowser.profiles;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.regex;
import sdlang;
import issuesbrowser.types;
import issuesbrowser.paths;

private ForgeProfile[] gProfiles;
private bool gLoaded;

void loadForgeProfiles(string root = null) {
	gProfiles.length = 0;
	gLoaded = true;
	string[] candidates;
	try {
		candidates ~= buildPath(dirName(thisExePath()), "profiles", "forge-profiles.sdl");
	} catch (Exception) {}
	candidates ~= buildPath(getcwd(), "profiles", "forge-profiles.sdl");
	candidates ~= buildPath(archiveRoot(root), "forge-profiles.sdl");
	candidates ~= absolutePath(buildPath("profiles", "forge-profiles.sdl"));
	foreach (c; candidates) {
		if (exists(c)) {
			parseForgeContent(readText(c));
			break;
		}
	}
	if (gProfiles.length == 0)
		gProfiles ~= defaultGitHub();
}

ForgeProfile[] allForgeProfiles() {
	if (!gLoaded) loadForgeProfiles();
	return gProfiles;
}

ForgeProfile resolveForge(string host) {
	if (!gLoaded) loadForgeProfiles();
	auto h = host.length ? host : "github.com";
	foreach (p; gProfiles) {
		foreach (m; p.matchers) {
			try {
				if (!matchFirst(h, regex(m)).empty)
					return p;
			} catch (Exception) {}
		}
	}
	return defaultGitHub();
}

string[] interpolateCmd(string[] tmpl, string owner, string name, string host, string since = "") {
	string[] outArgs;
	foreach (a; tmpl) {
		outArgs ~= a
			.replace("$OWNER", owner)
			.replace("$NAME", name)
			.replace("$HOST", host)
			.replace("$SINCE", since);
	}
	return outArgs;
}

private void parseForgeContent(string content) {
	Tag root = parseSource(content);
	foreach (tag; root.tags) {
		if (tag.name != "forge") continue;
		ForgeProfile p;
		p.name = tag.values[0].get!string;
		foreach (child; tag.tags) {
			string[] vals;
			foreach (v; child.values) vals ~= v.get!string;
			switch (child.name) {
			case "matcher":
				p.matchers = vals;
				break;
			case "cli":
				if (vals.length) p.cli = vals[0];
				break;
			case "list-issues":
				p.listIssuesCmd = vals;
				break;
			case "list-prs":
				p.listPrsCmd = vals;
				break;
			case "graphql":
				if (vals.length) p.graphql = vals[0] == "true" || child.values[0].get!bool;
				break;
			case "rate_limit":
				foreach (rl; child.tags) {
					if (rl.name == "min_interval_ms" && rl.values.length)
						p.minIntervalMs = cast(int) rl.values[0].get!long;
					else if (rl.name == "on_429_backoff_s" && rl.values.length)
						p.on429BackoffS = cast(int) rl.values[0].get!long;
				}
				break;
			default:
				break;
			}
		}
		gProfiles ~= p;
	}
}

private ForgeProfile defaultGitHub() {
	ForgeProfile p;
	p.name = "github";
	p.matchers = ["github\\.com"];
	p.cli = "gh";
	p.listIssuesCmd = ["api", "repos/$OWNER/$NAME/issues", "--paginate", "--state", "all"];
	p.listPrsCmd = ["api", "repos/$OWNER/$NAME/pulls", "--paginate", "--state", "all"];
	p.graphql = true;
	p.minIntervalMs = 1000;
	p.on429BackoffS = 60;
	return p;
}
