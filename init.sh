#!/bin/bash
set -eo pipefail

_log(){
  declare BLUE="\e[32m" WHITE="\e[39m"
  echo -e "$(date --iso-8601=s)${BLUE} (info)${WHITE}:" $@
}

_error(){
  declare RED="\e[91m" WHITE="\e[39m"
  echo -e "$(date --iso-8601=s)${RED} (error)${WHITE}:" $@
  exit 1
}

check_postfix_tls_files(){
  local SSL_DIR="/etc/postfix/ssl"

  _log "Checking presence of TLS files for 'postfix'..."
  if [ ! -f ${SSL_DIR}/mail.key -a ! -f ${SSL_DIR}/mail.crt -a ${SSL_DIR}/ca.crt ]; then
    _error "> files aren't present: exiting"
  fi
}

check_postfix_providers_files(){
  local PROVIDERS_DIR="/etc/postfix/providers"

  _log "Checking presence of 'Providers' SASL files..."
  if [ ! -f ${PROVIDERS_DIR}/sasl_passwd ]; then
    _error "> files aren't present: exiting"
  else
    postmap ${PROVIDERS_DIR}/sasl_passwd
  fi
}

waiting_consul_is_up(){
  CONSUL_IP=${CONSUL:-}
  CONSUL_HTTP_API_PORT=${CONSUL_HTTP_API_PORT:-8500}

  if [ -n "${CONSUL_IP}" ]; then
    declare TIMEOUT=60

    _log "Checking if Consul ($CONSUL_IP:$CONSUL_HTTP_API_PORT) is up..."
    until curl -s --max-time 1 "http://"$CONSUL_IP":"$CONSUL_HTTP_API_PORT"/v1/agent/self/"; do
      TIMEOUT=$(expr $TIMEOUT - 1)
      if [ $TIMEOUT -eq 0 ]; then
        _error "Could not connect to Consul server. Aborting..."
      fi
      echo "> waiting for Consul..."
    done
  else
    _error "'CONSUL' environnment variable isn't defined"
  fi
}

configure_consul_template() {
  _log "Configure 'consul-template' with Consul access ($CONSUL_IP:$CONSUL_HTTP_API_PORT)..."
  sed -i -e 's/{{ CONSUL_IP }}/'$CONSUL_IP'/g' -e 's/{{ CONSUL_HTTP_API_PORT }}/'$CONSUL_HTTP_API_PORT'/g' /etc/consul-template/config.hcl
}

create_sasl_users(){
  SASL_USERS=${SASL_USERS:-}

  if [ -n "${SASL_USERS}" ]; then
    _log "Creating SASL database based on 'SASL_USERS' environnment variable..."
    echo $SASL_USERS | tr , \\n > /tmp/sasl-users
    while IFS=":" read -r _userid _pwd; do
      _log "> create user '$_userid'"
      echo $_pwd | saslpasswd2 -p -c $_userid
    done < /tmp/sasl-users
    chown postfix /etc/sasldb2 && chmod 440 /etc/sasldb2
  fi
}

configure_sasl(){
  declare SASL_SMTPD_FILE="/etc/postfix/sasl/smtpd.conf"

  _log "Configure SASL..."
  cat << EOF > ${SASL_SMTPD_FILE}
pwcheck_method: auxprop
mech_list: CRAM-MD5 DIGEST-MD5
EOF
}

configure_postfix_master_services(){
  local POSTFIX_MASTER_FILE="/etc/postfix/master.cf"

  _log "Configuring postfix 'master' services..."
  _log "> disable 'smtp' service (25/tcp)"
  sed -i -e "s/^\(smtp.*inet.*smtpd\)$/#\1/g" ${POSTFIX_MASTER_FILE}

  _log "> enable 'submission' service (587/tcp)"
  if [ $(grep -c "^#submission" ${POSTFIX_MASTER_FILE}) == "1" ]; then
    sed -i -e "s/^#submission.*$//g" ${POSTFIX_MASTER_FILE}

    cat << EOF >> ${POSTFIX_MASTER_FILE}
submission inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
EOF
  else
    _log ">> already active"
  fi
}

configure_postfix(){
  _log "Configure postfix..."

  _log "> disable chroot options for all the configuration"
  postconf -F '*/*/chroot = n'

  local MTA_HOSTNAME=${MTA_HOSTNAME:-$(hostname --fqdn)}
  _log "> setting postfix hostname to '$MTA_HOSTNAME'"
  sed -i -e 's/{{ MTA_HOSTNAME }}/'$MTA_HOSTNAME'/g' /etc/consul-template/postfix_main.cf.ctmpl
}

run_consul_template_once()
{
  declare KEY="config/mail/transports/default"

  _log "Running consul-template once..."

  _log "> checking if '$KEY' key is defined"
  HTTP_CODE=$(curl -o /dev/null -sw "%{http_code}" http://192.168.10.10:8500/v1/kv/$KEY)
  if [ $HTTP_CODE -ne "200" ]; then
    if [ $HTTP_CODE -eq "404" ]; then
      _error "'$KEY' key isn't defined. Exiting..."
    else
      _error "Consul return HTTP code '$HTTP_CODE'. Exiting..."
    fi
  fi

  _log "> starting 'consul-template' once time"
  /usr/local/bin/consul-template \
  -consul=${CONSUL_IP}:${CONSUL_HTTP_API_PORT} \
  -template="/etc/consul-template/postfix_main.cf.ctmpl:/etc/postfix/main.cf" \
  -template="/etc/consul-template/postfix_sender_transport.ctmpl:/etc/postfix/sender_transport:postmap /etc/postfix/sender_transport" \
  -once
}

configure_rsyslog_mail_facility(){
  local MAIL_LOG=${MAIL_LOG:-}

  _log "Configure rsyslog log file for 'mail' facility..."
  if [ -n "${MAIL_LOG}" ]; then
    sed -i -e 's@-/var/log/mail.log@-'${MAIL_LOG}'@g' /etc/rsyslog.d/50-default.conf
    _log "> set to '${MAIL_LOG}'"
  else
    _log "> set to '/var/log/mail.log'"
  fi
}

start_supervisor(){
  _log "Starting supervisord..."
  /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
}

main(){
  check_postfix_tls_files
  check_postfix_providers_files
  create_sasl_users
  configure_sasl
  configure_postfix
  configure_postfix_master_services
  configure_rsyslog_mail_facility
  waiting_consul_is_up
  configure_consul_template
  run_consul_template_once
  start_supervisor
}


main
