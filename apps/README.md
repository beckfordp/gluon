# apps/

Each application built on the Gluon platform lives here as its own **independent
git repository** — `apps/gfood/`, etc. — pushed to its own GitHub remote
(`beckfordp/<name>`), with its own `/conductor`, user stories, ADRs and acceptance
suite ([ADR 0031](../docs/adr/0031-multi-app-platform.md)).

gshop, the exemplar the platform was built with, stays part of the platform
(`frontends/gshop`, `services/`).

An application uses the platform services in `../services/` (listed in its
`app.yaml`) and never copies them. Its own services are repos under
`apps/<app>/services/`, one per service.

This directory is **not** tracked by gluon's own git repo (see `.gitignore`), bar
this README. `bin/sandbox-export` carries `apps/gfood` to the sandbox and
`bin/sandbox-save` brings its commits back (`bin/lib/sandbox.py`).
