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
import d2sqlite3;

mixin APP_ENTRY_POINT;

extern (C) int UIAppMain(string[] args) {
	FontManager.fontGamma = 0.8;
	FontManager.hintingMode = HintingMode.Normal;
	Window window = Platform.instance.createWindow("Issues Browser"d, null, WindowFlag.Resizable, 900, 600);
	window.mainWidget = new IssuesBrowserFrame();
	window.show();
	return Platform.instance.enterMessageLoop();
}

class IssuesBrowserFrame : Widget {
	this() {
		HorizontalLayout topBar = new HorizontalLayout();
		LineEdit folderEdit = new LineEdit();
		folderEdit.placeholder = "Path to folder of git repos";
		folderEdit.preferredWidth = 400;
		Button addBtn = new Button("Add folder");
		Button syncBtn = new Button("Sync selected");
		Button refreshBtn = new Button("Refresh list");
		topBar.addChild(folderEdit);
		topBar.addChild(addBtn);
		topBar.addChild(syncBtn);
		topBar.addChild(refreshBtn);

		ListView repoList = new ListView();
		repoList.preferredWidth = 220;
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

		string[] repoNames;
		string[] repoPaths;
		string currentDbPath;
		long[] issueIds;
		bool[] isDiscussion; // parallel to issueIds

		void refreshRepos() {
			repoList.items.clear();
			repoNames = [];
			repoPaths = [];
			string path = folderEdit.text.to!string.strip();
			if (path.length == 0) return;
			auto repos = discoverRepos(path);
			foreach (r; repos) {
				string label = r.name;
				if (r.owner.length > 0) label = r.owner ~ "/" ~ label;
				repoList.items ~= label;
				repoNames ~= r.name;
				repoPaths ~= r.path;
			}
			repoList.updateItems();
		}

		void refreshIssues() {
			issueList.items.clear();
			issueIds = [];
			isDiscussion = [];
			if (currentDbPath.length == 0 || !exists(currentDbPath)) return;
			Database db = Database(currentDbPath);
			foreach (row; db.execute("SELECT id, number, title, state FROM issues ORDER BY number DESC")) {
				issueIds ~= row.peek!long(0);
				isDiscussion ~= false;
				issueList.items ~= ("#" ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~ " [" ~ row.peek!string(3) ~ "]");
			}
			foreach (row; db.execute("SELECT id, number, title, category FROM discussions ORDER BY number DESC")) {
				issueIds ~= row.peek!long(0);
				isDiscussion ~= true;
				string cat = row.peek!string(3);
				issueList.items ~= ("D#" ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~ (cat.length ? " [" ~ cat ~ "]" : ""));
			}
			issueList.updateItems();
		}

		addBtn.onClick = {
			refreshRepos();
		};

		repoList.onItemClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repoPaths.length) return;
			string rpath = repoPaths[idx];
			string rname = repoNames[idx];
			migrateLegacyDbIfNeeded(rpath, rname);
			currentDbPath = databasePath(rpath);
			refreshIssues();
		};

		syncBtn.onClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repoPaths.length) return;
			string rpath = repoPaths[idx];
			SyncOptions opts;
			// Preflight large/fork syncs; user must confirm in the detail pane flow via Yes/No dialog when available.
			opts.confirm = (string message) {
				detailEdit.text = "SYNC CONFIRMATION REQUIRED\n\n" ~ message ~
					"\n\nClick Sync selected again after setting force via CLI (--yes), or approve if a dialog appears.";
				auto w = this.window;
				if (w is null) return false;
				auto res = w.showMessageBox(
					UIString.fromRaw("Confirm sync"d),
					UIString.fromRaw(to!dstring(message ~ "\n\nContinue?")),
					[ButtonDetails(ACTION_YES, "Yes"d), ButtonDetails(ACTION_NO, "No"d)]
				);
				return res == ACTION_YES;
			};
			if (syncRepo(rpath, opts)) {
				currentDbPath = databasePath(rpath);
				refreshIssues();
			}
		};

		refreshBtn.onClick = {
			refreshRepos();
			if (currentDbPath.length > 0) refreshIssues();
		};

		issueList.onItemClick = {
			if (currentDbPath.length == 0 || issueIds.length == 0) return;
			int idx = issueList.selectedIndex;
			if (idx < 0 || idx >= issueIds.length) return;
			long iid = issueIds[idx];
			bool disc = isDiscussion[idx];
			Database db = Database(currentDbPath);
			string text;
			if (!disc) {
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
				foreach (crow; cstmt.execute()) {
					text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~ crow.peek!string(2);
				}
				cstmt.reset();
			} else {
				auto stmt = db.prepare("SELECT number, title, category, body, url, author FROM discussions WHERE id=?1");
				stmt.bind(1, iid);
				foreach (row; stmt.execute()) {
					text = "Discussion #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
						"Category: " ~ row.peek!string(2) ~ "\n" ~
						"Author: " ~ row.peek!string(5) ~ "\n" ~
						row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
					break;
				}
				stmt.reset();
				auto cstmt = db.prepare("SELECT author, created_at, body FROM discussion_comments WHERE discussion_id=?1 ORDER BY created_at");
				cstmt.bind(1, iid);
				foreach (crow; cstmt.execute()) {
					text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~ crow.peek!string(2);
				}
				cstmt.reset();
			}
			detailEdit.text = text;
		};
	}
}
