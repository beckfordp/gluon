Paste into `conductor/tracks.md`'s `## Backlog` section after `/conductor:setup`.

- TD-1.2: No CORS support — see `../TECHNICAL_DEBT.md`, cross-cutting,
  shared writeup there. Port once `pure-service-generator`'s own
  backlog item (TD-1.1, generator-level fix) lands.
- Generate cart-service bare scaffold, no field-spec applied (infra)
- Design the Redis cart data model (line items) and drop the generated Postgres layer (infra)
- US-2.1: add/remove items in a cart
