
-- ----------------------------------------------------------------------------------------------
--
-- Script:       xplan.package.sql
--
-- Version:      1.2
--
-- Author:       Adrian Billington
--               www.oracle-developer.net
--
-- Description:  Creates a package named XPLAN as a wrapper over DBMS_XPLAN. Provides access to
--               the following DBMS_XPLAN pipelined functions:
--
--                  1. DISPLAY;
--                  2. DISPLAY_CURSOR;
--                  3. DISPLAY_AWR (optional - see Notes section for licence implications).
--
--               The XPLAN wrapper package has one purpose: to include the parent operation ID
--               and "order" columns in the plan output. This makes plan interpretation easier
--               for larger or more complex execution plans. See the following example for
--               details.
--
-- Example:      DBMS_XPLAN output (format BASIC):
--               ------------------------------------------------
--               | Id  | Operation                    | Name    |
--               ------------------------------------------------
--               |   0 | SELECT STATEMENT             |         |
--               |   1 |  MERGE JOIN                  |         |
--               |   2 |   TABLE ACCESS BY INDEX ROWID| DEPT    |
--               |   3 |    INDEX FULL SCAN           | PK_DEPT |
--               |   4 |   SORT JOIN                  |         |
--               |   5 |    TABLE ACCESS FULL         | EMP     |
--               ------------------------------------------------
--
--               Equivalent XPLAN output (format BASIC):
--               --------------------------------------------------------------
--               | Id  | PID | Order | Operation                    | Name    |
--               --------------------------------------------------------------
--               |   0 |     |     6 | SELECT STATEMENT             |         |
--               |   1 |   0 |     5 |  MERGE JOIN                  |         |
--               |   2 |   1 |     2 |   TABLE ACCESS BY INDEX ROWID| DEPT    |
--               |   3 |   2 |     1 |    INDEX FULL SCAN           | PK_DEPT |
--               |   4 |   1 |     4 |   SORT JOIN                  |         |
--               |   5 |   4 |     3 |    TABLE ACCESS FULL         | EMP     |
--               --------------------------------------------------------------
--
-- Usage:        SELECT * FROM TABLE(XPLAN.DISPLAY(...));
--               SELECT * FROM TABLE(XPLAN.DISPLAY_CURSOR(...));
--               SELECT * FROM TABLE(XPLAN.DISPLAY_AWR(...));
--
--               Usage for XPLAN is the same as for DBMS_XPLAN. See the DBMS_XPLAN 
--               documentation for all options.
--
--               Note that the only exception to this is that XPLAN.DISPLAY does not contain 
--               the FILTER_PREDS parameter available in 10.2+ versions of DBMS_XPLAN.DISPLAY
--               (this parameter enables us to limit the data being returned from an Explain
--               Plan but is of quite limited use).
--
--               See the Notes section below for details on the licensing implications of
--               using XPLAN.DISPLAY_AWR.
--
-- Versions:     This utility will work for all versions of 10g and upwards.
--
-- Required:     1) PLAN_TABLE of at least 10.1 format
--
--               2) Either:
--                     SELECT ANY DICTIONARY
--                  Or:
--                     SELECT on V$DATABASE
--                     SELECT on V$SQL_PLAN
--                     SELECT on V$SESSION
--                     SELECT on V$MYSTAT
--                     SELECT on DBA_HIST_SQL_PLAN
--                  Or:
--                     SELECT_CATALOG_ROLE
--
--               3) CREATE TYPE, CREATE PROCEDURE
--
--               Note that the SQL statements that access V$ views are all dynamic and the 
--               package uses invoker rights. This means that the package will compile in 
--               constrained developer environments where explicit privileges on V$ views
--               are not granted and access to the views is only available via roles such as 
--               SELECT_CATALOG_ROLE.
--
-- Notes:        *** IMPORTANT: PLEASE READ ***
--
--               1) Oracle license implications
--                  ---------------------------
--                  The AWR functionality of XPLAN accesses a DBA_HIST% view which means
--                  that it requires an Oracle Diagnostic Pack license. The XPLAN.DISPLAY_AWR 
--                  pipelined function is therefore disabled by default. It can be included
--                  by modifying two substitution variables at the start of the script. Please
--                  ensure that you are licensed to use this feature: the author accepts
--                  no responsibility for any use of this functionality in an unlicensed database.
--
-- Installation: Installation requires SQL*Plus or any IDE that supports substitution
--               variables and SQL*Plus SET commands. To install, simply run the script in 
--               the target schema.
-- 
-- Creates:      1) XPLAN_OT object type
--               2) XPLAN_NTT collection type
--               3) XPLAN package
--
-- Removal:      1) DROP PACKAGE xplan;
--               3) DROP TYPE xplan_ntt;
--               4) DROP TYPE xplan_ot;
--
-- Credits:      James Padfield for the hierarchical query to order the plan operations.
--
-- Disclaimer:   http://www.oracle-developer.net/disclaimer.php
--
-- ----------------------------------------------------------------------------------------------

