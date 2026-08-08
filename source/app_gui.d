module app_gui;

import dlangui;
import std.path;
import std.file;
import std.conv;
import std.algorithm;
import std.string;
import issuesbrowser;
import d2sqlite3;

mixin APP_ENTRY_POINT;

extern (C) int UIAppMain(string[] args) {
	FontManager.fontGamma = 0.8;
	FontManager.hintingMode = HintingMode.Normal;
	Window window = Platform.instance.createWindow("Issues Browser"d, null, WindowFlag.Resizable, 960, 640);
	window.mainWidget = new IssuesBrowserFrame();
	window.show();
	return Platform.instance.enterMessageLoop();
}

class IssuesBrowserFrame : Widget {
	this() {
		HorizontalLayout topBar = new HorizontalLayout();
		LineEdit folderEdit = new LineEdit();
		folderEdit.placeholder = "Path to folder of git repos";
		folderEdit.preferredWidth = 360;
		Button addBtn = new Button("Add folder");
		Button syncBtn = new Button("Sync selected");
		Button refreshBtn = new Button("Refresh");
		CheckBox allowLarge = new CheckBox("Allow large sync");
		topBar.addChild(folderEdit);
		topBar.addChild(addBtn);
		topBar.addChild(syncBtn);
		topBar.addChild(allowLarge);
		topBar.addChild(refreshBtn);

		ListView repoList = new ListView();
		repoList.preferredWidth = 240;
		ListView issueList = new ListView();
		issueList.preferredWidth = 360;
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
		long[] itemIds;
		bool[] itemIsDiscussion;

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
				if (exists(databasePath(r.path))) label ~= " ●";
				repoList.items ~= label;
				repoNames ~= r.name;
				repoPaths ~= r.path;
			}
			repoList.updateItems();
		}

		void refreshItems() {
			issueList.items.clear();
			itemIds = [];
			itemIsDiscussion = [];
			if (currentDbPath.length == 0 || !exists(currentDbPath)) return;
			Database db = Database(currentDbPath);
			foreach (row; db.execute("SELECT id, number, title, state FROM issues ORDER BY number DESC")) {
				itemIds ~= row.peek!long(0);
				itemIsDiscussion ~= false;
				issueList.items ~= ("#" ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~
					" [" ~ row.peek!string(3) ~ "]");
			}
			foreach (row; db.execute("SELECT id, number, title, category FROM discussions ORDER BY number DESC")) {
				itemIds ~= row.peek!long(0);
				itemIsDiscussion ~= true;
				string cat = row.peek!string(3);
				issueList.items ~= ("D#" ~ to!string(row.peek!int(1)) ~ " " ~ row.peek!string(2) ~
					(cat.length ? " [" ~ cat ~ "]" : ""));
			}
			issueList.updateItems();
		}

		addBtn.onClick = { refreshRepos(); };

		repoList.onItemClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repoPaths.length) return;
			currentDbPath = databasePath(repoPaths[idx]);
			refreshItems();
		};

		syncBtn.onClick = {
			int idx = repoList.selectedIndex;
			if (idx < 0 || idx >= repoPaths.length) return;
			SyncOptions opt;
			opt.force = allowLarge.checked;
			opt.includeDiscussions = true;
			auto res = syncRepo(repoPaths[idx], opt);
			detailEdit.text = res.message;
			currentDbPath = databasePath(repoPaths[idx]);
			if (res.ok) refreshItems();
		};

		refreshBtn.onClick = {
			refreshRepos();
			if (currentDbPath.length > 0) refreshItems();
		};

		issueList.onItemClick = {
			if (currentDbPath.length == 0 || itemIds.length == 0) return;
			int idx = issueList.selectedIndex;
			if (idx < 0 || idx >= itemIds.length) return;
			long iid = itemIds[idx];
			bool isDisc = itemIsDiscussion[idx];
			Database db = Database(currentDbPath);
			string text;
			if (!isDisc) {
				auto stmt = db.prepare(
					"SELECT number, title, state, body, url, author, pr_accepted, state_reason FROM issues WHERE id=?1"
				);
				stmt.bind(1, iid);
				foreach (row; stmt.execute()) {
					text = "Issue #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
						"State: " ~ row.peek!string(2) ~
						(row.peek!string(7).length ? " (" ~ row.peek!string(7) ~ ")" : "") ~ "\n" ~
						"Author: " ~ row.peek!string(5) ~ (row.peek!int(6) ? " | PR merged" : "") ~ "\n" ~
						row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
					break;
				}
				stmt.reset();
				auto cstmt = db.prepare(
					"SELECT author, created_at, body FROM comments WHERE issue_id=?1 ORDER BY created_at"
				);
				cstmt.bind(1, iid);
				foreach (crow; cstmt.execute()) {
					text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~
						crow.peek!string(2);
				}
				cstmt.reset();
			} else {
				auto stmt = db.prepare(
					"SELECT number, title, category, body, url, author FROM discussions WHERE id=?1"
				);
				stmt.bind(1, iid);
				foreach (row; stmt.execute()) {
					text = "Discussion #" ~ to!string(row.peek!int(0)) ~ " " ~ row.peek!string(1) ~ "\n" ~
						"Category: " ~ row.peek!string(2) ~ "\n" ~
						"Author: " ~ row.peek!string(5) ~ "\n" ~
						row.peek!string(4) ~ "\n\n" ~ row.peek!string(3);
					break;
				}
				stmt.reset();
				auto cstmt = db.prepare(
					"SELECT author, created_at, body FROM discussion_comments WHERE discussion_id=?1 ORDER BY created_at"
				);
				cstmt.bind(1, iid);
				foreach (crow; cstmt.execute()) {
					text ~= "\n\n--- " ~ crow.peek!string(0) ~ " " ~ crow.peek!string(1) ~ " ---\n" ~
						crow.peek!string(2);
				}
				cstmt.reset();
			}
			detailEdit.text = text;
		};
	}
}
