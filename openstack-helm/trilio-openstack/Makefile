# Chart-local Makefile, invoked by the parent `init-%` target.
#
# The four generated templates/bin/*.tpl files are not committed (see
# ../.gitignore); they are rendered from the *.tpl.in stubs at install time.
# helm lint / package / template all fail hard without them, because
# helm-toolkit.utils.template includes them by file path. Materialise them here
# so the parent Makefile's lint/build/package targets work on a bare clone.
.PHONY: all
all:
	@bash utils/restore_templates.sh
