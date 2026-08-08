/** issues-browser-tray — system tray client for issuesd (Win32 tray; Qt settings later). */
module app_tray;

import std.stdio;
import std.getopt;
import std.conv;
import std.string;
import std.net.curl;
import std.process;
import std.path;
import std.file;
import tray.win_tray;
import issuesbrowser.paths;
import issuesbrowser.ipc : defaultPort;

void main(string[] args) {
	string root;
	ushort port = defaultPort;
	getopt(args, "root", &root, "port", &port);
	auto archiveRootPath = archiveRoot(root);
	auto base = "http://127.0.0.1:" ~ to!string(port);

	// Ensure daemon is up (best-effort)
	try {
		get(base ~ "/health");
	} catch (Exception) {
		stderr.writeln("issuesd not reachable at ", base, " — start issuesd first.");
	}

	version (Windows) {
		if (!startTray("issues-browser", (uint cmd) {
			try {
				if (cmd == ID_SYNC) {
					post(base ~ "/sync-now", `{"repo":""}`);
					setTrayTip("Sync requested");
				} else if (cmd == ID_STATUS) {
					auto st = get(base ~ "/status").idup;
					setTrayTip(st.length > 120 ? st[0 .. 120] : st);
					stderr.writeln(st);
				} else if (cmd == ID_OPEN_ARCHIVES) {
					auto dir = archivesDir(archiveRootPath);
					mkdirRecurse(dir);
					spawnProcess(["explorer", dir]);
				} else if (cmd == ID_QUIT) {
					stopTray();
				}
			} catch (Exception e) {
				setTrayTip("Error: " ~ e.msg);
			}
		})) {
			stderr.writeln("Failed to create tray icon.");
			return;
		}
		stderr.writeln("Tray running. Archives: ", archiveRootPath);
		runTrayLoop();
	} else {
		stderr.writeln("Tray UI is Windows-first (Win32). Use CLI/daemon on this platform.");
		stderr.writeln("IPC: ", base, "  archives: ", archiveRootPath);
	}
}
