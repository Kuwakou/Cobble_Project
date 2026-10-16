# Live (production) path - not implemented

EDP's `database/live` path is the authorised production-deployment entry
point: real connection, deployment identity, backup/rollback controls,
change evidence, post-deployment checks. None of that infrastructure
exists for this course project (there is no real production tenant store,
release pipeline, or ops team), so there is nothing truthful to put in a
`build.sql` here.

This folder is kept as a placeholder so the module's shape matches the
three-path convention. If this project ever needs a real deployment
target, start from `../rls/build.sql` (the same schema/policy, since
production must run RLS) and add the deployment controls EDP describes
in its `docs/database-delivery-paths.md`, rather than writing a new schema.
