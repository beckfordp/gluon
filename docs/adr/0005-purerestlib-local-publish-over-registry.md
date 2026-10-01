# 0005. Use `sbt publishLocal` for purerestlib in local dev, not a registry

## Status
Accepted

## Context
Every generated service (`order-service`, `inventory-service`,
`payment-service`, `catalog-service`, `notification-service`,
`cart-service`) depends on `purerestlib`, published from the `purerest`
repo. The generated `build.sbt` resolves it from GitHub Packages
(`https://maven.pkg.github.com/beckfordp/purerest`), which requires a
`read:packages` personal access token even though `purerest` is a public
repo — a GitHub product limitation, not a misconfiguration. In practice this
meant exporting `GITHUB_TOKEN`/`GITHUB_ACTOR` in every shell before building,
and GUI tools (IntelliJ IDEA) not inheriting those vars when launched outside
a terminal, needing `launchctl setenv` or a direct-binary launch workaround.

Options considered:
- **GitHub Packages** (status quo) — already wired into every generated
  `build.sbt`; requires a PAT everywhere, including IDEA launches.
- **`sbt publishLocal`** — publishes `purerestlib` to `~/.ivy2/local`, which
  sbt checks before any remote resolver. No credentials, no env vars, works
  in IDEA unmodified. Requires re-running `publishLocal` after any
  `purerest` change, and gives no resolution path for a machine that's never
  built `purerest` locally (CI).
- **JitPack** — resolves `purerestlib` straight from GitHub tags, no auth
  for a public repo, no publish step. `purerest` already uses `sbt-dynver`
  (git-tag-derived versions), so it's a good fit if adopted later. Not
  pursued now — would need coordinate/resolver changes in
  `pure-service-generator`'s template and all six already-generated
  services' `build.sbt`.
- **Maven Central** — the "real" zero-auth-forever option. Namespace
  (`io.github.beckfordp`) can self-verify via Sonatype's GitHub-based flow;
  needs GPG-signed artifacts and POM metadata, typically via `sbt-ci-release`.
  Meaningful one-time setup cost (GPG key, CI secret, release workflow); not
  pursued now.

## Decision
Use **`sbt publishLocal`** as the default local-dev resolution path for
`purerestlib` — run it in `purerest` after any change, before building a
dependent service (including opening one in IDEA). Keep the existing GitHub
Packages resolver/credentials in generated `build.sbt` files as-is, as the
fallback for CI or any machine without a local `purerest` checkout — do not
remove it.

This is explicitly a **for-now** decision, not a final one. JitPack and
Maven Central remain open options if the GitHub Packages fallback itself
becomes a problem (e.g. for CI, or for anyone else consuming `purerest`) —
revisit with a new ADR superseding this one if either is adopted.

## Consequences
- Local dev (including IntelliJ IDEA) needs no `GITHUB_TOKEN`/`GITHUB_ACTOR`
  and no Keychain/`launchctl` setup for the common case.
- Must remember to re-run `sbt publishLocal` in `purerest` after pulling or
  making changes there, or a dependent service silently builds against a
  stale local jar.
- CI and fresh-machine builds still depend on the GitHub Packages token flow
  — unchanged, token stored in macOS Keychain (`gluon-github-token`).
- JitPack/Maven Central migration deferred; no code changes made to
  `pure-service-generator`'s template or any generated service's `build.sbt`
  as part of this decision.
