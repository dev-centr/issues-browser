module issuetracker.types;

/// A discovered git repository (path and optional remote).
struct RepoInfo {
	string path;       /// Absolute or relative path to repo root
	string remote;     /// e.g. "https://github.com/owner/repo.git" or empty
	string owner;      /// GitHub owner (from remote)
	string name;       /// Repo name (from remote or folder name)
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

/// Comment row.
struct CommentRow {
	long id;
	long issueId;
	string body;
	string author;
	string createdAt;
}
