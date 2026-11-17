FROM postgres:16

# Patroni from Debian packages (no pip, no build tools in the image)
RUN apt-get update \
 && apt-get install -y --no-install-recommends patroni python3-etcd python3-psycopg2 curl \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/lib/postgresql/patroni \
 && chown postgres:postgres /var/lib/postgresql/patroni \
 && chmod 700 /var/lib/postgresql/patroni

COPY --chown=postgres:postgres patroni.yml /etc/patroni/patroni.yml

USER postgres
EXPOSE 5432 8008
HEALTHCHECK --interval=5s --timeout=3s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8008/liveness || exit 1
ENTRYPOINT ["patroni", "/etc/patroni/patroni.yml"]
