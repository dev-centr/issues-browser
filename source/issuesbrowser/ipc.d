module issuesbrowser.ipc;

import std.socket;
import std.conv;
import std.string;
import std.array;
import std.algorithm;
import std.stdio;
import std.json;
import std.datetime;
import issuesbrowser.paths;
import issuesbrowser.monitor;
import issuesbrowser.types;
import issuesbrowser.sync;

enum ushort defaultPort = 17365;

shared bool gStop;
shared string gStatusJson = `{"ok":true,"message":"starting"}`;

struct DaemonState {
	string archiveRoot;
	int syncedCount;
	string lastError;
	string lastSyncAt;
}

DaemonState gState;

void setStatus(string json) {
	synchronized {
		gStatusJson = json;
	}
}

string getStatus() {
	synchronized {
		return gStatusJson;
	}
}

/// Minimal HTTP/1.1 server on 127.0.0.1 (rulesd-shaped).
void serveIpc(ushort port, string archiveRoot) {
	gState.archiveRoot = archiveRoot;
	auto addr = new InternetAddress("127.0.0.1", port);
	auto listener = new TcpSocket();
	listener.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
	listener.bind(addr);
	listener.listen(8);
	stderr.writeln("issuesd IPC on 127.0.0.1:", port);

	while (!gStop) {
		auto set = new SocketSet();
		set.add(listener);
		if (Socket.select(set, null, null, dur!"msecs"(500)) <= 0)
			continue;
		if (!set.isSet(listener)) continue;
		auto client = listener.accept();
		scope (exit) client.close();
		char[8192] buf;
		auto n = client.receive(buf[]);
		if (n <= 0) continue;
		auto req = buf[0 .. n].idup;
		auto resp = handleRequest(req, archiveRoot);
		client.send(resp);
	}
	listener.close();
}

private string handleRequest(string req, string archiveRoot) {
	auto lines = req.splitLines();
	if (lines.length == 0) return httpResponse(400, `{"error":"bad request"}`);
	auto parts = lines[0].split(" ");
	if (parts.length < 2) return httpResponse(400, `{"error":"bad request"}`);
	auto method = parts[0];
	auto path = parts[1];
	string body;
	auto blank = req.indexOf("\r\n\r\n");
	if (blank >= 0) body = req[blank + 4 .. $];

	if (method == "GET" && path == "/health")
		return httpResponse(200, `{"ok":true}`);
	if (method == "GET" && path == "/status")
		return httpResponse(200, buildStatusJson(archiveRoot));
	if (method == "GET" && path == "/debug")
		return httpResponse(200, buildDebugJson(archiveRoot));
	if (method == "GET" && path.startsWith("/monitor"))
		return httpResponse(200, monitorListJson(archiveRoot));
	if (method == "POST" && path == "/monitor/add") {
		auto slug = jsonField(body, "repo");
		if (slug.length == 0) return httpResponse(400, `{"error":"repo required"}`);
		auto ok = addMonitored(slug, archiveRoot);
		return httpResponse(ok ? 200 : 400, ok ? `{"ok":true}` : `{"error":"invalid repo"}`);
	}
	if (method == "POST" && path == "/monitor/remove") {
		auto slug = jsonField(body, "repo");
		auto ok = removeMonitored(slug, archiveRoot);
		return httpResponse(ok ? 200 : 404, ok ? `{"ok":true}` : `{"error":"not found"}`);
	}
	if (method == "POST" && path == "/sync-now") {
		auto slug = jsonField(body, "repo");
		auto ok = syncOneFromSlug(slug, archiveRoot);
		return httpResponse(ok ? 200 : 500, ok ? `{"ok":true}` : `{"error":"sync failed"}`);
	}
	return httpResponse(404, `{"error":"not found"}`);
}

