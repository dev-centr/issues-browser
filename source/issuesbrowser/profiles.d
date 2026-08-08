module issuesbrowser.profiles;

import std.algorithm : canFind;
import std.array;
import std.string;
// Selective import avoids clash with repoget.forge.ForgeProfile under some compilers.
import issuesbrowser.types : ForgeProfile;
import rg = repoget.forge;

private ForgeProfile[] gProfiles;
private bool gLoaded;

private ForgeProfile toLocal(rg.ForgeProfile p)
{
	ForgeProfile outP;
	outP.name = p.name;
	outP.matchers = p.matchers.dup;
	outP.cli = p.cli;
	outP.listIssuesCmd = p.listIssuesCmd.dup;
	outP.listPrsCmd = p.listPrsCmd.dup;
	outP.graphql = p.graphql;
	outP.minIntervalMs = p.minIntervalMs;
	outP.on429BackoffS = p.on429BackoffS;
	return outP;
}

void loadForgeProfiles(string root = null)
{
	gProfiles.length = 0;
	gLoaded = true;

	foreach (host; ["github.com", "gitlab.com"])
	{
		auto p = rg.getForge(host);
		if (p.name.length && !gProfiles.canFind!(x => x.name == p.name))
			gProfiles ~= toLocal(p);
	}

	if (gProfiles.length == 0)
		gProfiles ~= defaultGitHub();
}

ForgeProfile[] allForgeProfiles()
{
	if (!gLoaded)
		loadForgeProfiles();
	return gProfiles;
}

ForgeProfile resolveForge(string host)
{
	if (!gLoaded)
		loadForgeProfiles();
	auto h = host.length ? host : "github.com";
	auto p = rg.getForge(h);
	if (p.name.length)
		return toLocal(p);
	return defaultGitHub();
}

string[] interpolateCmd(string[] tmpl, string owner, string name, string host, string since = "")
{
	string[] outArgs;
	foreach (a; tmpl)
	{
		outArgs ~= a
			.replace("$OWNER", owner)
			.replace("$NAME", name)
			.replace("$HOST", host)
			.replace("$SINCE", since);
	}
	return outArgs;
}

private ForgeProfile defaultGitHub()
{
	ForgeProfile p;
	p.name = "github";
	p.matchers = ["github\\.com"];
	p.cli = "gh";
	p.listIssuesCmd = ["api", "repos/$OWNER/$NAME/issues", "--paginate", "--state", "all"];
	p.listPrsCmd = ["api", "repos/$OWNER/$NAME/pulls", "--paginate", "--state", "all"];
	p.graphql = true;
	p.minIntervalMs = 1000;
	p.on429BackoffS = 60;
	return p;
}
