module app_gui;

import dlangui;
import std.path;
import std.file;
import std.conv;
import std.algorithm;
import issuetracker.gitdiscover;
import issuetracker.sync;
import issuetracker.database;
import d2sqlite3;

mixin APP_ENTRY_POINT;

extern (C) int UIAppMain(string[] args) {
	FontManager.fontGamma = 0.8;
	FontManager.hintingMode = HintingMode.Normal;
	Window window = Platform.instance.createWindow("Issue Tracker"d, null, WindowFlag.Resizable, 900, 600);
	window.mainWidget = new IssueTrackerFrame();
	window.show();
	return Platform.instance.enterMessageLoop();
}

class IssueTrackerFrame : Widget {
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
			if (currentDbPath.length == 0 || !exists(currentDbPath)) return;
			Database db = Database(currentDbPath);
			auto r = db.execute("SELECT id, number, title, state FROM issues ORDER BY number DESC");
			foreach (row; r) {
				issueIds ~= row.peek!long(0);
				int num = row.peek!int(1);
				string title = row.peek!string(2);
				string state = row.peek!string(3);
				issueList.items ~= ("#" ~ to!string(num) ~ " " ~ title ~ " [" ~ state ~ "]");
			}
			issueList.updateItems();
		}

		addBtn.onClick = {
			refreshRepos();
		};

		repoList.onItemClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repoPaths.length) return;
			string parentDir = dirName(repoPaths[idx]);
			string rname = repoNames[idx];
			currentDbPath = buildPath(parentDir, ".issues", rname ~ ".sqlite");
			currentRepoId = -1;
			refreshIssues();
		};

		syncBtn.onClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repoPaths.length) return;
			string parentDir = dirName(repoPaths[idx]);
			string rname = repoNames[idx];
			syncRepo(repoPaths[idx], parentDir, rname);
			currentDbPath = buildPath(parentDir, ".issues", rname ~ ".sqlite");
			refreshIssues();
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
			Database db = Database(currentDbPath);
			auto stmt = db.prepare("SELECT number, title, state, body, url, author, pr_accepted, state_reason FROM issues WHERE id=?1");
			stmt.bind(1, iid);
			auto r = stmt.execute();
			string text;
			foreach (row; r) {
				text = "Issue #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
					"State: " ~ row.peek!string(2) ~ (row.peek!string(7).length ? " (" ~ row.peek!string(7) ~ ")" : "") ~ "\n" ~
					"Author: " ~ row.peek!string(5) ~ (row.peek!int(6) ? " | PR merged" : "") ~ "\n" ~ row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
				break;
			}
			stmt.reset();
			auto cstmt = db.prepare("SELECT author, created_at, body FROM comments WHERE issue_id=?1 ORDER BY created_at");
			cstmt.bind(1, iid);
			foreach (crow; cstmt.execute()) {
				text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~ crow.peek!string(2);
			}
			cstmt.reset();
			detailEdit.text = text;
		};
	}
}
