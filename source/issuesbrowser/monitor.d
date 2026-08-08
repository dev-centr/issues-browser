module issuesbrowser.monitor;

import std.file;
import std.path;
import std.string;
import std.algorithm;
import std.array;
import std.conv;
import std.stdio;
import sdlang;
import issuesbrowser.types;
import issuesbrowser.paths;

MonitoredRepo[] loadMonitorList(string root = null) {
	MonitoredRepo[] list;
	auto path = monitorPath(root);
	if (!exists(path)) return list;
	try {
		Tag doc = parseSource(readText(path));
		foreach (tag; doc.tags) {
			if (tag.name != "repo") continue;
			MonitoredRepo m;
			m.remote = tag.values[0].get!string;
			foreach (child; tag.tags) {
				if (child.values.length == 0) continue;
				switch (child.name) {
				case "host": m.host = child.values[0].get!string; break;
				case "owner": m.owner = child.values[0].get!string; break;
				case "name": m.name = child.values[0].get!string; break;
				case "poll_interval_s": m.pollIntervalSec = cast(int) child.values[0].get!long; break;
				case "last_sync": m.lastSync = child.values[0].get!string; break;
				case "last_error": m.lastError = child.values[0].get!string; break;
				case "enabled": m.enabled = child.values[0].get!bool; break;
				case "backup": m.backup = child.values[0].get!bool; break;
				case "mode":
					auto mode = child.values[0].get!string;
					m.backup = (mode == "backup");
					break;
				default: break;
				}
			}
			if (m.host.length == 0) m.host = "github.com";
			list ~= m;
		}
	} catch (Exception e) {
		stderr.writeln("Failed to parse monitor.sdl: ", e.msg);
	}
	return list;
}

void saveMonitorList(MonitoredRepo[] list, string root = null) {
	auto rootPath = archiveRoot(root);
	mkdirRecurse(rootPath);
	auto path = monitorPath(root);
	string s = "// issues-browser monitored repositories (local; do not commit)\n";
	foreach (m; list) {
		s ~= "repo \"" ~ escapeSdl(m.remote) ~ "\" {\n";
		s ~= "    host \"" ~ escapeSdl(m.host) ~ "\"\n";
		s ~= "    owner \"" ~ escapeSdl(m.owner) ~ "\"\n";
		s ~= "    name \"" ~ escapeSdl(m.name) ~ "\"\n";
		s ~= "    poll_interval_s " ~ to!string(m.pollIntervalSec) ~ "\n";
		s ~= "    enabled " ~ (m.enabled ? "true" : "false") ~ "\n";
		s ~= "    backup " ~ (m.backup ? "true" : "false") ~ "\n";
		if (m.lastSync.length)
			s ~= "    last_sync \"" ~ escapeSdl(m.lastSync) ~ "\"\n";
		if (m.lastError.length)
			s ~= "    last_error \"" ~ escapeSdl(m.lastError) ~ "\"\n";
		s ~= "}\n";
	}
	std.file.write(path, s);
}

bool addMonitored(string remoteOrSlug, string root = null, int pollIntervalSec = 300, bool backup = false) {
	auto list = loadMonitorList(root);
	string host, owner, name, remote;
	if (!parseRemoteOrSlug(remoteOrSlug, host, owner, name, remote))
		return false;
	foreach (ref m; list) {
		if (m.host == host && m.owner == owner && m.name == name) {
			m.enabled = true;
			m.pollIntervalSec = pollIntervalSec;
			m.backup = backup;
			saveMonitorList(list, root);
			return true;
		}
	}
	MonitoredRepo m;
	m.host = host;
	m.owner = owner;
	m.name = name;
	m.remote = remote;
	m.pollIntervalSec = pollIntervalSec;
	m.enabled = true;
	m.backup = backup;
	list ~= m;
	saveMonitorList(list, root);
	return true;
}

