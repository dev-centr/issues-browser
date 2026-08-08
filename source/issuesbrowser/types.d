module issuesbrowser.types;

/// A discovered git repository (path and optional remote).
struct RepoInfo {
	string path;       /// Absolute or relative path to repo root
	string remote;     /// e.g. "https://github.com/owner/repo.git" or empty
	string owner;      /// Forge owner (from remote)
	string name;       /// Repo name (from remote or folder name)
	string host;       /// e.g. "github.com", "gitlab.com"
	bool isFork;       /// From forge metadata when known
}

/// Options controlling sync volume and confirmation.
struct SyncOptions {
	bool force;                    /// Skip confirmation prompts
	bool includeDiscussions = true;
	bool includePrs = false;       /// Default: true issues only (exclude PRs)
	int warnThreshold = 500;       /// Soft warning size
	int requireConfirmThreshold = 2000; /// Require explicit approval at/above this
	bool delegate(string message) confirm; /// Return true to proceed
}

/// Preflight counts from the forge (before downloading bodies).
struct SyncPreflight {
	int issueCount;
	int discussionCount;
	int prCount;
	bool isFork;
	string parentNameWithOwner;
	string summaryMessage;
	bool needsConfirm;
}

/// Issue row as stored and queried.
struct IssueRow {
	long id;
	long repoId;
	int number;
	string title;
	string state;      /// "OPEN" | "CLOSED"
	string body;
	string url;
	string createdAt;
	string closedAt;
	string author;
	bool prAccepted;   /// true if closed by merged PR
	string stateReason; /// e.g. "duplicate", "completed"
}

/// Comment row (issue or discussion).
struct CommentRow {
	long id;
	long parentId;     /// issue id or discussion id
	string body;
	string author;
	string createdAt;
}

/// Discussion row.
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
