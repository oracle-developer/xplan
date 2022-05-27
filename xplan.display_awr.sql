
-- ----------------------------------------------------------------------------------------------
--
-- Utility:      XPLAN
--
-- Script:       xplan.display_awr.sql
--
-- Version:      1.3
--
-- Author:       Adrian Billington
--               www.oracle-developer.net
--               (c) oracle-developer.net
--
-- Description:  A free-standing SQL wrapper over DBMS_XPLAN. Provides access to the
--               DBMS_XPLAN.DISPLAY_AWR pipelined function for a given SQL_ID and optional
--               plan hash value.
--
--               The XPLAN utility has one purpose: to include the parent operation ID (PID)
--               and an execution order column (OID) in the plan output. This makes plan
--               interpretation easier for larger or more complex execution plans. Version 1.3
--               has also added the object owner to the output for more clarity.
--
--               See the following example for details.
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
--               ------------------------------------------------------------------
--               | Id  | Pid | Ord | Operation                    | Name          |
--               ------------------------------------------------------------------
--               |   0 |     |   6 | SELECT STATEMENT             |               |
--               |   1 |   0 |   5 |  MERGE JOIN                  |               |
--               |   2 |   1 |   2 |   TABLE ACCESS BY INDEX ROWID| SCOTT.DEPT    |
--               |   3 |   2 |   1 |    INDEX FULL SCAN           | SCOTT.PK_DEPT |
--               |   4 |   1 |   4 |   SORT JOIN                  |               |
--               |   5 |   4 |   3 |    TABLE ACCESS FULL         | SCOTT.EMP     |
--               ------------------------------------------------------------------
--
-- Usage:        @xplan.display_awr.sql <sql_id> [plan_hash_value] [plan_format]
--
--               Parameters: 1) sql_id           - MANDATORY
--                           2) plan_hash_value  - OPTIONAL (defaults to all available for the SQL ID)
--                           3) plan_format      - OPTIONAL (defaults to TYPICAL)
--
-- Examples:     1) All AWR plans for a SQL_ID
--                  --------------------------
--                  @xplan.display_awr.sql 9vfvgsk7mtkr4
--
--               2) All AWR plans for a SQL_ID with a non-default format
--                  ----------------------------------------------------
--                  @xplan.display_awr.sql 9vfvgsk7mtkr4 "" "basic +projection"
--
--               3) AWR plan for a SQL_ID and specific PLAN_HASH_VALUE
--                  --------------------------------------------------
--                  @xplan.display_awr.sql 9vfvgsk7mtkr4 63301235
--
--               4) AWR plan for a SQL_ID, specific PLAN_HASH_VALUE and non-default format
--                  ----------------------------------------------------------------------
--                  @xplan.display_awr.sql 9vfvgsk7mtkr4 63301235 "advanced"
--
-- Versions:     This utility will work for all versions of 10g and upwards.
--
-- Required:     *** IMPORTANT: PLEASE READ ***
--
--               1) Oracle license implications
--                  ---------------------------
--                  The AWR functionality of XPLAN accesses a DBA_HIST% AWR view which means
--                  that it requires an Oracle Tuning and Diagnostic Pack license. Please
--                  ensure that you are licensed to use this feature: the author accepts
--                  no responsibility for any use of this functionality in an unlicensed database.
--
--               2) Access to the DBA_HIST_SQL_PLAN AWR view.
--
-- Notes:        An XPLAN PL/SQL package is also available. This has wrappers for all of the
--               DBMS_XPLAN pipelined functions, but requires the creation of objects.
--
-- Credits:      1) James Padfield for the hierarchical query to order the plan operations.
--
-- Disclaimer:   http://www.oracle-developer.net/disclaimer.php
--
-- ----------------------------------------------------------------------------------------------

set define on
define v_xa_version = 1.3

-- Initialise variables 1,2,3 in case they aren't supplied...
-- ----------------------------------------------------------
set termout off
column 1 new_value 1
column 2 new_value 2
column 3 new_value 3
select null as "1"
,      null as "2"
,      null as "3"
from   dual
where  1=2;

-- Define the parameters...
-- ------------------------
column dbid            new_value v_xa_dbid
column sql_id          new_value v_xa_sql_id
column format          new_value v_xa_format
column plan_hash_value new_value v_xa_plan_hash_value
select dbid
,      '&1'                 as sql_id
,      nvl('&2', 'NULL')    as plan_hash_value
,      nvl('&3', 'TYPICAL') as format
from   gv$database
where  inst_id = sys_context('userenv','instance');

-- Main Xplan SQL...
-- -----------------
set termout on lines 200 pages 1000
col plan_table_output format a200

