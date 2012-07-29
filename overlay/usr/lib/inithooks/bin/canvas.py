#!/usr/bin/python
"""Set Canvas admin password, email and domain to serve

Option:
    --pass=     unless provided, will ask interactively
    --email=    unless provided, will ask interactively
    --domain=   unless provided, will ask interactively
"""

import sys
import getopt
import hashlib
import random
import string

from dialog_wrapper import Dialog
from mysqlconf import MySQL
from executil import system

def usage(s=None):
    if s:
        print >> sys.stderr, "Error:", s
    print >> sys.stderr, "Syntax: %s [options]" % sys.argv[0]
    print >> sys.stderr, __doc__
    sys.exit(1)

def main():
    try:
        opts, args = getopt.gnu_getopt(sys.argv[1:], "h",
                                       ['help', 'pass=', 'email=', 'domain='])
    except getopt.GetoptError, e:
        usage(e)

    email = ""
    domain = ""
    password = ""
    for opt, val in opts:
        if opt in ('-h', '--help'):
            usage()
        elif opt == '--pass':
            password = val
        elif opt == '--email':
            email = val
        elif opt == '--domain':
            domain = val

    if not password:
        d = Dialog('TurnKey Linux - First boot configuration')
        password = d.get_password(
            "Canvas Password",
            "Enter new password for the Canvas 'admin' account.")

    if not email:
        if 'd' not in locals():
            d = Dialog('TurnKey Linux - First boot configuration')

        email = d.get_email(
            "Canvas Email",
            "Enter email address for the Canvas 'admin' account.",
            "admin@example.com")

    if not domain:
        if 'd' not in locals():
            d = Dialog('TurnKey Linux - First boot configuration')

        domain = d.get_input(
            "Canvas Domain",
            "Enter the domain to serve Canvas.",
            "www.example.com")

    salt = "".join(random.choice(string.letters) for line in range(20))
    hash = password + salt
    for i in range(20):
        hash = hashlib.sha512(hash).hexdigest()

    access_token = "".join(random.choice(string.letters) for line in range(20))

    m = MySQL()
    m.execute('UPDATE canvas_production.users SET name=\"%s\", sortable_name=\"%s\" WHERE id=1;' % (email, email))
    m.execute('UPDATE canvas_production.pseudonyms SET unique_id=\"%s\", crypted_password=\"%s\", password_salt=\"%s\", single_access_token=\"%s\" WHERE user_id=1;' % (email, hash, salt, access_token))
    m.execute('UPDATE canvas_production.communication_channels SET path=\"%s\" WHERE id=1;' % email)

    config = "/var/www/canvas/config/domain.yml"
    system("sed -i \"s|domain:.*|domain: \\\"%s\\\"|\" %s" % (domain, config))

    config = "/var/www/canvas/config/outgoing_mail.yml"
    system("sed -i \"s|domain:.*|domain: \\\"%s\\\"|\" %s" % (domain, config))
    system("sed -i \"s|outgoing_address:.*|outgoing_address: \\\"%s\\\"|\" %s" % (email, config))


if __name__ == "__main__":
    main()

