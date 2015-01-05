#!/usr/bin/python
# -*- coding: utf-8 -*-

import argparse
import glob
import uuid
import os
import logging
import subprocess
import sys
from ConfigParser import SafeConfigParser
from colorlog import ColoredFormatter
from flanker import mime

def get_config(config_file):
    '''
    Get config from 'ini' file
    '''
    if os.path.exists(config_file):
        config = SafeConfigParser()
        config.read(config_file)
        return config
    else:
        print("Configuration file '%s' not found: exiting..." % config_file)
        sys.exit(1)


def configure_parser():
    '''
    Parser configuration
    '''
    parser = argparse.ArgumentParser()
    parser.add_argument("sender", help="email sender")
    parser.add_argument("recipients", help="list of all the recipients", nargs='+')
    return parser.parse_args()


def configure_logger(log_file):
    '''
    Logger configuration
    '''
    logger = logging.getLogger(__name__)
    logger.setLevel(logging.DEBUG)
    formatter = ColoredFormatter(
            '%(asctime)s %(log_color)s(%(levelname)-s)%(reset)s - %(yellow)s%(funcName)s:%(reset)s %(message)s ',
            datefmt='%Y-%m-%dT%H:%M:%S',
            log_colors={
                'DEBUG':    'cyan',
                'INFO':     'green',
                'ERROR':    'red',
            })

    # stream_handler = logging.StreamHandler()
    # stream_handler.setLevel(logging.DEBUG)
    # stream_handler.setFormatter(formatter)
    # logger.addHandler(stream_handler)

    file_handler = logging.FileHandler(log_file)
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(formatter)
    logger.addHandler(file_handler)

    return logger


