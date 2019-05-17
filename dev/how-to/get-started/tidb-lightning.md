# Overview
# Architecture
# Installation

TiDB-Lightning really benefits from a lot of CPU cores, so for this tutorial I recommend that you start a new cloud VM in the cloud provider of your choosing. (I'll use Digital Ocean, because it's inexpensive, quick to create VMs, and very simple to use from the command line. Digital Ocean starts VMs with the root user, which isn't so good, so I create and switch to user `tidb` after executing the `yum install` command you find below.)

If using a cloud VM isn't practical for some reason, you *can* complete the steps in this tutorial even in a single-core local VM. The steps in this tutorial do assume you're using a clean environment, though, and the steps in this tutorial will cause a number of directories and files to be created in the home directory of the user executing the steps below.

Install `unzip`, the MariaDB command-line client, and a couple other useful tools:
```bash
yum install -y unzip mariadb vim screen
```

If you also created a CentOS 7 VM in Digital Ocean, or you have another CentOS 7 environment where you only have a root user, be sure to create and switch to another user account before proceeding. You should **not** run components of TiDB Platform as `root`. These commands will create a `tidb` user that has *no password* and can *use sudo without root*. You should only execute these commands in a testing environment!
```bash
adduser -G wheel tidb
passwd -d tidb
sudo -i -u tidb screen -xR
```

Fetch and unpack all the bikeshare data archives. These 17 zip files are a combined 416MB, and the extracted data is 2.5GB, so make sure you have a few GB of free space.
```bash
mkdir -p ~/bikeshare-data
pushd ~/bikeshare-data
curl -L --remote-name-all https://s3.amazonaws.com/capitalbikeshare-data/{2010..2017}-capitalbikeshare-tripdata.zip
unzip \*-tripdata.zip
popd
```

If your `.csv` file has a header, TiDB-Lightning expects the header to contain the destination names of the columns in your table. The bikeshare `.csv` files do **not** have a header line with the column names we want to use, so we'll edit the files in-place to give them the header we want. Because the new header is exactly the same length as the old one, we don't have to copy the file or even use a real editor; instead, we can use the `dd` tool to overwrite the bytes in each CSV file with the bytes we want. This is really useful if you have extremely large files and don't want to make a copy of them.

We also need to create symlinks to the CSV files using the filename format expected by TiDB Lightning.

This bash loop will go through all CSV files, change their first line to be the header with column nams for our table, and create a symlink that matches the filename format expected by TiDB-Lightning:
```bash
pushd ~/bikeshare-data
mkdir -p import
i=1
printf > header %s '"duration","start_date","end_date","start_station_number","start_station","end_station_number","end_station","bike_number","member_type"'
for f in *.csv
do 
  printf -v new %s.%s.%03d.csv bikeshare trips "$((i++))"
  echo "$f"
  dd conv=notrunc status=none if=header of="$f"
  echo "==> $new"
  ln -s ../"$f" import/"$new"
done
popd
```


Even if you've already started a TiDB cluster, it will be easier to follow along with this tutorial if you set up a new, very simple cluster. We will install from a tarball, using a simplified form of the [Local Deployment](https://pingcap.com/docs/op-guide/binary-local-deployment/) guide. You may also wish to consult [Testing Deployment from Binary Tarball](https://pingcap.com/docs/op-guide/binary-testing-deployment/) for best practices establishing a real testing deployment that goes beyond the scope of this tutorial.

Fetch the latest packages of the core components of TiDB Platform as well as TiDB-Lightning, unpack them to their respective directories, and create symlinks to all binaries in a single directory:
```bash
cd ~
curl -L http://download.pingcap.org/tidb-latest-linux-amd64.tar.gz | tar xzf -
curl -L http://download.pingcap.org/tidb-lightning-latest-linux-amd64.tar.gz | tar xzf -
mkdir -p tidb/bin
ln -s -t tidb/bin "$PWD"/tidb-*/bin/*
```

## Configuration

Now we'll start a very simple TiDB cluster, with a single instance each of `pd-server`, `tikv-server`, and `tidb-server`.

First, let's populate the config files we'll use:
```bash
pushd ~/tidb
printf > pd.toml %s\\n 'log-file="pd.log"' 'data-dir="pd.data"'
printf > tikv.toml %s\\n 'log-file="tikv.log"' '[storage]' 'data-dir="tikv.data"' '[pd]' 'endpoints=["127.0.0.1:2379"]'\
                         '[rocksdb]' max-open-files=1024 '[raftdb]' max-open-files=1024 
printf > tidb.toml %s\\n 'store="tikv"' 'path="127.0.0.1:2379"' '[log.file]' 'filename="tidb.log"'
printf > tidb-lightning.toml %s\\n '[lightning]' 'file="tidb-lightning.log"' 'level="debug"'\
                                   '[tidb]' 'pd-addr="127.0.0.1:2379"' '[tikv-importer]' 'addr="127.0.0.1:20190"'\
                                   '[mydumper]' no-schema=true '[mydumper.csv]' "separator=','" "delimiter='\"'" header=true
printf > tikv-importer.toml %s\\n 'log-file="tikv-importer.log"' '[server]' 'addr="127.0.0.1:20190"'
printf >> ~/.my.cnf %s\\n '[mysql]' host=127.0.0.1 port=4000 user=root
```

This will allow you to see the contents of the config files:
```bash
for f in *.toml; do echo "$f:"; cat "$f"; echo; done
```

Expect this output:
```
pd.toml:
log-file="pd.log"
data-dir="pd.data"

tidb-lightning.toml:
[lightning]
file="tidb-lightning.log"
level="debug"
[tidb]
pd-addr="127.0.0.1:2379"
[tikv-importer]
addr="127.0.0.1:20190"
[mydumper]
no-schema=true
[mydumper.csv]
separator=','
delimiter='"'
header=true

tidb.toml:
store="tikv"
path="127.0.0.1:2379"
[log.file]
filename="tidb.log"

tikv-importer.toml:
log-file="tikv-importer.log"
[server]
addr="127.0.0.1:20190"

tikv.toml:
log-file="tikv.log"
[storage]
data-dir="tikv.data"
[pd]
endpoints=["127.0.0.1:2379"]
[rocksdb]
max-open-files=1024
[raftdb]
max-open-files=1024
```

## Bootstrapping

Now we can start each component. This is best done in a specific order, first bringing up the PD (Placement Driver), then TiKV Server (the backend key/value store used by the TiDB Platform), and finally TiDB Server (the frontend that speaks the MySQL protocol to your applications).

Start all the services:
```bash
./bin/pd-server --config=pd.toml &>pd.out &
./bin/tikv-server --config=tikv.toml &>tikv.out &
./bin/tidb-server --config=tidb.toml &>tidb.out &
```

Expect this output:
```
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/pd-server --config=pd.toml &>pd.out &
[1] 20935
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/tikv-server --config=tikv.toml &>tikv.out &
[2] 20944
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/tidb-server --config=tidb.toml &>tidb.out &
[3] 21058
```

And if you execute `jobs`, you should see the list of running daemons:
```
[kolbe@localhost tidb-latest-linux-amd64]$ jobs
[1]   Running                 ./bin/pd-server --config=pd.toml &>pd.out &
[2]   Running                 ./bin/tikv-server --config=tikv.toml &>tikv.out &
[3]+  Running                 ./bin/tidb-server --config=tidb.toml &>tidb.out &
```

If one of the services has failed to start (if you see "`Exit 1`" instead of "`Running`", for example), try to restart that individual service.

Now that our cluster is started, we can create the database and table into which we'll have TiDB-Lightning import the data set:
```sql
mysql -h 127.0.0.1 -P 4000 -u root <<'EoSQL'
CREATE DATABASE bikeshare;
CREATE TABLE bikeshare.trips (
  trip_id bigint(20) NOT NULL AUTO_INCREMENT,
  duration int(11) NOT NULL,
  start_date datetime DEFAULT NULL,
  end_date datetime DEFAULT NULL,
  start_station_number int(11) DEFAULT NULL,
  start_station varchar(255) DEFAULT NULL,
  end_station_number int(11) DEFAULT NULL,
  end_station varchar(255) DEFAULT NULL,
  bike_number varchar(255) DEFAULT NULL,
  member_type varchar(255) DEFAULT NULL,
  PRIMARY KEY (trip_id)
);
EoSQL
```


TiDB-Lightning uses the `tikv-importer` tool to push the data into the backend TiKV node(s), so we start `tikv-importer` before starting TiDB-Lightning:
```bash
./bin/tikv-importer --config=tikv-importer.toml &
```

```bash
./bin/tidb-lightning --config=tidb-lightning.toml -d "$HOME"/bikeshare-data/import
```

```
success=0; while ! ((success)); do if time ./bin/tidb-lightning --config=tidb-lightning.toml --pd-urls=127.0.0.1:2379 --importer=127.0.0.1:20160 --log-file=tidb-lightning.log -L debug -d "$HOME"/bikeshare-data/import; then success=1; echo "$(tput setaf 2)success"$HOME"/bikeshare-data/import$(tput sgr0)"; else echo "$(tput setaf 1; tput bold)failure"$HOME"/bikeshare-data/import$(tput sgr0)"; fi; sleep 1; done
```

If you want to compare performance of TiDB-Lightning with `LOAD DATA LOCAL INFILE` in the MySQL client for this dataset, you can use a strategy similar to this one to start a number of parallel MySQL clients and have each of them process a portion of the CSV files. This will start 2 fewer MySQL clients than the number of logical CPU cores on your machine (as long as you have more than 4 cores). It'll run in the background until all CSV files are imported, at which time the MySQL clients will execute and the total elapsed time will be written to `mysql.time`. You can use the Bash `jobs` statement to confirm that the job is still running, you can use `pgrep mysql` to see the running MySQL client processes, and you can use `mysql -e "show processlist"` to see the client connections to the TiDB server.
```bash
cd ~/bikeshare-data/import
thr=$(getconf _NPROCESSORS_ONLN)
(( thr>4 )) && (( thr-=2 ))
csv=(*.csv)
stmt="LOAD DATA LOCAL INFILE '%s' INTO TABLE trips FIELDS TERMINATED BY ',' \
      ENCLOSED BY '\"' LINES TERMINATED BY '\r\n' IGNORE 1 LINES \
      (duration, start_date, end_date, start_station_number, start_station, end_station_number, end_station, bike_number, member_type);"
  time (
    date
    for ((th=0;th<thr;th++)); do
      fifo=thr$th
      [[ -p $fifo ]] || mkfifo "$fifo" || break
      mysql -h 127.0.0.1 -P 4000 -u root bikeshare < "$fifo" &
      for ((i=th;i<${#csv[@]};i+=thr)); do
        printf "${stmt}\n" "${csv[i]}"
      done > "$fifo" &
    done
    wait
    date
  ) &> mysql.time &
```

In my tests, the `LOAD DATA LOCAL INFILE` tasks take a little over 5 minutes to complete, while TiDB-Lightning takes a little under 2 minutes.


## On-Time data set

TODO:
* Increase number of open files
* Massage input files to remove errors
* TiDB-Lightning resume?
* TiDB-Lightning validate data?

The On-Time data set is a collection of statistics about flight arrival times in the USA. The total size of the downloaded `.zip` files is about 6.5GB and the size of the uncompressed `.csv` files is an additional 76GB.

```bash
files=(https://transtats.bts.gov/PREZIP/On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{1987..2018}_{1..12}.zip)
step=$((${#files[@]}/10))
for ((th=0;th<10;th++)); do
  curl -sSL --remote-name-all "${files[@]:step*th:step}" &
done
```

If you want to monitor the progress of curl, you can start this loop, which will continue 
```bash
while true; do
  plist=$(pgrep curl)
  [[ $plist ]] || break
  date lsof -p "${plist//$'\n'/,}" | grep zip
  sleep 2
done
```

Some of the files may not have existed on the server, so let's delete those before we go any further:
```bash
grep -l --null '<title>404' *.zip | while read -r -d '' file; do rm "$file"; done
```

```bash
unzip \*.zip \*.csv
```

# # # #

To get the number of processors (physical and logical) on your machine, you can execute `getconf _NPROCESSORS_ONLN`.


bugs:
1) tikv-importer binds to same port as tikv-server
   a) tikv-importer and tikv-server are not handling bind conflicts properly
