module issuesbrowser.prohelpcompat;

import std.stdio;
import std.string;
import std.file;
import std.path;
import std.algorithm;
import std.array;
import sdlang;

/// ProHelp-compatible intercept for `?` / `--help` using the same `help.sdl` schema.
/// Full openshellorg/prohelp can replace this import when the toolchain builds it cleanly.
bool intercept(string[] args) {
	if (args.length < 2) return false;
	auto trigger = args[1].toLower;
	string[] bases = ["?", "help", "--help", "-h", "--?"];
	bool matched;
	string pathSpec;
	foreach (t; bases) {
		if (trigger == t) { matched = true; break; }
		if (trigger.startsWith(t ~ ":")) { matched = true; break; }
	}
	if (!matched) return false;

	if (args.length >= 3) pathSpec = args[2 .. $].join(" ");

	auto schema = loadHelpSdl();
	if (schema.length == 0) {
		writeln("issues-browser help (help.sdl not found)");
		writeln("  --sync --list --monitor-add --monitor-list --find-dbs --yes");
		return true;
	}
	renderHelp(schema, pathSpec);
	return true;
}

private string loadHelpSdl() {
	string[] candidates = [
		buildPath(getcwd(), "help.sdl"),
		absolutePath("help.sdl"),
	];
	try { candidates ~= buildPath(dirName(thisExePath()), "help.sdl"); } catch (Exception) {}
	foreach (c; candidates) {
		if (exists(c)) return readText(c);
	}
	return "";
}

private void renderHelp(string content, string pathSpec) {
	try {
		Tag root = parseSource(content);
		foreach (tag; root.tags) {
			if (tag.name != "command") continue;
			string title, summary, description;
			foreach (c; tag.tags) {
				if (c.name == "title" && c.values.length) title = c.values[0].get!string;
				else if (c.name == "summary" && c.values.length) summary = c.values[0].get!string;
				else if (c.name == "description" && c.values.length) description = c.values[0].get!string;
			}
			writeln(title.length ? title : "issues-browser");
			if (summary.length) writeln(summary);
			writeln();
			if (pathSpec.length == 0 && description.length) {
				writeln(description);
				writeln();
			}
			foreach (sec; tag.tags) {
				if (sec.name != "section") continue;
				string secName = sec.values.length ? sec.values[0].get!string : "";
				if (pathSpec.length && secName != pathSpec && !pathSpec.canFind(secName))
					continue;
				string secSummary, secContent;
				foreach (f; sec.tags) {
					if (f.name == "summary" && f.values.length) secSummary = f.values[0].get!string;
					else if (f.name == "content" && f.values.length) secContent = f.values[0].get!string;
				}
				writeln("== ", secName, (secSummary.length ? " — " ~ secSummary : ""));
				if (secContent.length) writeln(secContent);
				foreach (ex; sec.tags) {
					if (ex.name == "example" && ex.values.length >= 2)
						writeln("  # ", ex.values[0].get!string, "\n  ", ex.values[1].get!string);
				}
				writeln();
			}
		}
	} catch (Exception e) {
		writeln("Failed to parse help.sdl: ", e.msg);
	}
}
