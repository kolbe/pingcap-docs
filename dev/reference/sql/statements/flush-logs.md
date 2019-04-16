---
title: FLUSH LOGS | TiDB SQL Statement Reference 
summary: An overview of the usage of FLUSH LOGS for the TiDB database.
category: reference
---

# FLUSH LOGS

This statement has no effect in TiDB. It is included for compatibility with MySQL.

## Synopsis

```sql
FLUSH LOGS
```

## Examples

```sql
mysql> FLUSH LOGS;
ERROR 1064 (42000): You have an error in your SQL syntax; check the manual that corresponds to your TiDB version for the right syntax to use line 1 column 10 near "LOGS"
```

## MySQL Compatibility

* MySQL supports the ability to [flush individual logs](https://dev.mysql.com/doc/refman/5.7/en/flush.html), such as `FLUSH BINARY LOGS`. This syntax is not currently supported in TiDB.

