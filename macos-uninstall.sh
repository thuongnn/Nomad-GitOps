#!/bin/zsh

# Removes nomad/consul cluster-of-1 from a Mac that has run @see `setup.sh`
#
# PLEASE verify the four main packages will be removing are right for you
# (for example, esp. you aren't using `dnsmasq` for anything else)


nomad stop fabio
# normally we use exec driver, but in case ever use docker driver for fabio:
docker stop  fabio
docker rm -v fabio


sudo brew services stop dnsmasq
sudo brew services stop consul
sudo brew services stop nomad
sleep 10

sudo killall nomad
sudo killall consul

brew uninstall  nomad  consul  dnsmasq

sudo rm -rfv $(echo "
  /etc/fabio
  /etc/consul.d
  /etc/nomad.d
  /usr/local/etc/dnsmasq/*
  /opt/nomad
  /opt/consul
  /opt/nomad
  /opt/consul
  $HOME/.config/nomad.nom
")
