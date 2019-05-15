# Overview
# Architecture
# Installation

TiDB-Lightning really benefits from a lot of CPU cores, so for this tutorial I recommend that you start a new cloud VM in the cloud provider of your choosing. (I'll use Digital Ocean, because it's inexpensive, quick to create VMs, and very simple to use from the command line. Digital Ocean starts VMs with the root user, which isn't so good, so I create and switch to user `tidb` after executing the `yum install` command you find below.)

If using a cloud VM isn't practical for some reason, you *can* complete the steps in this tutorial even in a single-core local VM. The steps in this tutorial assume you're using a clean environment, though, and the steps in this tutorial will cause a number of directories and files to be created in the home directory of the user executing the steps below.

Install `unzip`, the MariaDB command-line client, and a couple other useful tools:
```bash
yum install -y unzip mariadb vim screen
```

If you also created a CentOS 7 VM in Digital Ocean, or you have another CentOS 7 environment where you only have a root user, be sure to create and switch to another user account before proceeding. You should **not** run components of TiDB Platform as `root`. These commands will create a `tidb` user that has *no password* and can *use sudo without root*. You should only execute these commands in a testing environment!
```bash
adduser -G wheel tidb
passwd -d tidb
sudo -i -u tidb screen
```

Fetch and unpack all the bikeshare data archives. These 17 zip files are a combined 416MB, and the extracted data is 2.5GB, so make sure you have a few GB of free space.
```bash
mkdir -p ~/bikeshare-data
pushd ~/bikeshare-data
curl -L --remote-name-all https://s3.amazonaws.com/capitalbikeshare-data/{2010..2017}-capitalbikeshare-tripdata.zip
unzip \*-tripdata.zip
popd
```

If your `.csv` file has a header, TiDB-Lightning expects the header to contain the destination names of the columns in your table. The bikeshare `.csv` files do **not** have a header line with the column names we want to use, so we'll edit the files in-place to give them the header we want. The `ex` tool included with Vim makes this very easy.

We also need to create symlinks to the CSV files using the filename format expected by TiDB Lightning.

This bash loop will go through all CSV files, change their first line to be the header with column nams for our table, and create a symlink in a subdirectory that matches the filename format expected by TiDB-Lightning:
```bash
pushd ~/bikeshare-data
mkdir -p import
i=1
for f in *.csv
do 
  echo "$f"
  printf %s\\n 1 c \
    '"duration","start_date","end_date","start_station_number","start_station","end_station_number","end_station","bike_number","member_type"'\
    . wq | 
  ex "$f"
  printf -v new %s.%s.%03d.csv bikeshare trips "$((i++))"
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
printf > tikv.toml %s\\n 'log-file="tikv.log"' '[storage]' 'data-dir="tikv.data"' '[pd]' 'endpoints=["127.0.0.1:2379"]' '[rocksdb]' max-open-files=1024 '[raftdb]' max-open-files=1024 
printf > pump.toml %s\\n 'log-file="pump.log"' 'data-dir="pump.data"' 'addr="127.0.0.1:8250"' 'advertise-addr="127.0.0.1:8250"' 'pd-urls="http://127.0.0.1:2379"'
printf > tidb.toml %s\\n 'store="tikv"' 'path="127.0.0.1:2379"' '[log.file]' 'filename="tidb.log"' '[binlog]' 'enable=true'
printf > drainer.toml %s\\n 'log-file="drainer.log"' '[syncer]' 'db-type="mysql"' '[syncer.to]' 'host="127.0.0.1"' 'user="root"' 'password=""' 'port=3306'
printf > tidb-lightning.toml %s\\n '[mydumper]' no-schema=true '[mydumper.csv]' "separator=','" "delimiter='\"'" header=true
printf >> ~/.my.cnf %s\\n '[mysql]' host=127.0.0.1 port=4000 user=root
```

This will allow you to see the contents of the config files:
```bash
for f in *.toml; do echo "$f:"; cat "$f"; echo; done
```

Expect this output:
```
drainer.toml:
log-file="drainer.log"
[syncer]
db-type="mysql"
[syncer.to]
host="127.0.0.1"
user="root"
password=""
port=3306

pd.toml:
log-file="pd.log"
data-dir="pd.data"

pump.toml:
log-file="pump.log"
data-dir="pump.data"
addr="127.0.0.1:8250"
advertise-addr="127.0.0.1:8250"
pd-urls="http://127.0.0.1:2379"

tidb-lightning.toml:
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
[binlog]
enable=true

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

Now we can start each component. This is best done in a specific order, first bringing up the PD (Placement Driver), then TiKV Server (the backend key/value store used by TiDB Platform), then pump (because TiDB must connect to the pump service to send the binary log), and finally TiDB Server (the frontend that speaks the MySQL protocol to your applications).

Start all the services:
```bash
./bin/pd-server --config=pd.toml &>pd.out &
./bin/tikv-server --config=tikv.toml &>tikv.out &
./bin/pump --config=pump.toml &>pump.out &
sleep 3
./bin/tidb-server --config=tidb.toml &>tidb.out &
```

Expect this output:
```
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/pd-server --config=pd.toml &>pd.out &
[1] 20935
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/tikv-server --config=tikv.toml &>tikv.out &
[2] 20944
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/pump --config=pump.toml &>pump.out &
[3] 21050
[kolbe@localhost tidb-latest-linux-amd64]$ sleep 3
[kolbe@localhost tidb-latest-linux-amd64]$ ./bin/tidb-server --config=tidb.toml &>tidb.out &
[4] 21058
```

And if you execute `jobs`, you should see the list of running daemons:
```
[kolbe@localhost tidb-latest-linux-amd64]$ jobs
[1]   Running                 ./bin/pd-server --config=pd.toml &>pd.out &
[2]   Running                 ./bin/tikv-server --config=tikv.toml &>tikv.out &
[3]-  Running                 ./bin/pump --config=pump.toml &>pump.out &
[4]+  Running                 ./bin/tidb-server --config=tidb.toml &>tidb.out &
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
./bin/tikv-importer --log-file=tikv-importer.log &
```

```bash
./bin/tidb-lightning --config=tidb-lightning.toml --pd-urls=127.0.0.1:2379 --importer=127.0.0.1:20160 --log-file=tidb-lightning.log -L debug -d "$HOME"/bikeshare-data/import
```

```
success=0; while ! ((success)); do if time ./bin/tidb-lightning --config=tidb-lightning.toml --pd-urls=127.0.0.1:2379 --importer=127.0.
0.1:20160 --log-file=tidb-lightning.log -L debug -d "$HOME"/bikeshare-data/import; then success=1; echo "$(tput setaf 2)success"$HOME"/bikeshare-data/import$(
tput sgr0)"; else echo "$(tput setaf 1; tput bold)failure"$HOME"/bikeshare-data/import$(tput sgr0)"; fi; sleep 1; done
```

```bash
cd ~/bikeshare-data/import
thr=$(getconf _NPROCESSORS_ONLN)
(( thr>4 )) && (( thr-=2 ))
csv=(*.csv)
stmt="LOAD DATA LOCAL INFILE '%s' INTO TABLE trips FIELDS TERMINATED BY ',' ENCLOSED BY '\"' LINES TERMINATED BY '\r\n' IGNORE 1 LINES (duration, start_date, end_date, start_station_number, start_station, end_station_number, end_station, bike_number, member_type);\n"
for ((th=0;th<thr;th++)); do
  fifo=thr$th
  [[ -p $fifo ]] || mkfifo "$fifo" || break
  time mysql -h 127.0.0.1 -P 4000 -u root bikeshare < "$fifo" &
  for ((i=th;i<${#csv[@]};i+=thr)); do
    printf "$stmt" "${csv[i]}"
  done > "$fifo" &
done
```

# # # #

To get the number of processors (physical and logical) on your machine, you can execute `getconf _NPROCESSORS_ONLN`.
