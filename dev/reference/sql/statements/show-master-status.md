---
title: SHOW MASTER STATUS | TiDB SQL Statement Reference 
summary: An overview of the usage of SHOW MASTER STATUS for the TiDB database.
category: reference
---

# SHOW MASTER STATUS

<brief description>

## Synopsis

```sql
SHOW MASTER STATUS
```

## Examples

```sql
mysql> SHOW MASTER STATUS;
+-------------+--------------------+--------------+------------------+-------------------+
| File        | Position           | Binlog_Do_DB | Binlog_Ignore_DB | Executed_Gtid_Set |
+-------------+--------------------+--------------+------------------+-------------------+
| tidb-binlog | 407749305261883393 |              |                  |                   |
+-------------+--------------------+--------------+------------------+-------------------+
1 row in set (0.00 sec)
```

## MySQL compatibility

* The column names for this command match MySQL, but the values for `Binlog_Do_DB`, `Binlog_Ignore_DB`, `Executed_Gtid_Set` will always be empty. Additionally the `File` will always be set to `tidb-binlog`.
* The `Position` column represents the current TSO value rather than a byte offset within a file.

## See also

* SHOW PUMP STATUS
* TiDB-Binlog page.
