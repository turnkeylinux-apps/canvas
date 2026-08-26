Canvas - Learning Management System
===================================

`Canvas`_ is a learning management system that helps busy teachers and
administrators save hours in their classes and institutions. It helps
create amazing course content with a rich content editor, speed up
grading, track learning outcomes, and can send notifications via email,
facebook and text notifications.

This appliance includes all the standard features in `TurnKey Core`_,
and on top of that:

- Canvas configurations:
   
   - Installed from the official Canvas ``prod`` channel in
     ``/var/www/canvas`` at a verified source commit.

     **Security note**: Updates to Canvas may require supervision so
     they **ARE NOT** configured to install automatically. See `Canvas
     documentation`_ for upgrade instructions.

     ``turnkey-canvas-update --check`` reports the installed and eligible
     production commits. ``--apply --dry-run`` shows the supervised update
     target without changing the appliance.

   - Includes Redis Server from Debian Trixie.
   - Pre-configured to use PostgreSQL (recommended for production).
   - Includes Canvas automated jobs daemon initscript.
   - Includes Apache pre-configured with Passenger support, with SSL
     support out of the box (performance, security).
   - Includes Debian Node.js 20 and NPM, plus Yarn Classic from the signed
     official Yarn package channel, as required for compiling assets.
   - Includes the official Canvas Rich Content Editor API at a verified
     source commit.

- SSL support out of the box.
- Postfix MTA (bound to localhost) to allow sending of email (e.g.,
  password recovery).
- Webmin modules for configuring Apache2, PostgreSQL and Postfix.

Credentials *(passwords set at first boot)*
-------------------------------------------

- Webmin, SSH: username **root**
- Canvas: default username is email set at first boot

.. _Canvas: https://www.instructure.com/
.. _TurnKey Core: https://www.turnkeylinux.org/core
.. _Canvas documentation: https://github.com/instructure/canvas-lms/wiki/Upgrading#canvas-upgrade
