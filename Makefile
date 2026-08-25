WEBMIN_FW_TCP_INCOMING = 22 80 443 3000 12321

RUBY_VER=3.4
include $(FAB_PATH)/common/mk/turnkey/rails-pgsql.mk
COMMON_OVERLAYS := $(filter-out yarn,$(COMMON_OVERLAYS))
COMMON_CONF := $(filter-out yarn,$(COMMON_CONF))
include $(FAB_PATH)/common/mk/turnkey.mk