--
-- Define the "commenting-out" substitution variables for the AWR elements of this utility. The
-- default is commented out. To include the AWR functionality, change the variables to " " (i.e.
-- a single space).
--

SET DEFINE ON
DEFINE _awr_start = "/*"
DEFINE _awr_end   = "*/"

--
-- Supporting types for the pipelined functions...
--

CREATE OR REPLACE TYPE xplan_ot AS OBJECT
( plan_table_output VARCHAR2(300) );
/

CREATE OR REPLACE TYPE xplan_ntt AS
   TABLE OF xplan_ot;
/

--
-- Xplan package...
--

CREATE OR REPLACE PACKAGE xplan AUTHID CURRENT_USER AS

   FUNCTION display( p_table_name   IN VARCHAR2 DEFAULT 'PLAN_TABLE',
                     p_statement_id IN VARCHAR2 DEFAULT NULL,
                     p_format       IN VARCHAR2 DEFAULT 'TYPICAL' )
      RETURN xplan_ntt PIPELINED;

   FUNCTION display_cursor( p_sql_id          IN VARCHAR2 DEFAULT NULL,
                            p_cursor_child_no IN INTEGER  DEFAULT 0,
                            p_format          IN VARCHAR2 DEFAULT 'TYPICAL' )
      RETURN xplan_ntt PIPELINED;

&_awr_start
   FUNCTION display_awr( p_sql_id          IN VARCHAR2,
                         p_plan_hash_value IN INTEGER  DEFAULT NULL,
                         p_db_id           IN INTEGER  DEFAULT NULL,
                         p_format          IN VARCHAR2 DEFAULT 'TYPICAL' )
      RETURN xplan_ntt PIPELINED;
&_awr_end
      
END xplan;
/

