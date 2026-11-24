# Release notes

Each release has one file here, `vX.Y.Z.md`, named for the version in
`VERSION`, and `bin/release` refuses to publish without it. It lands on
`development` in the same commit as the version bump, the last commit before
`main` is fast-forwarded for the release. It holds the changes since the last
tag, grouped by what a user notices: each group a `###` heading led by an
emoji, with two or three bullets. Draft it from `git log <last tag>..HEAD`,
check every bullet against its commit, and let Kelly edit it. `bin/release`
puts install steps above it and publishes the result as the GitHub release's
description, under "What's new".

The notes are public, so the disclosure rule in `CLAUDE.md` applies to them as
to the code: no profile names, addresses, identity providers, usernames,
hostnames or employers, even to describe a fix. `bin/release` runs the
disclosure audit, with the literal denylist, over this file and over the
description it publishes, and refuses on any match.
