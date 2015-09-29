#!/bin/bash
set -e

# Install MongoDB 2.4

SCRIPTPATH=$( cd $(dirname $0) ; pwd -P )

apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv 7F0CEB10
echo 'deb http://downloads-distro.mongodb.org/repo/ubuntu-upstart dist 10gen' > /etc/apt/sources.list.d/mongodb.list
apt-get update
apt-get install -y mongodb-10gen=2.4.9 ruby ruby-dev sysfsutils

#cp ${SCRIPTPATH}/mongodb.service /etc/systemd/system/mongodb.service

#service mongodb restart

# TODO: replace with bundler
echo "Installing Ruby gems for helper scripts"
gem install aws-sdk -v '~> 2'
gem install mongo -v '~> 2'
gem install bson -v '~> 3'

echo "Installing rsyslog config"
cat > /etc/rsyslog.d/31-mongo-scripts.conf <<EOF
local1.*    /var/log/mongodb/scripts.log
EOF
service rsyslog restart