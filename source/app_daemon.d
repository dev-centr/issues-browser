/** issuesd — background forge metadata backup daemon with localhost IPC. */
module app_daemon;

import std.stdio;
import std.getopt;
import std.conv;
import std.datetime;
import core.thread;
import issuesbrowser.paths;
import issuesbrowser.monitor;
import issuesbrowser.ipc;
import issuesbrowser.profiles;
import issuesbrowser.types;

void main(string[] args) {
	string root;
	ushort port = defaultPort;
	bool once;
	getopt(args,
		"root", &root,
		"port", &port,
		"once", &once
	);
	auto archiveRootPath = archiveRoot(root);
	loadForgeProfiles(archiveRootPath);
	migrateArchivesAsBackup(archiveRootPath);
	stderr.writeln("issuesd archive root: ", archiveRootPath);

	if (once) {
		foreach (m; loadMonitorList(archiveRootPath)) {
			if (!m.enabled) continue;
			stderr.writeln("Syncing ", m.owner, "/", m.name, " ...");
			syncMonitored(m, archiveRootPath);
		}
		return;
	}

	auto ipcThread = new Thread({
		serveIpc(port, archiveRootPath);
	});
	ipcThread.start();

	// Poll loop
	while (!gStop) {
		auto list = loadMonitorList(archiveRootPath);
		foreach (m; list) {
			if (!m.enabled) continue;
			stderr.writeln("Monitor sync ", m.owner, "/", m.name);
			syncMonitored(m, archiveRootPath);
			int waitSec = m.pollIntervalSec > 0 ? m.pollIntervalSec : 300;
			// coarse: sleep between repos; full interval applied after pass
			Thread.sleep(dur!"seconds"(2));
		}
		int pause = 60;
		foreach (m; list) if (m.enabled && m.pollIntervalSec > 0) {
			pause = m.pollIntervalSec;
			break;
		}
		foreach (i; 0 .. pause) {
			if (gStop) break;
			Thread.sleep(dur!"seconds"(1));
		}
	}
}