CREATE OR REPLACE PACKAGE BODY xplan AS

   TYPE ntt_map_binds IS TABLE OF VARCHAR2(100);

   TYPE rt_map IS RECORD
   ( ord PLS_INTEGER
   , pid PLS_INTEGER );

   TYPE aat_map IS TABLE OF rt_map
      INDEX BY PLS_INTEGER;

   g_map  aat_map;
   g_hdrs PLS_INTEGER;
   g_len  PLS_INTEGER;
   g_pad  VARCHAR2(300);

   ----------------------------------------------------------------------------
   PROCEDURE reset_state IS
   BEGIN
      g_hdrs := 0;
      g_len  := 0;
      g_pad  := NULL;
      g_map.DELETE;
   END reset_state;

   ----------------------------------------------------------------------------
   FUNCTION info RETURN xplan_ot IS
   BEGIN
      RETURN xplan_ot(CHR(10) ||
                     'About'   || CHR(10) || 
                     '-----'  || CHR(10) ||
                     '   - XPlan v1.2 by Adrian Billington (http://www.oracle-developer.net)' );
   END info;

   ----------------------------------------------------------------------------
   PROCEDURE build_map( p_sql   IN VARCHAR2,
                        p_binds IN ntt_map_binds ) IS

      TYPE rt_id_data IS RECORD
      ( id  PLS_INTEGER
      , pid PLS_INTEGER
      , ord PLS_INTEGER );

      TYPE aat_id_data IS TABLE OF rt_id_data
         INDEX BY PLS_INTEGER;

      aa_ids   aat_id_data;
      v_cursor SYS_REFCURSOR;
      v_sql    VARCHAR2(32767);

   BEGIN

      -- Build SQL template...
      -- ---------------------
      v_sql := 'WITH sql_plan_data AS ( ' || 
                        p_sql || '
                        )
                ,    hierarchical_sql_plan_data AS (
                        SELECT id
                        ,      parent_id
                        FROM   sql_plan_data
                        START WITH id = 0
                        CONNECT BY PRIOR id = parent_id
                        ORDER SIBLINGS BY id DESC
                        )
                SELECT id
                ,      parent_id
                ,      ROW_NUMBER() OVER (ORDER BY ROWNUM DESC) AS ord
                FROM   hierarchical_sql_plan_data';

      -- Binds will differ according to plan type...
      -- -------------------------------------------
      CASE p_binds.COUNT
         WHEN 0
         THEN
            OPEN v_cursor FOR v_sql;
         WHEN 1
         THEN
            OPEN v_cursor FOR v_sql USING p_binds(1);
         WHEN 2
         THEN
            OPEN v_cursor FOR v_sql USING p_binds(1),
                                          TO_NUMBER(p_binds(2));
         WHEN 3
         THEN
            OPEN v_cursor FOR v_sql USING p_binds(1), 
                                          TO_NUMBER(p_binds(2)),
                                          TO_NUMBER(p_binds(3));            
      END CASE;

      -- Fetch the IDs and order data...
      -- -------------------------------
      FETCH v_cursor BULK COLLECT INTO aa_ids;
      CLOSE v_cursor;

      -- Populate the map array...
      -- -------------------------
      FOR i IN 1 .. aa_ids.COUNT LOOP      
         g_map(aa_ids(i).id).ord := aa_ids(i).ord;
         g_map(aa_ids(i).id).pid := aa_ids(i).pid;
      END LOOP;

      -- Use the map to determine padding needed to slot in our columns...
      -- -----------------------------------------------------------------
      IF g_map.COUNT > 0 THEN
         g_len := LEAST(LENGTH(g_map.LAST) + 13, 14);
         g_pad := LPAD('-', g_len, '-');
      END IF;

   END build_map;

   ----------------------------------------------------------------------------
   FUNCTION prepare_row( p_curr IN VARCHAR2,
                         p_next IN VARCHAR2 ) RETURN xplan_ot IS

      v_id  PLS_INTEGER;
      v_row VARCHAR2(4000);
      v_hdr VARCHAR2(64) := '%|%Id%|%Operation%|%';

   BEGIN

      -- Intercept the plan section to include new columns for the
      -- the parent ID and operation order that we mapped earlier.
      -- The plan output itself will be bound by dashed lines.
      -- We need to add in additional dashes, column headings
      -- and column values...
      -- -------------------------------------------------------------

      IF p_curr LIKE '---%' THEN

         IF p_next LIKE v_hdr THEN
            g_hdrs := 1;
            v_row := g_pad || p_curr;
         ELSIF g_hdrs BETWEEN 1 AND 3 THEN
            g_hdrs := g_hdrs + 1;
            v_row := g_pad || p_curr;
         ELSE
            v_row := p_curr;
         END IF;

      ELSIF p_curr LIKE v_hdr THEN

         v_row := REGEXP_REPLACE(
                     p_curr, '\|',
                     RPAD('|', GREATEST(g_len-12, 2)) || 'PID ' ||
                     RPAD('|', GREATEST(g_len-13, 2)) || 'Order |',
                     1, 2
                     ); 

      ELSIF REGEXP_LIKE(p_curr, '^\|[\* 0-9]+\|') THEN

         v_id := REGEXP_SUBSTR(p_curr, '[0-9]+');
         v_row := REGEXP_REPLACE(
                     p_curr, '\|', 
                     '|' || LPAD(NVL(TO_CHAR(g_map(v_id).pid),' '), GREATEST(g_len-12, 4))
                     || ' |' || LPAD(g_map(v_id).ord, GREATEST(g_len-13, 6)) || ' |',
                     1, 2
                     ); 
      ELSE
         v_row := p_curr;
      END IF;

      RETURN xplan_ot(v_row);

   END prepare_row;

   ----------------------------------------------------------------------------
   FUNCTION display( p_table_name   IN VARCHAR2 DEFAULT 'PLAN_TABLE',
                     p_statement_id IN VARCHAR2 DEFAULT NULL,
                     p_format       IN VARCHAR2 DEFAULT 'TYPICAL' )
      RETURN xplan_ntt PIPELINED IS

      v_plan_table   VARCHAR2(128) := NVL(p_table_name, 'PLAN_TABLE');
      v_sql          VARCHAR2(512);
      v_binds        ntt_map_binds := ntt_map_binds();

   BEGIN
   
      reset_state();

      -- Prepare the inputs for the parent ID and order map...
      -- -----------------------------------------------------
      v_sql := 'SELECT id, parent_id
                FROM   ' || v_plan_table || '
                WHERE  plan_id = (SELECT MAX(plan_id)
                                  FROM   ' || v_plan_table || '
                                  WHERE  id = 0 %bind%)
                ORDER  BY id';

      IF p_statement_id IS NULL THEN
         v_sql := REPLACE(v_sql, '%bind%');
      ELSE
         v_sql := REPLACE(v_sql, '%bind%', 'AND statement_id = :bv_statement_id');
         v_binds := ntt_map_binds(p_statement_id);
      END IF;
      
      -- Build the map...
      -- --------------------------------------------------
      build_map(v_sql, v_binds);

      -- Now we can call DBMS_XPLAN to output the plan...
      -- ------------------------------------------------
      PIPE ROW (info);

      FOR r_plan IN ( SELECT plan_table_output AS p
                      ,      LEAD(plan_table_output) OVER (ORDER BY ROWNUM) AS np
                      FROM   TABLE(
                                DBMS_XPLAN.DISPLAY(
                                   v_plan_table, p_statement_id, p_format 
                                   ))
                      ORDER  BY
                             ROWNUM)
      LOOP
         IF g_map.COUNT > 0 THEN
            PIPE ROW (prepare_row(r_plan.p, r_plan.np));
         ELSE
            PIPE ROW (xplan_ot(r_plan.p));
         END IF;
      END LOOP;

      PIPE ROW (info);

      reset_state();
      RETURN;

   END display;

   ----------------------------------------------------------------------------
   FUNCTION display_cursor( p_sql_id          IN VARCHAR2 DEFAULT NULL,
                            p_cursor_child_no IN INTEGER  DEFAULT 0,
                            p_format          IN VARCHAR2 DEFAULT 'TYPICAL' )
      RETURN xplan_ntt PIPELINED IS

      v_sql_id   VARCHAR2(30);
      v_child_no INTEGER;
      v_sql      VARCHAR2(256);
      v_binds    ntt_map_binds := ntt_map_binds();

   BEGIN

      reset_state();

      -- Set a SQL_ID if default parameters passed...
      -- --------------------------------------------
      IF p_sql_id IS NULL THEN
         EXECUTE IMMEDIATE 'SELECT prev_sql_id, prev_child_number
                            FROM   v$session
                            WHERE  sid = (SELECT m.sid FROM v$mystat m WHERE ROWNUM = 1)
                            AND    username IS NOT NULL 
                            AND    prev_hash_value <> 0'
         INTO v_sql_id, v_child_no;
      ELSE
         v_sql_id := p_sql_id;
         v_child_no := NVL(p_cursor_child_no,0);
      END IF;

      -- Prepare the inputs for the parent ID and order map...
      -- -----------------------------------------------------
      v_sql := 'SELECT id, parent_id
                FROM   v$sql_plan
                WHERE  sql_id = :bv_sql_id
                AND    child_number = :bv_child_no';

      v_binds := ntt_map_binds(v_sql_id, v_child_no);
      
      -- Build the plan map from the SQL...
      -- ----------------------------------------
      build_map(v_sql, v_binds);

      -- Now we can call DBMS_XPLAN to output the plan...
      -- ------------------------------------------------
      FOR r_plan IN ( SELECT plan_table_output AS p
                      ,      LEAD(plan_table_output) OVER (ORDER BY ROWNUM) AS np
                      FROM   TABLE(
                                DBMS_XPLAN.DISPLAY_CURSOR(
                                   v_sql_id, v_child_no, p_format 
                                   ))
                      ORDER  BY
                             ROWNUM)
      LOOP
         IF g_map.COUNT > 0 THEN
            PIPE ROW (prepare_row(r_plan.p, r_plan.np));
         ELSE
            PIPE ROW (xplan_ot(r_plan.p));
         END IF;
      END LOOP;

      PIPE ROW (info);

      reset_state();
      RETURN;

   END display_cursor;