private string buildStatusJson(string archiveRoot) {
	auto list = loadMonitorList(archiveRoot);
	JSONValue o;
	o["ok"] = true;
	o["archiveRoot"] = issuesbrowser.paths.archiveRoot(archiveRoot);
	o["monitored"] = cast(int) list.length;
	o["enabled"] = cast(int) list.count!(m => m.enabled);
	o["lastSyncAt"] = gState.lastSyncAt;
	o["lastError"] = gState.lastError;
	o["syncedCount"] = gState.syncedCount;
	return o.toString();
}

private string buildDebugJson(string root) {
	JSONValue o;
	o["archiveRoot"] = archiveRoot(root);
	o["monitorPath"] = monitorPath(root);
	o["port"] = defaultPort;
	return o.toString();
}

private string monitorListJson(string root) {
	JSONValue[] arr;
	foreach (m; loadMonitorList(root)) {
		JSONValue o;
		o["host"] = m.host;
		o["owner"] = m.owner;
		o["name"] = m.name;
		o["remote"] = m.remote;
		o["pollIntervalSec"] = m.pollIntervalSec;
		o["enabled"] = m.enabled;
		o["lastSync"] = m.lastSync;
		o["lastError"] = m.lastError;
		arr ~= o;
	}
	JSONValue rootJ;
	rootJ["repos"] = arr;
	return rootJ.toString();
}

bool syncOneFromSlug(string slug, string archiveRoot) {
	string host, owner, name, remote;
	if (!parseRemoteOrSlug(slug, host, owner, name, remote) && slug.length) {
		// try owner/name from monitor list match
		foreach (m; loadMonitorList(archiveRoot)) {
			if (m.name == slug || (m.owner ~ "/" ~ m.name) == slug) {
				host = m.host; owner = m.owner; name = m.name; remote = m.remote;
				break;
			}
		}
	}
	if (owner.length == 0) {
		// sync all enabled
		bool any = false;
		foreach (m; loadMonitorList(archiveRoot)) {
			if (!m.enabled) continue;
			if (syncMonitored(m, archiveRoot)) any = true;
		}
		return any;
	}
	MonitoredRepo m;
	m.host = host; m.owner = owner; m.name = name; m.remote = remote; m.enabled = true;
	return syncMonitored(m, archiveRoot);
}

bool syncMonitored(MonitoredRepo m, string archiveRoot) {
	RepoInfo info;
	info.host = m.host;
	info.owner = m.owner;
	info.name = m.name;
	info.remote = m.remote;
	SyncOptions opts;
	opts.force = true;
	opts.includePrs = true;
	opts.includeDiscussions = true;
	opts.archiveRoot = archiveRoot;
	try {
		auto ok = syncRepoInfo(info, opts);
		auto now = Clock.currTime.toISOExtString();
		if (ok) {
			gState.syncedCount++;
			gState.lastSyncAt = now;
			gState.lastError = "";
			updateMonitorStatus(m.host, m.owner, m.name, now, "", archiveRoot);
		} else {
			gState.lastError = "sync failed";
			updateMonitorStatus(m.host, m.owner, m.name, m.lastSync, "sync failed", archiveRoot);
		}
		return ok;
	} catch (Exception e) {
		gState.lastError = e.msg;
		updateMonitorStatus(m.host, m.owner, m.name, m.lastSync, e.msg, archiveRoot);
		return false;
	}
}

private string jsonField(string body, string key) {
	try {
		auto j = parseJSON(body);
		if (key in j) return j[key].str;
	} catch (Exception) {}
	return body.strip().replace(`"`, "");
}

private string httpResponse(int code, string jsonBody) {
	auto reason = code == 200 ? "OK" : (code == 404 ? "Not Found" : "Error");
	return "HTTP/1.1 " ~ to!string(code) ~ " " ~ reason ~ "\r\n" ~
		"Content-Type: application/json\r\n" ~
		"Content-Length: " ~ to!string(jsonBody.length) ~ "\r\n" ~
		"Connection: close\r\n\r\n" ~ jsonBody;
}
