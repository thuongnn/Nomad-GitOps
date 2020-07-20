#!/bin/zsh -e

# cleans out prior hashistack setup


[  "$USER" != "root" ]  &&  echo run as root on a node in cluster  &&  exit 1
set -x

# nomad server force-leave
# consul leave

for CONTAINER in $(sudo docker ps|fgrep -v 'CONTAINER ID'|cut -f1 -d' '); do
  docker stop  $CONTAINER
  docker rm -v $CONTAINER
done

umount $(df -h |fgrep /var/lib/nomad |rev |cut -f1 -d' ' |rev)  ||  echo 'seems like all unmounted'


set +e
service consul stop
service  vault stop
service  nomad stop
service docker stop

systemctl disable  consul nomad vault


for i in /etc/fabio \
  /etc/nomad \
  /etc/consul \
  /etc/nomad \
  /etc/systemd/system/nomad.service \
  /etc/systemd/system/consul.service \
  /etc/systemd/system/vault.service \
  /var/lib/nomad \
  /var/lib/consul \
  /var/lib/docker \
  /etc/ferm/input/nomad.conf \
  /etc/ferm/output/nomad.conf \
  /etc/ferm/forward/nomad.conf \
  /etc/dnsmasq.d/nomad \
  /usr/sbin/consul \
  /usr/sbin/nomad \
  /usr/sbin/vault \
  $(ls /var/log/nomad*.log) \
  $(ls /var/log/consul*.log)
do
  find $i -ls -delete
done
set -e

systemctl daemon-reload

service ferm reload

service docker start
