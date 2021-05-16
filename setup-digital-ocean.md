# setup nomad & consul on digital ocean for $5

**Ideally** you can point a wildcard DNS domain to your rented VM,
and create [make Lets Encrypt https certs](xxx) files to start.

**Alternatively**
- you can step through setting up GitLab & GitLab Runner on VM
  - though you'd want a minimum $20/month 4GB RAM for GitLab
  - then GitLab, GitLab Runner, Nomad, Consul, Fabio can all talk to each other
  - see my other talks xxx


## environment (mac and VM):
```bash
export IP=143.198.132.62
export DOMAIN=xxx.archive.org
```

## just need wildcard dns certs
- setup DNS to point to your VM
- xxx link to wildcard LE script
```bash
scp  [DNS CERT FILE]  root@${IP?}:${DOMAIN?}-cert.pem
scp  [DNS KEY  FILE]  root@${IP?}:${DOMAIN?}-key.pem
```

## on mac/linux laptop, point domain to your VM IP address with `dnsmasq` (if needed)
```bash
brew install dnsmasq

echo "
address=/${DOMAIN?}/${IP?}
listen-address=127.0.0.1
" >> $(brew --prefix)/etc/dnsmasq.conf

sudo brew services restart dnsmasq
```

## xxx mac DNS slide


## rest of instructions are on digital ocean VM

## login to digital ocean VM
```bash
ssh root@${IP?}

export FIRST=$(hostname -s).${DOMAIN?}
```


## point DNS names to yourself (if needed)
```bash
echo "${IP?}  nom.${DOMAIN?}  ${FIRST?}" >> /etc/hosts
```


## basic setup
```bash
git clone https://gitlab.com/internetarchive/nomad

apt-get install -yqq zsh

hostname ${FIRST?}
```


## setup cluster
```bash
echo ${FIRST?}
nomad/setup.sh  ${DOMAIN?}-cert.pem  ${DOMAIN?}-key.pem
```


## afterwards, upon any relogin
```bash
source /root/.config/nomad

nomad status
```
