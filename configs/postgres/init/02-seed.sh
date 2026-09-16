#!/bin/bash
# ============================================================================
# Seed the PowerDNS zones.
#
# Runs automatically from /docker-entrypoint-initdb.d/ on FIRST initialisation
# of an empty PostgreSQL data directory only. Re-running the stack does NOT
# re-run it -- the 1M rows live in the named volume.
#
# RE-RUNNABLE. It can also be executed by hand against a live database to
# reseed without dropping the volume:
#   docker exec -e IOT_MOCK_IP=... -e DNS_RECORD_COUNT=... -e DNS_ZONE=... \
#       poc-postgres bash /docker-entrypoint-initdb.d/02-seed.sh
# It starts by deleting the two zones it owns (see the DELETE below), which
# cascades to their records, so a second run replaces rather than collides.
# To rebuild everything from nothing instead: docker compose down -v
#
# WHAT IT CREATES
#   test.domain           1,000,000 A records, iot0000001..iot1000000, all
#                         pointing at the IoT Mock, PLUS the SSRF corpus.
#   servfail.test.domain  an empty NATIVE zone, so a SERVFAIL can be produced
#                         deliberately for the DNS-failure tests.
#
# The dataset is generated IN-DATABASE with generate_series rather than loaded
# from a file: at 1M rows the file would be ~100 MB and would have to cross the
# 9p boundary from /mnt/c into the container. Measured seed time: ~27 s.
#
# NOTE ON THE SSRF CORPUS
#   Every name below resolves into an address class that a destination policy
#   is expected to REFUSE. The corpus is what makes the security tests test real
#   resolution rather than hypotheticals. ssrf-rebind deliberately carries TWO
#   A records -- one permitted, one forbidden -- so a name-based check would
#   pass while an address-based check catches it.
# ============================================================================
set -euo pipefail

: "${IOT_MOCK_IP:?IOT_MOCK_IP is required — the IoT Mock address the namespace resolves to}"
: "${DNS_ZONE:=test.domain}"
: "${DNS_RECORD_COUNT:=1000000}"
: "${POSTGRES_USER:=pdns}"
: "${POSTGRES_DB:=pdns}"

echo "[seed] zone=${DNS_ZONE} records=${DNS_RECORD_COUNT} iot_endpoint=${IOT_MOCK_IP}"

psql -v ON_ERROR_STOP=1 --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}" \
     -v zone="${DNS_ZONE}" -v iot="${IOT_MOCK_IP}" -v n="${DNS_RECORD_COUNT}" <<'EOSQL'

-- --- make this script re-runnable -----------------------------------------
-- Without this, a second run dies on the very next statement with
--   duplicate key value violates unique constraint "name_index"
-- because domains.name is UNIQUE (name_index) and the zone already exists.
-- Deleting the domain cascades to its records -- records.domain_id has
-- ON DELETE CASCADE -- so one statement clears both zones completely.
--
-- DESTRUCTIVE, but only for the two zones this script owns: any other zone
-- present in the database is untouched. On a first-boot run both DELETEs
-- match nothing and cost nothing.
DELETE FROM domains WHERE name IN (:'zone', 'servfail.test.domain');

-- --- zones ---------------------------------------------------------------
INSERT INTO domains (name, type) VALUES (:'zone', 'NATIVE');
INSERT INTO domains (name, type) VALUES ('servfail.test.domain', 'NATIVE');

-- --- zone apex: SOA + NS --------------------------------------------------
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT id, :'zone', 'SOA',
       'ns1.' || :'zone' || ' hostmaster.' || :'zone' || ' 1 10800 3600 604800 3600',
       3600, 0, false, ''
FROM domains WHERE name = :'zone';

INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT id, :'zone', 'NS', 'ns1.' || :'zone', 3600, 0, false, ''
FROM domains WHERE name = :'zone';

-- ns1 is the apex nameserver; it resolves to the IoT Mock like everything else.
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT id, 'ns1.' || :'zone', 'A', :'iot', 3600, 0, false, ''
FROM domains WHERE name = :'zone';

-- --- the IoT namespace: 1,000,000 A records -------------------------------
-- Generated in-database; iot0000001 .. iot<NNNNNNN>.
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT d.id,
       'iot' || lpad(g::text, 7, '0') || '.' || :'zone',
       'A', :'iot', 3600, 0, false, ''
FROM domains d, generate_series(1, :'n'::int) g
WHERE d.name = :'zone';

-- --- SSRF corpus: IPv4 ----------------------------------------------------
-- Each resolves into a class the destination policy must refuse.
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT d.id, v.name, 'A', v.ip, 3600, 0, false, ''
FROM domains d,
     (VALUES
        ('ssrf-loopback.'      || :'zone', '127.0.0.1'),
        ('ssrf-loopback-alt.'  || :'zone', '127.1.2.3'),
        ('ssrf-private10.'     || :'zone', '10.0.0.5'),
        ('ssrf-private172.'    || :'zone', '172.16.5.5'),
        ('ssrf-private192.'    || :'zone', '192.168.1.5'),
        ('ssrf-linklocal.'     || :'zone', '169.254.1.1'),
        ('ssrf-cgnat.'         || :'zone', '100.64.0.5'),
        ('ssrf-unspecified.'   || :'zone', '0.0.0.0'),
        ('ssrf-thisnet.'       || :'zone', '0.1.2.3'),
        ('ssrf-multicast.'     || :'zone', '224.0.0.1'),
        ('ssrf-broadcast.'     || :'zone', '255.255.255.255'),
        ('ssrf-reserved.'      || :'zone', '240.0.0.1'),
        ('ssrf-benchmark.'     || :'zone', '198.18.0.1')
     ) AS v(name, ip)
WHERE d.name = :'zone';

-- ssrf-rebind carries TWO A records: one permitted, one forbidden. A name-based
-- check passes here; only an address-based check catches it.
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT d.id, 'ssrf-rebind.' || :'zone', 'A', v.ip, 3600, 0, false, ''
FROM domains d,
     (VALUES ('127.0.0.1'), (:'iot')) AS v(ip)
WHERE d.name = :'zone';

-- --- SSRF corpus: IPv6 ----------------------------------------------------
-- TARGET's resolver is IPv4-pinned, so these fail to resolve there and are
-- rejected fail-closed. They exist so the IPv6 gap is exercised rather than
-- assumed away.
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled, ordername)
SELECT d.id, v.name, 'AAAA', v.ip6, 3600, 0, false, ''
FROM domains d,
     (VALUES
        ('ssrf-loopback6.'      || :'zone', '::1'),
        ('ssrf-linklocal6.'     || :'zone', 'fe80::1'),
        ('ssrf-ula6.'           || :'zone', 'fc00::1'),
        ('ssrf-ula6b.'          || :'zone', 'fd12:3456::1'),
        ('ssrf-multicast6.'     || :'zone', 'ff02::1'),
        ('ssrf-unspecified6.'   || :'zone', '::'),
        ('ssrf-v4mapped6.'      || :'zone', '::ffff:127.0.0.1'),
        ('ssrf-v4mapped-priv6.' || :'zone', '::ffff:10.0.0.1')
     ) AS v(name, ip6)
WHERE d.name = :'zone';

EOSQL

echo "[seed] inserted: $(psql -tAc "SELECT count(*) FROM records" --username "${POSTGRES_USER}" --dbname "${POSTGRES_DB}") records"