bool setBackupMode(string remoteOrSlug, bool backup, string root = null) {
	auto list = loadMonitorList(root);
	string host, owner, name, remote;
	if (!parseRemoteOrSlug(remoteOrSlug, host, owner, name, remote))
		return false;
	foreach (ref m; list) {
		if (m.host == host && m.owner == owner && m.name == name) {
			m.backup = backup;
			saveMonitorList(list, root);
			return true;
		}
	}
	// not monitored yet — add as enabled with requested backup flag
	return addMonitored(remoteOrSlug, root, 300, backup);
}

/// Existing archive DBs are treated as backup-enabled so upgrades never silently downgrade.
void migrateArchivesAsBackup(string root = null) {
	auto list = loadMonitorList(root);
	bool changed = false;
	auto dbs = discoverIssueDatabases(archivesDir(root));
	foreach (dbPath; dbs) {
		// archives/<host>/<owner>/<repo>/database.sqlite
		auto repoDir = dirName(dbPath);
		auto name = baseName(repoDir);
		auto owner = baseName(dirName(repoDir));
		auto host = baseName(dirName(dirName(repoDir)));
		bool found = false;
		foreach (ref m; list) {
			if (m.host == host && m.owner == owner && m.name == name) {
				if (!m.backup) {
					m.backup = true;
					changed = true;
				}
				found = true;
				break;
			}
		}
		if (!found) {
			MonitoredRepo m;
			m.host = host;
			m.owner = owner;
			m.name = name;
			m.remote = "https://" ~ host ~ "/" ~ owner ~ "/" ~ name ~ ".git";
			m.backup = true;
			m.enabled = true;
			list ~= m;
			changed = true;
		}
	}
	if (changed)
		saveMonitorList(list, root);
}

bool removeMonitored(string remoteOrSlug, string root = null) {
	auto list = loadMonitorList(root);
	string host, owner, name, remote;
	if (!parseRemoteOrSlug(remoteOrSlug, host, owner, name, remote))
		return false;
	auto kept = list.filter!(m => !(m.host == host && m.owner == owner && m.name == name)).array;
	if (kept.length == list.length) return false;
	saveMonitorList(kept, root);
	return true;
}

void updateMonitorStatus(string host, string owner, string name, string lastSync, string lastError, string root = null) {
	auto list = loadMonitorList(root);
	foreach (ref m; list) {
		if (m.host == host && m.owner == owner && m.name == name) {
			m.lastSync = lastSync;
			m.lastError = lastError;
			saveMonitorList(list, root);
			return;
		}
	}
}

bool parseRemoteOrSlug(string input, out string host, out string owner, out string name, out string remote) {
	auto s = input.strip();
	if (s.length == 0) return false;
	if (s.canFind("://") || s.startsWith("git@")) {
		remote = s;
		string pathPart;
		if (s.startsWith("git@")) {
			auto colon = s.indexOf(":");
			if (colon <= 4) return false;
			host = s[4 .. colon];
			pathPart = s[colon + 1 .. $];
		} else {
			auto rest = s[s.indexOf("://") + 3 .. $];
			auto slash = rest.indexOf("/");
			if (slash < 0) return false;
			host = rest[0 .. slash];
			pathPart = rest[slash + 1 .. $];
		}
		if (pathPart.endsWith(".git")) pathPart = pathPart[0 .. $ - 4];
		auto slash = pathPart.indexOf("/");
		if (slash < 0) return false;
		owner = pathPart[0 .. slash];
		name = pathPart[slash + 1 .. $];
		auto last = name.lastIndexOf("/");
		if (last >= 0) {
			owner = owner ~ "/" ~ name[0 .. last];
			name = name[last + 1 .. $];
		}
		return owner.length > 0 && name.length > 0;
	}
	auto slash = s.indexOf("/");
	if (slash <= 0) return false;
	host = "github.com";
	owner = s[0 .. slash];
	name = s[slash + 1 .. $];
	remote = "https://github.com/" ~ owner ~ "/" ~ name ~ ".git";
	return name.length > 0;
}

private string escapeSdl(string s) {
	return s.replace(`\`, `\\`).replace(`"`, `\"`);
}
