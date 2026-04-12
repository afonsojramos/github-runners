FROM postgres:17

# GitHub Actions services: blocks can't override the postgres CMD args, so
# tuning has to be baked in. Used by parallel E2E suites that exhaust the
# default 100-connection pool.
CMD ["postgres", "-c", "max_connections=300"]
