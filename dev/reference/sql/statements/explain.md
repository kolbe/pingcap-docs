# EXPLAIN

The `EXPLAIN` statement shows the execution plan for a query without executing it. It is complimented by `EXPLAIN ANALYZE` which will execute the query.

If the output of `EXPLAIN` does not match the expected result, consider executing `ANALYZE TABLE` on each table in the query.

## Synopsis

```sql
EXPLAIN [FORMAT=DOT] <select-statement>
```

## Examples

```sql
mysql> EXPLAIN SELECT 1;
+-------------------+-------+------+---------------+
| id                | count | task | operator info |
+-------------------+-------+------+---------------+
| Projection_3      | 1.00  | root | 1             |
| └─TableDual_4     | 1.00  | root | rows:1        |
+-------------------+-------+------+---------------+
2 rows in set (0.00 sec)

mysql> CREATE TABLE t1 (id INT NOT NULL PRIMARY KEY auto_increment, c1 INT NOT NULL);
Query OK, 0 rows affected (0.10 sec)

mysql> INSERT INTO t1 (c1) VALUES (1), (2), (3);
Query OK, 3 rows affected (0.02 sec)
Records: 3  Duplicates: 0  Warnings: 0

mysql> EXPLAIN SELECT * FROM t1 WHERE id = 1;
+-------------+-------+------+--------------------+
| id          | count | task | operator info      |
+-------------+-------+------+--------------------+
| Point_Get_1 | 1.00  | root | table:t1, handle:1 |
+-------------+-------+------+--------------------+
1 row in set (0.00 sec)
```

## MySQL Compatibility

* Both the format of `EXPLAIN` and the potential execution plans in TiDB differ substaintially from MySQL.
* TiDB does not support the `EXPLAIN FORMAT=JSON` as in MySQL.

## See also

* [Understanding Query Execution Plans](#xxx)
* [EXPLAIN ANALYZE](#xxx)
* [ANALYZE TABLE](#xxx)

