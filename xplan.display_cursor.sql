
-- ----------------------------------------------------------------------------------------------
--
-- Utility:      XPLAN
--
-- Script:       xplan.display_cursor.sql
--
-- Version:      1.2
--
-- Author:       Adrian Billington
--               www.oracle-developer.net
--               (c) oracle-developer.net 
--
-- Description:  A free-standing SQL wrapper over DBMS_XPLAN. Provides access to the 
--               DBMS_XPLAN.DISPLAY_CURSOR pipelined function for a given SQL_ID and CHILD_NO.
--
--               The XPLAN utility has one purpose: to include the parent operation ID (PID)
--               and an execution order column (OID) in the plan output. This makes plan
--               interpretation easier for larger or more complex execution plans.
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
--               ------------------------------------------------------------
--               | Id  | Pid | Ord | Operation                    | Name    |
--               ------------------------------------------------------------
--               |   0 |     |   6 | SELECT STATEMENT             |         |
--               |   1 |   0 |   5 |  MERGE JOIN                  |         |
--               |   2 |   1 |   2 |   TABLE ACCESS BY INDEX ROWID| DEPT    |
--               |   3 |   2 |   1 |    INDEX FULL SCAN           | PK_DEPT |
--               |   4 |   1 |   4 |   SORT JOIN                  |         |
--               |   5 |   4 |   3 |    TABLE ACCESS FULL         | EMP     |
--               ------------------------------------------------------------
--
-- Usage:        @xplan.display_cursor.sql <sql_id> [cursor_child_number] [format]
--
--               Parameters: 1) sql_id           - OPTIONAL (defaults to last executed SQL_ID)
--                           2) sql_child_number - OPTIONAL (defaults to 0)
--                           3) plan_format      - OPTIONAL (defaults to TYPICAL)
--
-- Examples:     1) Plan for last executed SQL (needs serveroutput off)
--                  ---------------------------------------------------
--                  @xplan.display_cursor.sql
--
--               2) Plan for a SQL_ID with default child number
--                  -------------------------------------------
--                  @xplan.display_cursor.sql 9vfvgsk7mtkr4
--
--               3) Plan for a SQL_ID with specific child number
--                  --------------------------------------------
--                  @xplan.display_cursor.sql 9vfvgsk7mtkr4 1
--
--               4) Plan for a SQL_ID with default child number and non-default format
--                  ------------------------------------------------------------------
--                  @xplan.display_cursor.sql 9vfvgsk7mtkr4 "" "basic +projection"
--
--               5) Plan for a SQL_ID, specific child number and non-default format
--                  ---------------------------------------------------------------
--                  @xplan.display_cursor.sql 9vfvgsk7mtkr4 1 "advanced"
--
-- Versions:     This utility will work for all versions of 10g and upwards.
--
-- Required:     1) Access to GV$SESSION, GV$SQL_PLAN
--
-- Notes:        An XPLAN PL/SQL package is also available. This has wrappers for all of the 
--               DBMS_XPLAN pipelined functions, but requires the creation of objects.
--
-- Credits:      1) James Padfield for the hierarchical query to order the plan operations. 
--               2) Paul Vale for the suggestion to turn XPLAN.DISPLAY_CURSOR into a standalone
--                  SQL script, including a prototype.
--
-- Disclaimer:   http://www.oracle-developer.net/disclaimer.php
--
-- ----------------------------------------------------------------------------------------------

set define on
define v_xc_version = 1.2

-- Fetch the previous SQL details in case they're not supplied...
-- --------------------------------------------------------------
set termout off
column prev_sql_id       new_value v_xc_prev_sql_id
column prev_child_number new_value v_xc_prev_child_no
select prev_sql_id
,      prev_child_number
from   gv$session
where  inst_id = sys_context('userenv','instance')
and    sid = sys_context('userenv','sid')
and    username is not null 
and    prev_hash_value <> 0;

