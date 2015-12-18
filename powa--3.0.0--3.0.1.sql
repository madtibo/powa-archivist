-- complain if script is sourced in psql, rather than via CREATE EXTENSION
--\echo Use "ALTER EXTENSION powa" to load this file. \quit

SET statement_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET client_min_messages = warning;
SET escape_string_warning = off;
SET search_path = public, pg_catalog;

CREATE OR REPLACE FUNCTION powa_statements_snapshot() RETURNS void AS $PROC$
DECLARE
    result boolean;
    ignore_regexp text:='^[[:space:]]*(DEALLOCATE|BEGIN|PREPARE TRANSACTION|COMMIT PREPARED|ROLLBACK PREPARED)';
BEGIN
    -- In this function, we capture statements, and also aggregate counters by database
    -- so that the first screens of powa stay reactive even though there may be thousands
    -- of different statements
    RAISE DEBUG 'running powa_statements_snapshot';
    WITH capture AS(
        SELECT pgss.*
        FROM pg_stat_statements pgss
        JOIN pg_roles r ON pgss.userid = r.oid
        WHERE pgss.query !~* ignore_regexp
        AND NOT (r.rolname = ANY (string_to_array(current_setting('powa.ignored_users'),',')))
    ),

    missing_statements AS(
        INSERT INTO powa_statements (queryid, dbid, userid, query)
            SELECT queryid, dbid, userid, query
            FROM capture c
            WHERE NOT EXISTS (SELECT 1
                              FROM powa_statements ps
                              WHERE ps.queryid = c.queryid
                              AND ps.dbid = c.dbid
                              AND ps.userid = c.userid
            )
    ),

    by_query AS (
        INSERT INTO powa_statements_history_current
            SELECT queryid, dbid, userid,
            ROW(
                now(), calls, total_time, rows, shared_blks_hit, shared_blks_read,
                shared_blks_dirtied, shared_blks_written, local_blks_hit, local_blks_read,
                local_blks_dirtied, local_blks_written, temp_blks_read, temp_blks_written,
                blk_read_time, blk_write_time
            )::powa_statements_history_record AS record
            FROM capture
    ),

    by_database AS (
        INSERT INTO powa_statements_history_current_db
            SELECT dbid,
            ROW(
                now(), sum(calls), sum(total_time), sum(rows), sum(shared_blks_hit), sum(shared_blks_read),
                sum(shared_blks_dirtied), sum(shared_blks_written), sum(local_blks_hit), sum(local_blks_read),
                sum(local_blks_dirtied), sum(local_blks_written), sum(temp_blks_read), sum(temp_blks_written),
                sum(blk_read_time), sum(blk_write_time)
            )::powa_statements_history_record AS record
            FROM capture
            GROUP BY dbid
    )

    SELECT true::boolean INTO result; -- For now we don't care. What could we do on error except crash anyway?
END;
$PROC$ language plpgsql;

-- remove entries that should not have been stored
DELETE FROM powa_statements_history_current pshc
USING powa_statements ps
WHERE pshc.queryid = ps.queryid
    AND pshc.dbid = ps.dbid
    AND pshc.userid = ps.userid
    AND ps.query ~* '^[[:space:]]*(DEALLOCATE|BEGIN|PREPARE TRANSACTION|COMMIT PREPARED|ROLLBACK PREPARED)';

DELETE FROM powa_statements_history psh
USING powa_statements ps
WHERE psh.queryid = ps.queryid
    AND psh.dbid = ps.dbid
    AND psh.userid = ps.userid
    AND ps.query ~* '^[[:space:]]*(DEALLOCATE|BEGIN|PREPARE TRANSACTION|COMMIT PREPARED|ROLLBACK PREPARED)';

DELETE FROM powa_statements
WHERE query ~* '^[[:space:]]*(DEALLOCATE|BEGIN|PREPARE TRANSACTION|COMMIT PREPARED|ROLLBACK PREPARED)';
