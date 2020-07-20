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
  sudo docker run -it --name certomatic ubuntu:bionic bash -c "
    apt-get -yqq update  && \
    apt-get -yqq install git  && \
    cd /opt  && \
    git clone https://github.com/certbot/certbot
    cd /opt/certbot
    ./certbot-auto --install-only
  "
  sudo docker commit certomatic certomatic
  sudo docker rm -v  certomatic
)

mkdir -p -m777 certs
sudo docker run -it --rm -v $(pwd)/certs:/x certomatic bash -c "
  cd /opt/certbot
  echo c | ./certbot-auto

  ./certbot-auto certonly --manual --preferred-challenges=dns --server https://acme-v02.api.letsencrypt.org/directory  -d '*.${TLS_DOMAIN?}'


  cd /etc/letsencrypt/live/*/
  cp -p fullchain.pem /x/${TLS_DOMAIN?}-cert.pem
  cp -p privkey.pem   /x/${TLS_DOMAIN?}-key.pem
"
