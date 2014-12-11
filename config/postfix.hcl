consul = "{{ CONSUL_IP }}:{{ CONSUL_HTTP_API_PORT }}"

template {
  source = "/etc/consul-template/postfix_main.cf.ctmpl"
  destination = "/etc/postfix/main.cf"
  command = "supervisorctl restart postfix"
}

template {
  source = "/etc/consul-template/postfix_sender_transport.ctmpl"
  destination = "/etc/postfix/sender_transport"
  command = "postmap /etc/postfix/sender_transport && supervisorctl restart postfix"
}
