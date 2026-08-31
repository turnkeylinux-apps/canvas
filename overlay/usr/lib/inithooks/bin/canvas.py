#!/usr/bin/python3
"""Set Canvas admin password, email and domain to serve

Option:
    --pass-stdin read the password from standard input
    --email=    unless provided, will ask interactively
    --domain=   unless provided, will ask interactively
                DEFAULT=www.example.com
"""

import sys
import getopt
import json
import re
import subprocess
from pathlib import Path

from libinithooks import inithooks_cache
from libinithooks.dialog_wrapper import Dialog


def usage(s=None):
    if s:
        print("Error:", s, file=sys.stderr)
    print("Syntax: %s [options]" % sys.argv[0], file=sys.stderr)
    print(__doc__, file=sys.stderr)
    sys.exit(1)


DEFAULT_DOMAIN = "www.example.com"


def main():
    try:
        opts, args = getopt.gnu_getopt(
            sys.argv[1:], "h",
            ['help', 'pass=', 'pass-stdin', 'email=', 'domain='])
    except getopt.GetoptError as e:
        usage(e)

    email = ""
    domain = ""
    password = ""
    password_stdin = False
    for opt, val in opts:
        if opt in ('-h', '--help'):
            usage()
        elif opt == '--pass':
            password = val
        elif opt == '--pass-stdin':
            password_stdin = True
        elif opt == '--email':
            email = val
        elif opt == '--domain':
            domain = val

    if password and password_stdin:
        usage('--pass and --pass-stdin are mutually exclusive')

    if password_stdin:
        password = sys.stdin.read()
        if not password:
            usage('standard input did not contain a password')
    elif not password:
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

    inithooks_cache.write('APP_EMAIL', email)

    if not domain:
        if 'd' not in locals():
            d = Dialog('TurnKey Linux - First boot configuration')

        domain = d.get_input(
            "Canvas Domain",
            "Enter the domain to serve Canvas.",
            DEFAULT_DOMAIN)

    if domain == "DEFAULT":
        domain = DEFAULT_DOMAIN

    inithooks_cache.write('APP_DOMAIN', domain)

    payload = json.dumps({'password': password, 'email': email})
    rails_script = f'''\
require "json"
payload = JSON.parse({json.dumps(payload)})
user = User.find(1)
pseudonym = user.pseudonyms.active.first!
pseudonym.unique_id = payload.fetch("email")
pseudonym.password = payload.fetch("password")
pseudonym.password_confirmation = payload.fetch("password")
pseudonym.save!
user.update!(name: payload.fetch("email"),
             short_name: payload.fetch("email"),
             sortable_name: payload.fetch("email"))
channel = user.communication_channels.first
channel.update!(path: payload.fetch("email")) if channel
'''
    subprocess.run(
        [
            'su', '-s', '/bin/bash', '-l', 'www-data', '-c',
            'cd /var/www/canvas && RAILS_ENV=production '
            'BUNDLE_PATH=vendor/bundle bundle exec rails runner -',
        ],
        input=rails_script,
        text=True,
        check=True,
    )

    def replace_yaml_value(config, key, value):
        path = Path(config)
        pattern = re.compile(
            rf'^(\s*{re.escape(key)}:\s*).*$', re.MULTILINE)
        updated, count = pattern.subn(
            lambda match: match.group(1) + json.dumps(value),
            path.read_text(encoding='utf-8'))
        if count != 1:
            raise RuntimeError(
                f'{config} contained {count} values for {key}, expected one')
        path.write_text(updated, encoding='utf-8')

    replace_yaml_value(
        '/var/www/canvas/config/outgoing_mail.yml', 'domain', domain)
    replace_yaml_value(
        '/var/www/canvas/config/outgoing_mail.yml',
        'outgoing_address', email)
    replace_yaml_value(
        '/var/www/canvas/config/dynamic_settings.yml',
        'app-host', f'{domain}:3000')
    replace_yaml_value(
        '/var/www/canvas/config/domain.yml', 'domain', domain)

    print("Restarting services; please wait...")
    for service in ['canvas_init', 'apache2']:
        subprocess.run(['systemctl', 'restart', service], check=True)


if __name__ == "__main__":
    main()
