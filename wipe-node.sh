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


(
  set +e
  for i in  nomad  vault  consul  docker  fabio  docker-ce; do
    service $i stop
    apt-get -yqq purge $i
    systemctl daemon-reload

    find  /opt/$i  /etc/$i  /etc/$i.d  /var/lib/$i  -ls -delete

    killall $i
  done

  rm -fv /etc/ferm/*/nomad.conf /etc/dnsmasq.d/nomad

  service ferm reload
)
