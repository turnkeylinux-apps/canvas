WEBMIN_FW_TCP_INCOMING = 22 80 443 3000 12321

RUBY_VER=3.1.4
include $(FAB_PATH)/common/mk/turnkey/rails-pgsql.mk
include $(FAB_PATH)/common/mk/turnkey/nodejs.mk
include $(FAB_PATH)/common/mk/turnkey.mk
