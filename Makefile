define root.patched/pre
		fab-apply-overlay gems.overlay $O/root.patched
endef

COMMON_OVERLAYS += nodejs-install
COMMON_CONF += nodejs-install

include $(FAB_PATH)/common/mk/turnkey/rails.mk
include $(FAB_PATH)/common/mk/turnkey.mk
