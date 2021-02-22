#!/bin/zsh -e

# Sets up a https cert for an entire domain w/ let's encrypt
# https://medium.com/@saurabh6790/generate-wildcard-ssl-certificate-using-lets-encrypt-certbot-273e432794d7

# https://github.com/kubernetes/ingress-nginx/issues/2045

# https://community.letsencrypt.org/t/confusing-on-root-domain-with-wildcard-cert/56113


[ $# -lt 1 ]  &&  echo "usage: $0 [TLS_DOMAIN eg: x.archive.org]"  &&  exit 1
set -x
TLS_DOMAIN=$1


# This part is pretty slow, so let's do all the slow setup and save it for reuse.
# You can `sudo docker rmi certomatic` later as desired
sudo docker run -it --rm certomatic echo  || (
  sudo docker run -it --name certomatic ubuntu:rolling bash -c '
    export DEBIAN_FRONTEND=noninteractive
    apt-get -yqq update
    apt-get -yqq install  certbot
  '
  sudo docker commit certomatic certomatic
  sudo docker rm -v  certomatic
)


sudo touch     ${TLS_DOMAIN?}-{cert,key}.pem
sudo chmod 666 ${TLS_DOMAIN?}-{cert,key}.pem

sudo docker run -it --rm -v $(pwd):/x  certomatic  bash -c "
  certbot certonly --manual --manual-public-ip-logging-ok --preferred-challenges dns-01 \
    --server https://acme-v02.api.letsencrypt.org/directory -d '*.${TLS_DOMAIN?}'
  set -x
  cd /etc/letsencrypt/live/*/
  cp -p fullchain.pem /x/${TLS_DOMAIN?}-cert.pem
  cp -p privkey.pem   /x/${TLS_DOMAIN?}-key.pem
  echo 'type exit to finish'
  bash
"
sudo chmod 444 ${TLS_DOMAIN?}-cert.pem
sudo chmod 400 ${TLS_DOMAIN?}-key.pem