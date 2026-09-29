# Runs the root.patched/post recipe of one shared makefile, MK, the way
# fab's product.mk runs it. FAB_SHARE_PATH points at this directory, so the
# product.mk that MK includes is the empty one here.
include $(MK)

.PHONY: post
post:
	$(root.patched/post)
