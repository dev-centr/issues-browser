module issuesbrowser.types;

/// A discovered git repository (path and optional remote).
struct RepoInfo {
	string path;
	string remote;
	string owner;
	string name;
	string host;
	bool isFork;
}

/// Index = lightweight listings; Backup = full bodies/comments archive.
enum RepoSyncMode {
	index,
	backup
}

/// Options controlling sync volume and confirmation.
struct SyncOptions {
	bool force;
	bool includeDiscussions = true;
	bool includePrs = true;        /// PRs on by default (issue history)
	int warnThreshold = 500;
	int requireConfirmThreshold = 2000;
	string archiveRoot;            /// override central .issues root
	RepoSyncMode mode = RepoSyncMode.index; /// default: index cache only
	bool delegate(string message) confirm;
}

struct SyncPreflight {
	int issueCount;
	int discussionCount;
	int prCount;
	bool isFork;
	string parentNameWithOwner;
	string summaryMessage;
	bool needsConfirm;
}

struct IssueRow {
	long id;
	long repoId;
	int number;
	string title;
	string state;
	string body;
	string url;
	string createdAt;
	string closedAt;
	string author;
	bool prAccepted;
	string stateReason;
	bool isPr;
	string updatedAt;
}

struct CommentRow {
	long id;
	long parentId;
	string body;
	string author;
	string createdAt;
}

struct DiscussionRow {
	long id;
	long repoId;
	int number;
	string title;
	string category;
	string body;
	string url;
	string createdAt;
	string author;
}

struct MonitoredRepo {
	string host;
	string owner;
	string name;
	string remote;
	int pollIntervalSec = 300;
	string lastSync;
	string lastError;
	bool enabled = true;
	bool backup = false; /// false => index-only; true => index + full backup
}

struct ForgeProfile {
	string name;
	string[] matchers;
	string cli;
	string[] listIssuesCmd;
	string[] listPrsCmd;
	string[] listDiscussionsHint;
	bool graphql;
	int minIntervalMs = 1000;
	int on429BackoffS = 60;
}