2) tidb-lightning gives a crazy error message if there's a gRPC problem or in this "EOF" case
3) tikv-importer does not seem to clean up after itself properly, or maybe doesn't handle being invoked in quick succession, or ... ?
4) '[ddl] syncer check all versions, someone is not synced, continue checking'
5) tidb-importer needs to report the filename (and line number maybe?) of a failed file:
    "["encode kv data and write failed"] [table=`ontime`.`ontime`] [engineNumber=0] [takeTime=13m22.890923775s] [error="[types:1691]BIGINT value is out of range in '0-90'"]"
    "[ERROR] [restore.go:107] [-] [table=`ontime`.`ontime`] [status=written] [error="[types:1406]Data Too Long, field len 4, data len 5"]"

6) OnTime data set has some fubar values (TaxiIn and CRSArrTime), so I changed those to char(4) in the CREATE TABLE:
```
   grep -ob "0-90" 'On_Time_Reporting_Carrier_On_Time_Performance_(1987_present)_2003_4.csv'
   dd conv=notrunc obs=1 seek=28800896 if=<(printf 0090) of='On_Time_Reporting_Carrier_On_Time_Performance_(1987_present)_2003_4.csv'
   dd conv=notrunc obs=1 seek="30478828" if=<(printf '"0084') of='On_Time_Reporting_Carrier_On_Time_Performance_(1987_present)_2005_10.csv'
   dd conv=notrunc obs=1 seek="25969160" if=<(printf '"0059') of='On_Time_Reporting_Carrier_On_Time_Performance_(1987_present)_2005_10.csv'
   dd conv=notrunc obs=1 seek="27280184" if=<(printf '"0071') of=~/ontime/'On_Time_Reporting_Carrier_On_Time_Performance_(1987_present)_2005_3.csv'
```


