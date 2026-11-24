# apps/

Each application built on the Gluon platform lives here as its own **independent
git repository** — `apps/gfood/`, `apps/ggrocery/`, etc. — pushed to its own GitHub remote
(`beckfordp/<name>`), with its own `/conductor`, user stories, ADRs and acceptance
suite.

gshop, the exemplar the platform was built with, stays part of the platform
(`frontends/gshop`, `services/`).

An application builds on gluon's services, tools, libraries and ways of working.
Reuse is harvested: a gluon service as it is where it fits; copied into
`apps/<app>/services/` with the app's prefix (`gf-order-service-rs`) where the app needs
changes; generic changes raised as change requests in the gluon service's backlog
(gfood's [README](https://github.com/beckfordp/gfood#reuse-is-harvested)). An app's own
services are repos under `apps/<app>/services/`, one per service.

This directory is **not** tracked by gluon's own git repo (see `.gitignore`), bar
this README. `bin/sandbox-export --app <app>` carries one app to a sandbox session of its
own, and `bin/sandbox-save` brings its commits back (`bin/lib/sandbox.py`).
