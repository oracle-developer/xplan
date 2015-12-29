
-- ----------------------------------------------------------------------------------------------
--
-- Utility:      XPLAN
--
-- Script:       xplan.display.sql
--
-- Version:      1.2
--
-- Author:       Adrian Billington
--               www.oracle-developer.net
--               (c) oracle-developer.net 
--
-- Description:  A free-standing SQL wrapper over DBMS_XPLAN. Provides access to the 
--               DBMS_XPLAN.DISPLAY pipelined function for an explained SQL statement.
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
-- Usage:        @xplan.display.sql [plan_table] [statement_id] [plan_format]
--
--               Parameters: 1) plan_table    - OPTIONAL (defaults to PLAN_TABLE)
--                           2) statement_id  - OPTIONAL (defaults to NULL)
--                           3) plan_format   - OPTIONAL (defaults to TYPICAL)
--
-- Examples:     1) Plan for last explained SQL statement
--                  -------------------------------------
--                  @xplan.display.sql
--
--               2) Plan for a specific statement_id
--                  --------------------------------
--                  @xplan.display.sql "" "my_statement_id"
--
--               3) Plan for last explained SQL statement using a non-standard plan table
--                  ---------------------------------------------------------------------
--                  @xplan.display.sql "my_plan_table"
--
--               4) Plan for last explained SQL statement with a non-default format
--                  ---------------------------------------------------------------
--                  @xplan.display.sql "" "" "basic +projection"
--
--               5) Plan for a specific statement_id and non-default format
--                  -------------------------------------------------------
--                  @xplan.display.sql "" "my_statement_id" "advanced"
--
--               6) Plan for last explained SQL statement with a non-default plan table and non-default format
--                  ------------------------------------------------------------------------------------------
--                  @xplan.display.sql "my_plan_table" "my_statement_id" "advanced"
--
-- Versions:     This utility will work for all versions of 10g and upwards.
--
-- Required:     1) Access to a plan table that corresponds to the Oracle version being used.
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
define v_xp_version = 1.2

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

-- Set the plan table...
-- ---------------------
column plan_table new_value v_xp_plan_table
select nvl('&1', 'PLAN_TABLE') as plan_table
from   dual;

-- Finally prepare the inputs to the main Xplan SQL...
-- ---------------------------------------------------
column plan_id  new_value v_xp_plan_id
column stmt_id  new_value v_xp_stmt_id
column format   new_value v_xp_format
select nvl(max(plan_id), -1)                                           as plan_id
,      max(statement_id) keep (dense_rank first order by plan_id desc) as stmt_id
,      nvl(max('&3'), 'typical')                                       as format
from   &v_xp_plan_table
where  id = 0
and    nvl(statement_id, '~') = coalesce('&2', statement_id, '~');

-- Main Xplan SQL...
-- -----------------
set termout on lines 200 pages 1000
col plan_table_output format a200

with sql_plan_data as (
        select id, parent_id
        from   &v_xp_plan_table
        where  plan_id = &v_xp_plan_id
        order  by id
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
        from   table(dbms_xplan.display('&v_xp_plan_table','&v_xp_stmt_id','&v_xp_format')) x
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
             rc,
             greatest(max(length(maxid)) over () + 3, 6) as csize,
             cast(null as varchar2(128)) as inject)
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
                                    then  chr(10) || chr(10) ||
                                         'About'  || chr(10) || 
                                         '------' || chr(10) ||
                                         '  - XPlan v&v_xp_version by Adrian Billington (http://www.oracle-developer.net)'
                                 end 
         )
order  by r;

-- Teardown...
-- -----------
undefine v_xp_plan_table
undefine v_xp_plan_id
undefine v_xp_stmt_id
undefine v_xp_format
undefine v_xp_version
undefine 1
undefine 2
undefine 3
