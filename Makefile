# Copyright 2016-2018 PreEmptive Solutions, LLC
# See LICENSE.txt for licensing information

PROJECT_NAME=PPiOS-Rename
NUMERIC_VERSION=1.4.0
VERSION=v$(NUMERIC_VERSION)
PROGRAM_NAME=ppios-rename

BUILD_DIR=build
PROGRAM="$(shell pwd)/$(BUILD_DIR)/Build/Products/Release/$(PROGRAM_NAME)"
README="$(shell pwd)/README.md"
GIT_CMD=git rev-parse --short HEAD
GIT_HASH_CHECK=$(GIT_CMD) &> /dev/null
GIT_HASH=$(shell $(GIT_HASH_CHECK) && $(GIT_CMD) | sed 's,^,-,')
BUILD_NUMBER_CHECK=! test -z "$${BUILD_NUMBER}"
BUILD_NUMBER=$(shell $(BUILD_NUMBER_CHECK) && echo $${BUILD_NUMBER} | sed 's,^,-,')
DIST_DIR=$(PROJECT_NAME)-$(VERSION)
FULL_VERSION=$(VERSION)$(GIT_HASH)$(BUILD_NUMBER)
ARCHIVE_DIR=$(FULL_VERSION)
DIST_PACKAGE=$(ARCHIVE_DIR)/$(PROJECT_NAME)-$(FULL_VERSION).tgz
WORKSPACE=ppios-rename.xcworkspace

XCODEBUILD_OPTIONS=\
	-workspace $(WORKSPACE) \
	-scheme ppios-rename \
	-configuration Release \
	-derivedDataPath $(BUILD_DIR)

.PHONY: default
default: all

.PHONY: all
all: Pods $(WORKSPACE) program

# convenience target
.PHONY: it
it: clean all check

$(WORKSPACE) Pods Podfile.lock: Podfile
	pod install

.PHONY: program
program: Pods build test

.PHONY: build
build:
	xcodebuild $(XCODEBUILD_OPTIONS) CLASS_DUMP_VERSION=$(NUMERIC_VERSION)$(GIT_HASH) build

.PHONY: test
test:
	xcodebuild $(XCODEBUILD_OPTIONS) test

.PHONY: check
check:
	( cd test/tests ; PPIOS_RENAME=$(PROGRAM) README=$(README) NUMERIC_VERSION=$(NUMERIC_VERSION) ./test-suite.sh )

.PHONY: archive
archive: package-check distclean archive-dir program check $(DIST_PACKAGE)
	cp -r $(PROGRAM).dSYM $(ARCHIVE_DIR)/

.PHONY: package-check
package-check:
	@$(GIT_HASH_CHECK) || echo "Info: git hash unavailable, omitting from package name"
	@$(BUILD_NUMBER_CHECK) || echo "Info: BUILD_NUMBER unset, omitting from package name"

.PHONY: archive-dir
archive-dir:
	mkdir -p $(ARCHIVE_DIR)

$(DIST_PACKAGE): program
	mkdir -p $(DIST_DIR)
	cp $(PROGRAM) \
		README.md \
		LICENSE.txt \
		ThirdPartyLicenses.txt \
		CHANGELOG.md \
		$(DIST_DIR)
	tar -cvpzf $@ --options gzip:compression-level=9 $(DIST_DIR)

.PHONY: clean
clean:
	$(RM) -r $(BUILD_DIR)

.PHONY: distclean
distclean: clean
	$(RM) -r Pods $(DIST_DIR)* $(VERSION)*
