module app_gui;

import dlangui;
import std.path;
import std.file;
import std.conv;
import std.algorithm;
import std.string;
import issuesbrowser.gitdiscover;
import issuesbrowser.sync;
import issuesbrowser.database;
import issuesbrowser.types;
import issuesbrowser.paths;
import issuesbrowser.index;
import issuesbrowser.monitor;
import d2sqlite3;

mixin APP_ENTRY_POINT;

extern (C) int UIAppMain(string[] args) {
	FontManager.fontGamma = 0.8;
	FontManager.hintingMode = HintingMode.Normal;

	string openRepoSlug;
	string openHost = "github.com";
	string archiveRootOpt;
	import std.getopt;
	getopt(args,
		"open-repo", &openRepoSlug,
		"host", &openHost,
		"root", &archiveRootOpt
	);

	Window window = Platform.instance.createWindow("Issues Browser"d, null, WindowFlag.Resizable, 900, 600);
	auto frame = new IssuesBrowserFrame(openRepoSlug, openHost, archiveRootOpt);
	window.mainWidget = frame;
	window.show();
	return Platform.instance.enterMessageLoop();
}

class IssuesBrowserFrame : Widget {
	this(string openRepoSlug = null, string openHost = "github.com", string archiveRootOpt = null) {
		HorizontalLayout topBar = new HorizontalLayout();
		LineEdit folderEdit = new LineEdit();
		folderEdit.placeholder = "Path to folder of git repos";
		folderEdit.preferredWidth = 400;
		Button addBtn = new Button("Add folder");
		Button syncBtn = new Button("Sync selected (index)");
		Button backupBtn = new Button("Backup selected");
		Button refreshBtn = new Button("Refresh list");
		topBar.addChild(folderEdit);
		topBar.addChild(addBtn);
		topBar.addChild(syncBtn);
		topBar.addChild(backupBtn);
		topBar.addChild(refreshBtn);

		ListView repoList = new ListView();
		repoList.preferredWidth = 260;
		ListView issueList = new ListView();
		issueList.preferredWidth = 350;
		TextEdit detailEdit = new TextEdit();
		detailEdit.readOnly = true;
		detailEdit.multiline = true;

		HorizontalLayout content = new HorizontalLayout();
		content.addChild(repoList, 0);
		content.addChild(issueList, 0);
		content.addChild(detailEdit, 1);

		VerticalLayout mainLayout = new VerticalLayout();
		mainLayout.addChild(topBar);
		mainLayout.addChild(content, 1);
		addChild(mainLayout);

		RepoInfo[] repos;
		string currentDbPath;
		long[] itemIds;
		string[] itemKinds; // "issue" | "pr" | "discussion"
		auto root = archiveRoot(archiveRootOpt);

		void refreshRepos() {
			repoList.items.clear();
			repos = [];
			string path = folderEdit.text.to!string.strip();
			if (path.length == 0) return;
			repos = discoverRepos(path);
			foreach (r; repos) {
				string label = r.name;
				if (r.owner.length > 0) label = r.owner ~ "/" ~ label;
				auto host = r.host.length ? r.host : "github.com";
				auto mode = repoModeLabel(host, r.owner, r.name, root);
				if (mode == "backup") label ~= " [backed up]";
				else if (mode == "index") label ~= " [cached]";
				repoList.items ~= label;
			}
			repoList.updateItems();
		}

		void refreshIssues() {
			issueList.items.clear();
			itemIds = [];
			itemKinds = [];
			if (currentDbPath.length == 0 || !exists(currentDbPath)) return;
			Database db = Database(currentDbPath);
			foreach (row; db.execute("SELECT id, number, title, state, is_pr FROM issues ORDER BY number DESC")) {
				itemIds ~= row.peek!long(0);
				bool isPr = row.peek!int(4) != 0;
				itemKinds ~= isPr ? "pr" : "issue";
				auto pfx = isPr ? "PR#" : "#";
				issueList.items ~= (pfx ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~ " [" ~ row.peek!string(3) ~ "]");
			}
			foreach (row; db.execute("SELECT id, number, title, state FROM pull_requests ORDER BY number DESC")) {
				itemIds ~= row.peek!long(0);
				itemKinds ~= "prtable";
				issueList.items ~= ("PR#" ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~ " [" ~ row.peek!string(3) ~ "]");
			}
			foreach (row; db.execute("SELECT id, number, title, category FROM discussions ORDER BY number DESC")) {
				itemIds ~= row.peek!long(0);
				itemKinds ~= "discussion";
				string cat = row.peek!string(3);
				issueList.items ~= ("D#" ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~ (cat.length ? " [" ~ cat ~ "]" : ""));
			}
			issueList.updateItems();
		}

		void openRepoBySlug(string slug, string host) {
			string owner, name, remote, h = host;
			if (!parseRemoteOrSlug(slug, h, owner, name, remote) && slug.canFind("/")) {
				auto slash = slug.indexOf("/");
				owner = slug[0 .. slash];
				name = slug[slash + 1 .. $];
				h = host.length ? host : "github.com";
			}
			if (owner.length == 0) return;
			currentDbPath = databasePath(h, owner, name, root);
			detailEdit.text = "Opened " ~ h ~ "/" ~ owner ~ "/" ~ name ~
				"\nMode: " ~ repoModeLabel(h, owner, name, root) ~
				"\nDB: " ~ currentDbPath;
			if (exists(currentDbPath))
				refreshIssues();
		}

		addBtn.onClick = { refreshRepos(); };

		repoList.onItemClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repos.length) return;
			auto r = repos[idx];
			auto host = r.host.length ? r.host : "github.com";
			migrateLegacyDbIfNeeded(host, r.owner, r.name, r.path, root);
			currentDbPath = databasePath(host, r.owner, r.name, root);
			refreshIssues();
		};

		void doSync(RepoSyncMode mode) {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repos.length) return;
			auto r = repos[idx];
			SyncOptions opts;
			opts.includePrs = true;
			opts.archiveRoot = root;
			opts.mode = mode;
			opts.confirm = (string message) {
				detailEdit.text = "SYNC CONFIRMATION\n\n" ~ message;
				auto w = this.window;
				if (w is null) return false;
				w.showMessageBox(
					UIString.fromRaw("Confirm sync"d),
					UIString.fromRaw(to!dstring(message ~ "\n\nPress OK to continue."))
				);
				return true;
			};
			if (syncRepo(r.path, opts)) {
				auto host = r.host.length ? r.host : "github.com";
				if (mode == RepoSyncMode.backup)
					setBackupMode(r.owner ~ "/" ~ r.name, true, root);
				currentDbPath = databasePath(host, r.owner, r.name, root);
				refreshRepos();
				refreshIssues();
			}
		}

		syncBtn.onClick = { doSync(RepoSyncMode.index); };
		backupBtn.onClick = { doSync(RepoSyncMode.backup); };

		refreshBtn.onClick = {
			refreshRepos();
			if (currentDbPath.length > 0) refreshIssues();
		};

		issueList.onItemClick = {
			if (currentDbPath.length == 0 || itemIds.length == 0) return;
			int idx = issueList.selectedIndex;
			if (idx < 0 || idx >= itemIds.length) return;
			long iid = itemIds[idx];
			auto kind = itemKinds[idx];
			Database db = Database(currentDbPath);
			string text;
			if (kind == "discussion") {
				auto stmt = db.prepare("SELECT number, title, category, body, url, author FROM discussions WHERE id=?1");
				stmt.bind(1, iid);
				foreach (row; stmt.execute()) {
					text = "Discussion #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
						"Category: " ~ row.peek!string(2) ~ "\nAuthor: " ~ row.peek!string(5) ~ "\n" ~
						row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
					break;
				}
				stmt.reset();
				auto cstmt = db.prepare("SELECT author, created_at, body FROM discussion_comments WHERE discussion_id=?1 ORDER BY created_at");
				cstmt.bind(1, iid);
				foreach (crow; cstmt.execute())
					text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~ crow.peek!string(2);
				cstmt.reset();
			} else if (kind == "prtable") {
				auto stmt = db.prepare("SELECT number, title, state, body, url, author, merged FROM pull_requests WHERE id=?1");
				stmt.bind(1, iid);
				foreach (row; stmt.execute()) {
					text = "Pull Request #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
						"State: " ~ row.peek!string(2) ~ (row.peek!int(6) ? " (merged)" : "") ~ "\n" ~
						"Author: " ~ row.peek!string(5) ~ "\n" ~ row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
					break;
				}
				stmt.reset();
			} else {
				auto stmt = db.prepare("SELECT number, title, state, body, url, author, pr_accepted, state_reason FROM issues WHERE id=?1");
				stmt.bind(1, iid);
				foreach (row; stmt.execute()) {
					text = "Issue #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
						"State: " ~ row.peek!string(2) ~ (row.peek!string(7).length ? " (" ~ row.peek!string(7) ~ ")" : "") ~ "\n" ~
						"Author: " ~ row.peek!string(5) ~ (row.peek!int(6) ? " | PR merged" : "") ~ "\n" ~
						row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
					break;
				}
				stmt.reset();
				auto cstmt = db.prepare("SELECT author, created_at, body FROM comments WHERE issue_id=?1 ORDER BY created_at");
				cstmt.bind(1, iid);
				foreach (crow; cstmt.execute())
					text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~ crow.peek!string(2);
				cstmt.reset();
			}
			detailEdit.text = text;
		};

		if (openRepoSlug.length)
			openRepoBySlug(openRepoSlug, openHost);
	}
}
