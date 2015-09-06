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
   
   - Installed from upstream git repo in /var/www/canvas providing an
     easy upgrade path.
   - Installed Redis Server from Jessie repos.
   - Pre-configured to use PostgreSQL (recommended for production).
   - Includes Canvas automated jobs daemon initscript.
   - Includes Apache pre-configured with Passenger support, with SSL
     support out of the box (performance, security).
   - Includes NodeJS and NPM required for compiling assets.

- SSL support out of the box.
- Postfix MTA (bound to localhost) to allow sending of email (e.g.,
  password recovery).
- Webmin modules for configuring Apache2, PostgreSQL and Postfix.

Credentials *(passwords set at first boot)*
-------------------------------------------

- Webmin, SSH, MySQL: username **root**
- Canvas: default username is email set at first boot


.. _Canvas: http://www.instructure.com/
.. _TurnKey Core: http://www.turnkeylinux.org/core
