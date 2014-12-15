FROM ubuntu:14.04

## -- Installation --
ENV DEBIAN_FRONTEND noninteractive
## system upgrade
RUN apt-get update && \
    apt-get upgrade -y
## tools
RUN apt-get install wget curl supervisor -y
## postfix and dependencies
RUN apt-get install postfix sasl2-bin -y
## consul-template
ENV CONSUL_TPL_VERSION 0.3.1
RUN cd /opt && \
    wget -q https://github.com/hashicorp/consul-template/releases/download/v${CONSUL_TPL_VERSION}/consul-template_${CONSUL_TPL_VERSION}_linux_amd64.tar.gz && \
    tar xvzf consul-template_${CONSUL_TPL_VERSION}_linux_amd64.tar.gz && \
    mv consul-template_${CONSUL_TPL_VERSION}_linux_amd64/consul-template /usr/local/bin && \
    chmod u+x /usr/local/bin/consul-template && \
    rm -fr /opt/consul-template*


## -- Configuration --
## consul-template
RUN mkdir /etc/consul-template/
ADD config/postfix_main.cf.ctmpl /etc/consul-template/postfix_main.cf.ctmpl
ADD config/postfix_sender_transport.ctmpl /etc/consul-template/
ADD config/postfix.hcl /etc/consul-template/config.hcl
## supervisor
ADD config/supervisor-postfix.conf /etc/supervisor/conf.d/postfix.conf
ADD config/supervisor-rsyslog.conf /etc/supervisor/conf.d/rsyslog.conf
ADD config/supervisor-consul-template.conf /etc/supervisor/conf.d/consul-template.conf
## init script
ADD init.sh /init.sh
RUN chmod +x /init.sh
## volumes
VOLUME ["/etc/postfix/providers"]
VOLUME ["/etc/postfix/ssl"]
VOLUME ["/etc/postfix/sasl"]

EXPOSE 587
CMD ["/init.sh"]