class Email:
    def __init__(self, filter_dir=None):
        self.filter_dir = filter_dir
        self.uuid = ""
        self.sender = ""
        self.recipients = ""
        self.origin_recipients = ""
        self.raw = ""
        self.env_header = ""
        self.has_changed = False


    def generate_uuid(self, logger):
        '''
        Generate email UUID
        - based on the host ID and current time
        - cut to 10 digits
        - uppercase
        '''
        self.uuid = str(uuid.uuid1()).replace("-", "")[:10].upper()
        logger.info("%s: new uuid has been generate for incoming email" % self.uuid)


    def load_from_stdin(self, logger):
        '''
        Load email from standard input
        '''
        logger.info("%s: loading email from stdin" % self.uuid)
        email_string = ""
        for line in sys.stdin:
            email_string += line
        self.raw = mime.from_string(email_string)

        self.raw.headers.add("X-Capkopper-Filter-UUID", self.uuid)


    def save_to_disk(self, logger, ext):
        '''
        Save 'raw' email attribute to disk
        '''
        if os.path.exists(self.filter_dir):
            f_name = os.path.join(self.filter_dir,self.uuid + "." + ext)
            logger.info("%s: saving email to disk (%s)" % (self.uuid, f_name))
            f = open(f_name, "w")
            f.write(self.raw.to_string())
            f.close()
        else:
            logger.error("Directory (%s) doesn't exists" % self.filter_dir)
            sys.exit(1)


    def set_sender(self, sender):
        self.sender = sender


    def set_recipients(self, recipients):
        self.recipients = str(recipients).strip('[]').replace(", ", " ").replace(",", " ").replace("'", "")
        self.origin_recipients = self.recipients


    def check_env_header(self, logger, default_env_header):
        '''
        Check 'X-Capkopper-Env' header
        - if not defined set to default value
        '''
        env_header = self.raw.headers.get("X-Capkopper-Env")

        if env_header is None:
            logger.info("%s: header 'X-Capkopper-Env' isn't present, set it to '%s'" % (self.uuid, default_env_header))
            self.raw.headers.add("X-Capkopper-Env", default_env_header)
            env_header = default_env_header
        else:
            logger.info("%s: header 'X-Capkopper-Env' is present (%s)" % (self.uuid, env_header))

        self.env_header = env_header


    def set_transport_from_env_header(self, logger):
        '''
        Set transport due to 'X-Capkopper-Env'
        '''
        logger.info("%s: set 'X-Capkopper-Env-Transport' " % self.uuid)
        if ( self.env_header == "dev" or
             self.env_header == "development"):
            self.raw.headers.add("X-Capkopper-Env-Transport", "dev")
        elif ( self.env_header == "preprod" or
               self.env_header == "preproduction" or
               self.env_header == "staging"):
            self.raw.headers.add("X-Capkopper-Env-Transport", "staging")


    def set_recipients_from_headers(self, logger, default_recipients_header):
        '''
        Set email recipients according to 'X-Capkopper' header
        '''
        recipients_header = self.raw.headers.get("X-Capkopper-Recipients")

        ## -- dev and staging environments --
        if ( self.env_header == "dev" or
             self.env_header == "development" or
             self.env_header == "preprod" or
             self.env_header == "preproduction" or
             self.env_header == "staging"
             ):
            # divert to 'X-Capkopper-Recipients' value if it's defined,
            # otherwise set to default recipients
            if recipients_header is None:
                logger.info("%s: header 'X-Capkopper-Recipients' isn't present, set it to '%s'" % (self.uuid, default_recipients_header))
                divert_recipients = default_recipients_header
            else:
                logger.info("%s: header 'X-Capkopper-Recipients' is present (%s)" % (self.uuid, recipients_header))
                divert_recipients = recipients_header.replace(",", " ")

            # set recipients to diverted value
            logger.info("%s: email has been divert to '%s'" % (self.uuid, divert_recipients))
            self.recipients = divert_recipients
            # add origin recipients informations
            logger.debug("%s: add 'X-Capkopper-Filter-Origin-Recipients' header" % self.uuid)
            self.raw.headers.add("X-Capkopper-Filter-Origin-Recipients", self.origin_recipients.replace(" ", ","))

            # remove the 'To' header (will be added later by sendmail)
            if self.raw.headers["To"] is not None:
                logger.info("%s: 'To' header has been detected, remove it" % self.uuid)
                self.raw.remove_headers("To")

            # flag that email has changed
            self.has_changed = True

        ## -- production environment --
        elif (  self.env_header == "prod" or
                self.env_header == "production" or
                self.env_header == "live"
                ):
            logger.info("%s: no modification are allowed on 'live' environment" % self.uuid)

        else:
            logger.error("%s: Wrong value for 'X-Capkopper-Env' header: %s" % (self.uuid, env_header))
            sys.exit(1)


    def tag_changes(self, logger):
        '''
        Tag that the email has changed
          - add a customer header "X-Capkopper-Filter"
          - add a prefix in the email 'Subject' (dev)
          - TODO : add modifications informations into mail body
        '''
        if self.has_changed is True:
            logger.info("%s: tag that email has changed" % self.uuid)
            self.raw.headers.add("X-Capkopper-Modify", "yes")

            # email subject
            self.raw.headers["Subject"] = u"[This email has been divert] - " + self.raw.headers["Subject"]

            # email body


    def send(self, logger, ext):
        '''
        Resubmit email to postfix using 'sendmail' command
        '''
        logger.info("%s: submit email with 'sendmail' command" % self.uuid)

        # get the filtered email...
        logger.debug("%s: get '%s' email from disk" % (self.uuid, ext))
        mail = subprocess.Popen(['cat', os.path.join(self.filter_dir,self.uuid + "." + ext) ],
                            stdout=subprocess.PIPE
                            )
        # ... and resubmit it
        logger.debug("%s: resubmit email to postfix", self.uuid)
        send_cmd = subprocess.Popen(['/usr/sbin/sendmail', '-G', '-i', '-f', self.sender, "--", self.recipients],
                            stdin=mail.stdout,
                            stdout=subprocess.PIPE
                            )


    def delete_from_disk(self, logger):
        '''
        Delete email files from disk after sending
        '''
        logger.info("%s: deleting email files from disk" % self.uuid)
        for f in glob.glob(os.path.join(self.filter_dir, self.uuid + "*")):
            logger.debug("%s " % f)
            os.remove(f)


def main():
    '''
    Main process
    '''
    # basic configuration
    config = get_config(os.path.join(os.path.dirname(__file__), "filter.settings"))
    args = configure_parser()
    logger = configure_logger(config.get("log", "file"))

    # get email, sender and recipients
    email = Email(config.get("filter", "dir"))
    email.generate_uuid(logger)
    email.load_from_stdin(logger)
    email.save_to_disk(logger, "in")
    email.set_sender(args.sender)
    email.set_recipients(args.recipients)

    # 'modify' email due to headers
    email.check_env_header(logger, config.get("headers", "default_env"))
    email.set_transport_from_env_header(logger)
    email.set_recipients_from_headers(logger, config.get("headers", "default_recipients"))
    email.tag_changes(logger)

    # send 'filtered' email
    email.save_to_disk(logger, "filtered")
    email.send(logger, "filtered")
    email.delete_from_disk(logger)


main()