prompt _ _____________________________________________________________________
prompt _
prompt _ XPlan v&v_xa_version by Adrian Billington (http://www.oracle-developer.net)
prompt _
prompt _
prompt _                  *** IMPORTANT: PLEASE READ ***
prompt _
prompt _ A licence for the Oracle Tuning and Diagnostics Pack is needed to
prompt _ use this utility. Continue at your own risk: the author accepts
prompt _ no responsibility for any use of this functionality in an unlicensed
prompt _ database.
prompt _
prompt _                   To cancel:   press Ctrl-C
prompt _                   To continue: press Enter
prompt _ _____________________________________________________________________
prompt
pause

with sql_plan_data as (
        select id, parent_id, plan_hash_value, object_owner, object_name
        from   dba_hist_sql_plan
        where  sql_id = '&v_xa_sql_id'
        and    plan_hash_value = nvl(&v_xa_plan_hash_value, plan_hash_value)
        and    dbid = &v_xa_dbid
        )
,    hierarchy_data as (
        select  id, parent_id, plan_hash_value, object_owner, object_name
        from    sql_plan_data
        start   with id = 0
        connect by prior id = parent_id
               and prior plan_hash_value = plan_hash_value
        order   siblings by id desc
        )
,    ordered_hierarchy_data as (
        select id
        ,      parent_id
        ,      plan_hash_value
        ,      object_owner
        ,      object_name
        ,      row_number() over (partition by plan_hash_value order by rownum desc) as order_id
        ,      max(id) over (partition by plan_hash_value) as max_id
        from   hierarchy_data
        )
,    xplan_data as (
        select /*+ ordered use_nl(o) */
               x.plan_table_output
        ,      o.id
        ,      o.parent_id
        ,      o.order_id
        ,      o.max_id
        ,      o.object_owner
        ,      o.object_name
        ,      p.plan_hash_value
        ,      count(*) over () as row_count
        from  (
               select distinct plan_hash_value
               from   ordered_hierarchy_data
              ) p
               cross join
               table(dbms_xplan.display_awr('&v_xa_sql_id',p.plan_hash_value,&v_xa_dbid,'&v_xa_format')) x
               left outer join
               ordered_hierarchy_data o
               on (    o.plan_hash_value = p.plan_hash_value
                   and o.id = case
                                 when regexp_like(x.plan_table_output, '^\|[\* 0-9]+\|')
                                 then to_number(regexp_substr(x.plan_table_output, '[0-9]+'))
                              end)
        )
select plan_table_output
from   xplan_data
model
   dimension by (plan_hash_value as phv, rownum as r)
   measures (plan_table_output,
             id,
             max_id as mid,
             parent_id as pid,
             order_id as oid,
             object_owner as owner,
             object_name as oname,
             nullif(object_owner || '.', '.') || object_name as ownname,
             max(length(object_owner || '.' || object_name)) over () as maxownnamelen,
             max(length(object_owner || '.' || object_name)) over () - max(length(object_name)) over () as ownnamepad,
             greatest(max(length(max_id)) over () + 3, 6) as csize,
             cast(null as varchar2(128)) as inject,
             row_count as rc)
   rules sequential order (
          inject[phv,r] = case
                             when id[cv(),cv()+1] = 0
                             or   id[cv(),cv()+3] = 0
                             or   id[cv(),cv()-1] = mid[cv(),cv()-1]
                             then rpad('-', csize[cv(),cv()]*2 + ownnamepad[cv(),cv()], '-')
                             when id[cv(),cv()+2] = 0
                             then '|' || lpad('Pid |', csize[cv(),cv()]) || lpad('Ord |', csize[cv(),cv()])
                             when id[cv(),cv()] is not null
                             then '|' || lpad(pid[cv(),cv()] || ' |', csize[cv(),cv()]) || lpad(oid[cv(),cv()] || ' |', csize[cv(),cv()])
                          end,
          plan_table_output[phv,r] = case
                                        when inject[cv(),cv()] like '---%'
                                        then inject[cv(),cv()] || plan_table_output[cv(),cv()]
                                        when inject[cv(),cv()] is not null
                                        then regexp_replace(plan_table_output[cv(),cv()], '\|', inject[cv(),cv()], 1, 2)
                                        else plan_table_output[cv(),cv()]
                                     end,
          plan_table_output[phv,r] order by r = case
                                                   when plan_table_output[cv(),cv()] like '|%'
                                                   then case
                                                           when id[cv(),cv()+2] = 0
                                                           then regexp_replace(plan_table_output[cv(),cv()], '(\| Name[ ]+)', '\1' || rpad('  ', ownnamepad[cv(),cv()]))
                                                           else case
                                                                   when oname[cv(),cv()] is not null
                                                                   then regexp_replace(plan_table_output[cv(),cv()], '[^\|]+', rpad(' ' || ownname[cv(),cv()], maxownnamelen[cv(),cv()] + 2), 1, 5)
                                                                   else regexp_replace(plan_table_output[cv(),cv()], '(\|.)', '\1' || rpad('  ', ownnamepad[cv(),cv()]), 1, 5)
                                                                end
                                                        end
                                                   else plan_table_output[cv(),cv()]
                                                end ||
                                                case
                                                   when cv(r) = rc[cv(),cv()]
                                                   then chr(10) ||
                                                        'About'  || chr(10) ||
                                                        '------' || chr(10) ||
                                                        '  - XPlan v&v_xa_version by Adrian Billington (http://www.oracle-developer.net)'
                                                end
         )
order  by r;


-- Teardown...
-- -----------
undefine v_xa_sql_id
undefine v_xa_plan_hash_value
undefine v_xa_dbid
undefine v_xa_format
undefine v_xa_version
undefine 1
undefine 2
undefine 3
