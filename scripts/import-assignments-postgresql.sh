#!/usr/bin/env bash

set -euo pipefail

input_file=${1:?Usage: import-assignments-postgresql.sh INPUT_CSV [PSQL_ARGUMENT...]}
shift

if [[ ! -f "$input_file" ]]; then
    printf 'Import file does not exist: %s\n' "$input_file" >&2
    exit 1
fi
if ! command -v psql >/dev/null 2>&1; then
    printf '%s\n' 'psql is required to import assignments.' >&2
    exit 1
fi

header=$(LC_ALL=C sed -n '1{s/\r$//;p;}' "$input_file")
if [[ "$header" != 'realm_id,user_id,identifier' ]]; then
    printf '%s\n' \
        'The CSV header must be exactly: realm_id,user_id,identifier' >&2
    exit 1
fi

input_file=$(cd "$(dirname "$input_file")" && pwd)/$(basename "$input_file")
if [[ "$input_file" == *$'\n'* || "$input_file" == *$'\r'* ]]; then
    printf '%s\n' 'The CSV path must not contain a newline.' >&2
    exit 1
fi
escaped_input_file=${input_file//\'/\'\'}

psql --set=ON_ERROR_STOP=1 "$@" <<SQL
BEGIN;

CREATE TEMPORARY TABLE RFC1123_USERNAME_IMPORT (
    REALM_ID VARCHAR(36),
    USER_ID VARCHAR(255),
    IDENTIFIER VARCHAR(63)
) ON COMMIT DROP;

\copy RFC1123_USERNAME_IMPORT (REALM_ID, USER_ID, IDENTIFIER) FROM '$escaped_input_file' WITH (FORMAT csv, HEADER true)

DO \$import\$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM RFC1123_USERNAME_IMPORT
        WHERE REALM_ID IS NULL
           OR REALM_ID = ''
           OR USER_ID IS NULL
           OR USER_ID = ''
           OR IDENTIFIER IS NULL
           OR IDENTIFIER !~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\$'
    ) THEN
        RAISE EXCEPTION 'import contains an empty identity or invalid RFC1123 identifier';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM RFC1123_USERNAME_IMPORT
        GROUP BY REALM_ID, USER_ID
        HAVING COUNT(*) > 1
    ) OR EXISTS (
        SELECT 1
        FROM RFC1123_USERNAME_IMPORT
        GROUP BY REALM_ID, IDENTIFIER
        HAVING COUNT(*) > 1
    ) THEN
        RAISE EXCEPTION 'import contains a duplicate user or identifier within a realm';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM RFC1123_USERNAME_IMPORT imported
        LEFT JOIN USER_ENTITY keycloak_user
          ON keycloak_user.ID = imported.USER_ID
         AND keycloak_user.REALM_ID = imported.REALM_ID
        WHERE keycloak_user.ID IS NULL
    ) THEN
        RAISE EXCEPTION 'import references a user that does not exist in the specified realm';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM RFC1123_USERNAME_IMPORT imported
        JOIN RFC1123_USERNAME_ASSIGNMENT assigned
          ON assigned.REALM_ID = imported.REALM_ID
         AND assigned.USER_ID = imported.USER_ID
        WHERE assigned.IDENTIFIER <> imported.IDENTIFIER
    ) OR EXISTS (
        SELECT 1
        FROM RFC1123_USERNAME_IMPORT imported
        JOIN RFC1123_USERNAME_ASSIGNMENT assigned
          ON assigned.REALM_ID = imported.REALM_ID
         AND assigned.IDENTIFIER = imported.IDENTIFIER
        WHERE assigned.USER_ID <> imported.USER_ID
    ) THEN
        RAISE EXCEPTION 'import conflicts with an existing user or identifier assignment';
    END IF;
END
\$import\$;

INSERT INTO RFC1123_USERNAME_ASSIGNMENT (ID, REALM_ID, USER_ID, IDENTIFIER, CREATED_AT)
SELECT
    md5(random()::text || clock_timestamp()::text || imported.REALM_ID || imported.USER_ID)::uuid::text,
    imported.REALM_ID,
    imported.USER_ID,
    imported.IDENTIFIER,
    floor(extract(epoch FROM clock_timestamp()) * 1000)::bigint
FROM RFC1123_USERNAME_IMPORT imported
WHERE NOT EXISTS (
    SELECT 1
    FROM RFC1123_USERNAME_ASSIGNMENT assigned
    WHERE assigned.REALM_ID = imported.REALM_ID
      AND assigned.USER_ID = imported.USER_ID
      AND assigned.IDENTIFIER = imported.IDENTIFIER
);

COMMIT;
SQL

printf 'Imported assignments from %s.\n' "$input_file"
