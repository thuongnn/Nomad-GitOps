# setup nomad & consul on digital ocean for $5

**Ideally** you can point a wildcard DNS domain to your rented VM, and create
[make Lets Encrypt https certs](https://gitlab.com/internetarchive/nomad/-/blob/master/create-https-certs.sh)
files to start.

**Alternatively**
- you can step through setting up GitLab & GitLab Runner on VM
  - though you'd want a minimum $20/month 4GB RAM for GitLab
  - then GitLab, GitLab Runner, Nomad, Consul, Fabio can all talk to each other
    - see [my other talks](https://tracey.dev.archive.org/)
      - [create a webapp on GitLab](https://archive.org/~tracey/slides/devops/2021-02-03)

      - [1/3 setup GitLab & GitLab Runner on your Mac](https://archive.org/~tracey/slides/devops/2021-02-17)
      - [2/3 setup Nomad & Consul on your Mac](https://archive.org/~tracey/slides/devops/2021-02-24)
      - [3/3 connect: GitLab, GitLab Runner, Nomad & Consul](https://archive.org/~tracey/slides/devops/2021-03-10)

      - [1/2 Setup GitLab, Nomad, Consul & Fabio](https://archive.org/~tracey/slides/devops/2021-03-31)
      - [2/2 Add GitLab Runner & Setup full CI/CD pipelines](https://archive.org/~tracey/slides/devops/2021-04-07)


## environment vars (mac and VM) (example values):
```bash
export IP=143.198.132.62
export DOMAIN=xxx.archive.org
```

## just need wildcard dns certs
- setup DNS to point to your VM
- [wildcard DNS Lets Encrypt script](https://gitlab.com/internetarchive/nomad/-/blob/master/create-https-certs.sh)
```bash
scp  [DNS_CERT_FILE]  root@${IP?}:${DOMAIN?}-cert.pem
scp  [DNS_KEY__FILE]  root@${IP?}:${DOMAIN?}-key.pem
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

## mac - setup DNS to use dnsmasq first
https://archive.org/~tracey/slides/devops/2021-03-31/#/15
<img src="https://archive.org/~tracey/slides/devops/2021-03-31/dns.jpg">


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
