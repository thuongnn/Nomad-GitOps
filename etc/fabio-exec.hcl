# @see https://github.com/fabiolb/fabio/blob/master/fabio.properties
# which has all the defaults and settings (commented out) which we clobber with just what's below

# you can put any domain or host-based https tls cert files into /etc/fabio/ssl/
#   https://fabiolb.net/faq/multiple-protocol-listeners/

locals {
  # contruct long string robotically
  ports = [443, 8012, 4245, 6881, 6969, 99]
  addrs = join(",", [for po in local.ports : "127.0.0.1:${po};cs=my-certs;type=path;cert=/etc/fabio/ssl"])
}

job "fabio" {
  datacenters = ["dc1"]
  group "fabio" {
    count = 1
    task "fabio" {
      driver = "raw_exec"
      config {
        command = "fabio"
        args    = [
          "-proxy.cs", "cs=my-certs;type=path;cert=/etc/fabio/ssl",
          "-proxy.addr", "${local.addrs},127.0.0.1:80",
          # setup HSTS headers - ensuring all services only communicate with https
          "-proxy.header.sts.maxage", "15724800",
          "-proxy.header.sts.subdomains",
          # get client IP sent to containers
          "-proxy.header.clientip", "X-Forwarded-For",
        ]
      }
      artifact {
        source      = "https://github.com/fabiolb/fabio/releases/download/v1.5.15/fabio-1.5.15-go1.15.5-darwin_amd64"
        destination = "local/fabio"
        mode        = "file"
      }
    }
  }
}
