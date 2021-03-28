external_url "https://git.x.archive.org"
registry_external_url "https://registry.x.archive.org:444"

nginx['listen_port'] = 80
registry_nginx['listen_port'] = 444

nginx['listen_https'] = false
registry_nginx['listen_https'] = true

nginx['redirect_http_to_https'] = false
registry_nginx['redirect_http_to_https'] = false

registry_nginx['ssl_certificate']     = "/etc/gitlab/tls/x.archive.org-cert.pem"
registry_nginx['ssl_certificate_key'] = "/etc/gitlab/tls/x.archive.org-key.pem"
