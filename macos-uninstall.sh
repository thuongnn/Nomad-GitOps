#!/bin/zsh

# Removes nomad/consul cluster-of-1 from a Mac that has run @see `setup.sh`
#
# PLEASE verify the four main packages will be removing are right for you
# (for example, esp. you aren't using `dnsmasq` or `supervisor` for anything else)

# docker stop  fabio
# docker rm -v fabio
nomad stop fabio

sudo brew services stop dnsmasq

sudo supervisorctl stop all
sleep 5
SUPERPID=$(ps auxwww |fgrep /usr/local/bin/supervisord |grep -v grep |tr -s ' ' |cut -f2 -d ' ')
sudo kill $SUPERPID
sleep 5
sudo killall nomad
sudo killall consul

brew uninstall  nomad  consul  supervisor  dnsmasq

sudo rm -rfv $(echo "
  /etc/fabio
  /etc/consul.d
  /etc/nomad.d
  /usr/local/etc/dnsmasq/*
  /opt/nomad
  /opt/consul
  /usr/local/etc/supervisord.conf
  /usr/local/etc/supervisor.d/
  /usr/local/var/log/supervisord.log
  /opt/nomad
  /opt/consul
  $HOME/.config/nomad.nom
")
