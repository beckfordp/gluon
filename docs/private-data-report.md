# Private data report (2026-11-10)

A check of the gluon delivery (`gluon-20261110.tar.gz`) for personal data,
secrets and machine-specific details, made before it went for review. It
covers the whole tree: gluon's own files and every repo under `services/`,
`tests/`, `frontends/`, `lib/` and `tools/`.

**Result:** there are no live credentials and no personal data. The
captured tokens and a laptop path were replaced with placeholders (below).
What remains is of three kinds:

- made-up test data;
- local-development defaults;
- the project's public GitHub name.

## How it was checked

Each file in the delivery was searched for:

- e-mail addresses;
- home-directory paths (`/Users/…`, `/home/…`);
- the owner's name and user name;
- `password`/`token`/`secret`/`key` assignments and JSON fields;
- bearer and authorization headers;
- private keys, cloud and GitHub tokens, JWTs;
- 43-character opaque tokens;
- PBKDF2 hashes.

Files the delivery leaves out were not checked: `.git`, build output and
anything gitignored.

## Changed to placeholders

| Where | Was | Now |
|---|---|---|
| `tests/contract/contracts/user-service/20261109/http/signup-201.txt`, `login-200.txt`, `signup-text-plain.txt`, `signup-no-content-type.txt`, `traceparent-signup.txt` | the access and refresh tokens the Scala service issued during the capture | `EXAMPLE-access-token-<exchange>-not-real-…` and `EXAMPLE-refresh-token-login-200-not-real-00`. Each placeholder keeps the token shape (43 base64url characters), so `Content-Length` and the checks are unchanged. |
| `tests/contract/contracts/user-service/20261109/stdout.log`, line 2 | the owner's laptop path in a JVM warning | `/Users/<user>/<path-to>/gluon/…` |
| `tests/contract/tests/unit/test_formats.py` | one of those captured tokens, used as a valid-token example | `EXAMPLE-access-token-signup-201-not-real-00` |
| `services/user-service-rs/crates/user-service/tests/domain.rs` | `a@b.co` and `first+tag@sub.example.co.uk`: real, registered domains | `a@b.example`, `first+tag@sub.example.com` |

`tests/contract/contracts/user-service/CAPTURE.md` ("Edits after capture")
records the changes to the capture.

## What remains, and why it's fine

### Example test data

| What | Where | Why it's not private |
|---|---|---|
| E-mail addresses: `capture.kat@`, `ada@`, `grace@`, `alan@`, `jane@`, `kat@`, `guest@`, `user@`, `nobody@` and others, all at `example.com`, plus the demo personas `ada.demo@`, `grace.demo@`, `alan.demo@` | tests, capture, docs, examples in the API docs, `bin/seed-demo-data` | `example.com` is reserved for documentation and testing (RFC 2606): no mailbox exists. The names are made up. |
| Shape-only addresses: `a@b.example`, `a@b.c`, `x@y.z.`, `local@host.tld`, `local@domain.tld` | e-mail validation tests and doc comments | These only exercise the address format. `.example` is a reserved name (RFC 2606), and the others aren't real domains. |
| Passwords: `correct-horse-battery-1`, `correct-horse-battery-staple`, `correct-horse-1`, `correct horse battery`, `wrong-password-1`, `another-password`, `12345678`, `short` | capture (`CAPTURE.md`, `http/*.txt`), Rust and harness tests, Scala tests and verify scripts, API-doc examples | Written for tests, and published in the tests themselves. None protects anything. |
| PBKDF2 hashes (`pbkdf2$210000$…`) | capture `db-user-account.txt`; `user-service-rs/.../tests/hashing.rs`; `tests/contract/tests/unit/test_formats.py` | Hashes of the published test password `correct-horse-battery-1` for the capture's test accounts. They are kept because a check depends on them: a password hashed by the Scala service must log in to the Rust one (ADR 0028 decision 5). |
| Token placeholders: `example-access-token-not-valid`, `example-refresh-token-not-valid`, `EXAMPLE-…-not-real-…` | API-doc examples (Scala and Rust), capture | Placeholders; no service issued them. |
| User, order and trace IDs (random UUIDs, hex trace IDs) | capture, tests | Random identifiers for test records in throw-away databases. |
| Token rows `access\|64\|00:59:59.97` | capture `db-auth-tokens.txt` | Only each token's kind, hash length and lifetime; no token or hash values. |

### Local-development defaults

| What | Where | Why it's fine |
|---|---|---|
| Postgres user/password equal to the service name (`user`/`user`, `catalog`, `notification`, `fulfilment`, …) | `environments/local/*.values.yaml`, each service's `application.conf`, `docker-compose.yml` and tests, Rust test support | Defaults for throw-away local and test databases, one pattern across the services. |
| `dev-operator-token` | `services/fulfilment-service` config and tests | A named development default for the local operator endpoint. |
| `POSTGRES_PASSWORD=p`, `SECRET=no`, `HOME=/home/x` | harness and Rust unit tests | Dummy values in tests that check configuration and environment handling. |

### Project identity and the sandbox

| What | Where | Why it's fine |
|---|---|---|
| GitHub user `beckfordp` | READMEs, ADRs, `build.sbt` (`io.github.beckfordp` artifacts), CI workflows, dashboard links in `infra/k8s` | The project's public GitHub account and package namespace; deliberately public. |
| `gluon sandbox <sandbox@gluon.local>` | `bin/sandbox-setup`, `plans/private/sandbox.md` | The git identity for commits made in the sandbox. `.local` isn't a routable domain. |
| `/home/model`, `/home/claude/.local/bin` | `plans/private/sandbox.md`, `bin/verify-port user-service`, a harness unit test | Paths inside the sandbox machine, not anyone's computer. |
| `support@asyncapi.org`, `i@izs.me` | generated AsyncAPI HTML, `frontends/gshop/package-lock.json` | Contacts of upstream open-source projects, published in their packages. |

## Left out of the delivery

These are gitignored, so they are not in the archive. Copies stay on the
owner's laptop:

- IDE and editor state (`.idea/`, `.obsidian/`, `.DS_Store`). The `.idea`
  files hold about 110 copies of the laptop's home path.
- `frontends/gshop/.env`, which holds in-cluster service URLs only.
- `.seed-demo-data.state.json`.
- `tests/*/.claude/`.
- `tools/pure-service-generator/.dev/`.

The build output deleted before the delivery also held laptop paths: the sbt
`.bsp/sbt.json` files and the coverage reports in `frontends/gshop` and
`tests/acceptance`.

The delivery has no git history. In the sandbox, the earlier commits of
`tests/contract` still hold the original capture values. If that history is
ever published, filter those values out first, or publish from a fresh
history.
