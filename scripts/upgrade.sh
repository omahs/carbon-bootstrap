#!/bin/bash

set -e

if [ ! -f "/usr/local/lib/libleveldb.so.1" ]; then
  echo "Install dependencies"
  sudo sh -c 'echo "deb http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
  wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -

  sudo apt update
  sudo apt install build-essential jq cmake redis-server postgresql-12 -y

  wget https://github.com/google/leveldb/archive/1.23.tar.gz
  tar -zxvf 1.23.tar.gz

  wget https://github.com/google/googletest/archive/release-1.11.0.tar.gz
  tar -zxvf release-1.11.0.tar.gz
  mv googletest-release-1.11.0/* leveldb-1.23/third_party/googletest

  wget https://github.com/google/benchmark/archive/v1.5.5.tar.gz
  tar -zxvf v1.5.5.tar.gz
  mv benchmark-1.5.5/* leveldb-1.23/third_party/benchmark

  cd leveldb-1.23
  mkdir -p build

  cd build
  cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=ON ..
  cmake --build .
  sudo cp libleveldb.so.1 /usr/local/lib/
  sudo ldconfig
  cd ..

  sudo cp -r include/leveldb /usr/local/include/
  cd ..

  rm -rf benchmark-1.5.5/
  rm -f v1.5.5.tar.gz

  rm -rf googletest-release-1.11.0/
  rm -f release-1.11.0.tar.gz

  rm -rf leveldb-1.23/
  rm -f 1.23.tar.gz

  sudo sed -i -e '/^local   all             postgres                                peer$/d' \
    -e 's/ peer/ trust/g' \
    -e 's/ md5/ trust/g' \
    /etc/postgresql/12/main/pg_hba.conf
  sudo service postgresql restart
fi

echo "-- Stopping any previous system service of carbond"

sudo systemctl stop carbond || true
sudo systemctl stop carbond-oracle || true
sudo systemctl stop carbond-liquidator || true

echo "-- Clear old carbon data and install carbond and setup the node --"

dropdb -U postgres --if-exists carbon
rm -rf ~/.carbon
sudo rm -f /usr/local/bin/carbond
sudo rm -f /usr/local/bin/cosmovisor
sudo rm -rf /var/log/carbon

YOUR_KEY_NAME=val
YOUR_NAME=$1
DAEMON=carbond
PERSISTENT_PEERS="bd0a0ed977eabef81c60da2aac2dabb64a149173@3.0.180.87:26656"

echo "Installing carbond"
wget https://github.com/Switcheo/carbon-testnets/releases/download/v0.0.1/carbon0.0.1.tar.gz
tar -zxvf carbon0.0.1.tar.gz
sudo mv cosmovisor /usr/local/bin
rm carbon0.0.1.tar.gz

echo "Setting up your validator"
./$DAEMON init $YOUR_NAME
wget -O ~/.carbon/config/genesis.json https://raw.githubusercontent.com/Switcheo/carbon-testnets/master/carbon-0/genesis.json

echo "----------Setting config for seed node---------"
sed -i 's#timeout_commit = "5s"#timeout_commit = "1s"#g' ~/.carbon/config/config.toml
sed -i 's#cors_allowed_origins = \[\]#cors_allowed_origins = \["*"\]#g' ~/.carbon/config/config.toml
sed -i 's#laddr = "tcp:\/\/127.0.0.1:26657"#laddr = "tcp:\/\/0.0.0.0:26657"#g' ~/.carbon/config/config.toml
sed -i 's#addr_book_strict = true#addr_book_strict = false#g' ~/.carbon/config/config.toml
sed -i 's#db_backend = "goleveldb"#db_backend = "cleveldb"#g' ~/.carbon/config/config.toml
sed -i '/persistent_peers =/c\persistent_peers = "'"$PERSISTENT_PEERS"'"' ~/.carbon/config/config.toml
sed -i 's#enable = false#enable = true#g' ~/.carbon/config/app.toml

mkdir ~/.carbon/migrations
createdb -U postgres carbon
POSTGRES_DB=carbon POSTGRES_USER=postgres ./$DAEMON migrations
POSTGRES_DB=carbon POSTGRES_USER=postgres ./$DAEMON persist-genesis

mkdir -p ~/.carbon/cosmovisor/genesis/bin
mv $DAEMON ~/.carbon/cosmovisor/genesis/bin
sudo ln -s ~/.carbon/cosmovisor/current/bin/$DAEMON /usr/local/bin/$DAEMON

sudo mkdir /var/log/carbon

echo "---------Creating system file---------"

sudo tee /etc/systemd/system/carbond.service > /dev/null <<EOF
[Unit]
Description=Carbon Daemon
Wants=carbond-oracle.service
Wants=carbond-liquidator.service
After=network-online.target

[Service]
User=$USER
Environment="DAEMON_HOME=$HOME/.carbon"
Environment="DAEMON_NAME=$DAEMON"
Environment="PATH=$HOME/.carbon/cosmovisor/current/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Environment="POSTGRES_USER=postgres"
ExecStart=/usr/local/bin/cosmovisor start --persistence
StandardOutput=append:/var/log/carbon/start.log
StandardError=append:/var/log/carbon/start.err
Restart=always
RestartSec=3
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

echo "Setting up your oracle"

echo "---------Creating system file---------"

echo Enter keyring passphrase:
read -s WALLET_PASSWORD

sudo tee /etc/systemd/system/carbond-oracle.service > /dev/null <<EOF
[Unit]
Description=Carbon Oracle Daemon
BindsTo=carbond.service
After=carbond.service
After=network-online.target

[Service]
User=$USER
Environment="ORACLE_WALLET_LABEL=oraclewallet"
Environment="WALLET_PASSWORD=$WALLET_PASSWORD"
ExecStart=$HOME/.carbon/cosmovisor/current/bin/carbond oracle
StandardOutput=append:/var/log/carbon/oracle.log
StandardError=append:/var/log/carbon/oracle.err
Restart=always
RestartSec=3
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

echo "Setting up your liquidator"

echo "---------Creating system file---------"

sudo tee /etc/systemd/system/carbond-liquidator.service > /dev/null <<EOF
[Unit]
Description=Carbon Liquidator Daemon
BindsTo=carbond.service
After=carbond.service
After=network-online.target

[Service]
User=$USER
Environment="WALLET_PASSWORD=$WALLET_PASSWORD"
Environment="POSTGRES_USER=postgres"
ExecStart=$HOME/.carbon/cosmovisor/current/bin/carbond liquidator
StandardOutput=append:/var/log/carbon/liquidator.log
StandardError=append:/var/log/carbon/liquidator.err
Restart=always
RestartSec=3
LimitNOFILE=64000

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable carbond
