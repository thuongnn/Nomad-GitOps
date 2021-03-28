external_url "https://git.x.archive.org"
registry_external_url "https://registry.x.archive.org"
# registry_external_url "https://registry.x.archive.org:88"


nginx['listen_port'] = 80
registry_nginx['listen_port'] = 80

nginx['listen_https'] = false
registry_nginx['listen_https'] = false

nginx['redirect_http_to_https'] = false

# new:
registry_nginx['redirect_http_to_https'] = false

# new:
nginx['proxy_set_headers'] = {
  "X-Forwarded-Proto" => "http",
  "X-Forwarded-Protocol" => "http",
  "Host" => "registry.x.archive.org"
 }