&_awr_start
   ----------------------------------------------------------------------------
   FUNCTION display_awr( p_sql_id          IN VARCHAR2,
                         p_plan_hash_value IN INTEGER  DEFAULT NULL,
                         p_db_id           IN INTEGER  DEFAULT NULL,
                         p_format          IN VARCHAR2 DEFAULT 'TYPICAL' )
      RETURN xplan_ntt PIPELINED IS
      
      TYPE rt_awr IS RECORD
      ( sql_id          VARCHAR2(30)
      , plan_hash_value INTEGER
      , dbid            INTEGER );

      TYPE aat_awr IS TABLE OF rt_awr
         INDEX BY PLS_INTEGER;

      aa_awr  aat_awr;
      v_sql   VARCHAR2(256);
      v_binds ntt_map_binds := ntt_map_binds();

   BEGIN
   
      reset_state();

      -- Prepare the inputs for the parent ID and order map...
      -- -----------------------------------------------------
      v_sql := 'SELECT id, parent_id
                FROM   dba_hist_sql_plan
                WHERE  sql_id = :bv_sql_id
                AND    plan_hash_value = :bv_plan_hash_value
                AND    dbid = :bv_dbid';

      -- Determine all plans for the sql_id...
      -- -------------------------------------      
      EXECUTE IMMEDIATE 'SELECT DISTINCT
                                sql_id
                         ,      plan_hash_value
                         ,      dbid
                         FROM   dba_hist_sql_plan
                         WHERE  sql_id = :bv_sql_id
                         AND    plan_hash_value = NVL(:bv_plan_hash_value, plan_hash_value)
                         AND    dbid = NVL(:bv_db_id, (SELECT dbid FROM v$database))
                         ORDER  BY
                                plan_hash_value'
      BULK COLLECT INTO aa_awr
      USING p_sql_id, p_plan_hash_value, p_db_id;

      FOR i IN 1 .. aa_awr.COUNT LOOP
      
         -- Prepare the binds and build the order map...
         -- --------------------------------------------
         v_binds := ntt_map_binds(aa_awr(i).sql_id, 
                                  aa_awr(i).plan_hash_value, 
                                  aa_awr(i).dbid);
                                       
         -- Build the plan map from the SQL...
         -- ----------------------------------
         build_map(v_sql, v_binds);

         -- Now we can call DBMS_XPLAN to output the plan...
         -- ------------------------------------------------
         FOR r_plan IN ( SELECT plan_table_output AS p
                         ,      LEAD(plan_table_output) OVER (ORDER BY ROWNUM) AS np
                         FROM   TABLE(
                                   DBMS_XPLAN.DISPLAY_AWR(
                                      aa_awr(i).sql_id, aa_awr(i).plan_hash_value,
                                      aa_awr(i).dbid, p_format 
                                      ))
                         ORDER  BY
                                ROWNUM)
         LOOP
            IF g_map.COUNT > 0 THEN
               PIPE ROW (prepare_row(r_plan.p, r_plan.np));
            ELSE
               PIPE ROW (xplan_ot(r_plan.p));
            END IF;
         END LOOP;

      END LOOP;

      PIPE ROW (info);

      reset_state();
      RETURN;
      
   END display_awr;
&_awr_end

END xplan;
/

UNDEFINE _awr_start
UNDEFINE _awr_end