[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:788] ["encode kv data and write failed"] [table=`ontime`.`ontime`] [engineNumber=0] [takeTime=12m21.763426151s] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:644] ["restore engine failed"] [table=`ontime`.`ontime`] [engineNumber=0] [takeTime=12m21.763506921s] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:661] ["import whole table failed"] [table=`ontime`.`ontime`] [takeTime=12m21.763594084s] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:487] ["restore table failed"] [table=`ontime`.`ontime`] [takeTime=12m21.766252462s] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:532] ["restore all tables data failed"] [takeTime=12m21.766375826s] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:244] ["run failed"] [step=2] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:250] ["the whole procedure failed"] [takeTime=12m21.779263707s] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:105] ["tables failed to be imported"] [count=1]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [restore.go:107] [-] [table=`ontime`.`ontime`] [status=written] [error="syntax error"]
[2019/05/16 09:40:45.194 +00:00] [INFO] [restore.go:424] ["everything imported, stopping periodic actions"]
[2019/05/16 09:40:45.194 +00:00] [ERROR] [main.go:69] ["tidb lightning encountered error"] [error="syntax error"] [errorVerbose="syntax error\ngithub.com/pingcap/tidb-lightning/lightning/mydump.(*CSVParser).lex\n\t/home/jenkins/workspace/build_lightning_master/go/src/github.com/pingcap/tidb-lightning/lightning/mydump/csv_parser_generated.go:2949\ngithub.com/pingcap/tidb-lightning/lightning/mydump.(*CSVParser).ReadRow\n\t/home/jenkins/workspace/build_lightning_master/go/src/github.com/pingcap/tidb-lightning/lightning/mydump/csv_parser.go:121\ngithub.com/pingcap/tidb-lightning/lightning/restore.(*chunkRestore).restore\n\t/home/jenkins/workspace/build_lightning_master/go/src/github.com/pingcap/tidb-lightning/lightning/restore/restore.go:1587\ngithub.com/pingcap/tidb-lightning/lightning/restore.(*TableRestore).restoreEngine.func1\n\t/home/jenkins/workspace/build_lightning_master/go/src/github.com/pingcap/tidb-lightning/lightning/restore/restore.go:767\nruntime.goexit\n\t/usr/local/go/src/runtime/asm_amd64.s:1337"]
