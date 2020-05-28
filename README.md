
# XPLAN

## 1.0 Introduction
This repository contains two versions of the XPLAN utility. XPLAN is a wrapper over DBMS_XPLAN functions that re-formats plan output to include parent operation ID and execution order columns. This makes plan interpretation easier for larger or more complex execution plans.

## 2.0 Versions
There are two versions provided.

### 2.1 Installed Package (xplan.package.sql)
This is a package of pipelined function wrappers over the DBMS_XPLAN reports (DISPLAY, DISPLAY_CURSOR, DISPLAY_AWR). It creates two types and the XPLAN package itself. See the description in the package header for more details and usage information.

### 2.2 Standalone Scripts (xplan.display.sql, xplan.display_cursor.sql, xplan.display_awr.sql)
These are standalone SQL scripts (for SQL*Plus) that simulate the XPLAN functionality but without having to create any database objects. Because they are free-standing SQL scripts, they are more portable, can be added to your SQLPath for instant availability and can be used in more restrictive environments.  See the description in the script headers for more details and usage information. Note that a Tuning and Diagnostics Pack licence is required for the `xplan.display_awr.sql` script as it accesses AWR data.

## 4.0 License
This project uses the MIT License.
See https://github.com/oracle-developer/xplan/blob/master/LICENSE

Adrian Billington
www.oracle-developer.net