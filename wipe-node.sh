#!/bin/zsh

# cleans out prior hashistack setup
#
#  ** PLEASE **  look this script over in its entirety before running ;-)


[  "$USER" != "root" ]  &&  echo run as root on a node in cluster  &&  exit 1
set -x

# nomad server force-leave
# consul leave

typeset -a CONTAINERS
CONTAINERS=( $(sudo docker ps |fgrep -v 'CONTAINER ID' |cut -f1 -d' ' ) ) # |tr '\n' ' ') )
docker stop   $CONTAINERS
sleep 10
docker rm -v  $CONTAINERS
docker rm -v  $CONTAINERS


umount $(df -h |fgrep /var/lib/nomad |rev |cut -f1 -d' ' |rev)  ||  echo 'seems like all unmounted'


set +e
for i in  nomad  consul  docker  fabio  docker-ce; do
  service $i stop
  apt-get -yqq purge $i
  systemctl disable $i.service
  systemctl reset-failed
  systemctl daemon-reload

  find  /opt/$i  /etc/$i  /etc/$i.d  /var/lib/$i  -delete

  killall $i
done

rm -fv /etc/ferm/*/nomad.conf /etc/dnsmasq.d/nomad

service ferm reload


rmdir /pv/[0-9]*
rmdir /pv

[ -e /pv ]  &&  echo "

NOTE: NOT removing remaining non-empty Persistent Volume dirs:

"  &&  ls /pv/[0-9]*