-- Initialise variables 1,2,3 in case they aren't supplied...
-- ----------------------------------------------------------
column 1 new_value 1
column 2 new_value 2
column 3 new_value 3
select null as "1"
,      null as "2"
,      null as "3"
from   dual 
where  1=2;

-- Finally prepare the inputs to the main Xplan SQL...
-- ---------------------------------------------------
column sql_id   new_value v_xc_sql_id
column child_no new_value v_xc_child_no
column format   new_value v_xc_format
select nvl('&1', '&v_xc_prev_sql_id')              as sql_id
,      to_number(nvl('&2', '&v_xc_prev_child_no')) as child_no
,      nvl('&3', 'typical')                        as format
from   dual;

-- Main Xplan SQL...
-- -----------------
set termout on lines 200 pages 1000
col plan_table_output format a200

with sql_plan_data as (
        select  id, parent_id
        from    gv$sql_plan
        where   inst_id = sys_context('userenv','instance')
        and     sql_id = '&v_xc_sql_id'
        and     child_number = to_number('&v_xc_child_no')
        )
,    hierarchy_data as (
        select  id, parent_id
        from    sql_plan_data
        start   with id = 0
        connect by prior id = parent_id
        order   siblings by id desc
        )
,    ordered_hierarchy_data as (
        select id
        ,      parent_id as pid
        ,      row_number() over (order by rownum desc) as oid
        ,      max(id) over () as maxid
        from   hierarchy_data
        )
,    xplan_data as (
        select /*+ ordered use_nl(o) */
               rownum as r
        ,      x.plan_table_output as plan_table_output
        ,      o.id
        ,      o.pid
        ,      o.oid
        ,      o.maxid 
        ,      count(*) over () as rc
        from   table(dbms_xplan.display_cursor('&v_xc_sql_id',to_number('&v_xc_child_no'),'&v_xc_format')) x
               left outer join
               ordered_hierarchy_data o
               on (o.id = case
                             when regexp_like(x.plan_table_output, '^\|[\* 0-9]+\|')
                             then to_number(regexp_substr(x.plan_table_output, '[0-9]+'))
                          end)
        )
select plan_table_output
from   xplan_data
model
   dimension by (rownum as r)
   measures (plan_table_output,
             id,
             maxid,
             pid,
             oid,
             greatest(max(length(maxid)) over () + 3, 6) as csize,
             cast(null as varchar2(128)) as inject,
             rc)
   rules sequential order (
          inject[r] = case
                         when id[cv()+1] = 0
                         or   id[cv()+3] = 0
                         or   id[cv()-1] = maxid[cv()-1]
                         then rpad('-', csize[cv()]*2, '-')
                         when id[cv()+2] = 0
                         then '|' || lpad('Pid |', csize[cv()]) || lpad('Ord |', csize[cv()])
                         when id[cv()] is not null
                         then '|' || lpad(pid[cv()] || ' |', csize[cv()]) || lpad(oid[cv()] || ' |', csize[cv()]) 
                      end, 
          plan_table_output[r] = case
                                    when inject[cv()] like '---%'
                                    then inject[cv()] || plan_table_output[cv()]
                                    when inject[cv()] is not null
                                    then regexp_replace(plan_table_output[cv()], '\|', inject[cv()], 1, 2)
                                    else plan_table_output[cv()]
                                 end ||
                                 case
                                    when cv(r) = rc[cv()]
                                    then  chr(10) ||
                                         'About'  || chr(10) || 
                                         '------' || chr(10) ||
                                         '  - XPlan v&v_xc_version by Adrian Billington (http://www.oracle-developer.net)'
                                 end 
         )
order  by r;


-- Teardown...
-- -----------
undefine v_xc_sql_id
undefine v_xc_child_no
undefine v_xc_format
undefine v_xc_prev_sql_id
undefine v_xc_prev_child_no
undefine v_xc_version
undefine 1
undefine 2
undefine 3
