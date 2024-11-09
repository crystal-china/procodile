NAME = procodile
CRYSTAL_ENTRY := $(shell pwd)/$(shell cat shard.yml |grep main: |cut -d: -f2|cut -d" " -f2)
CRYSTAL_ENTRY != echo ${CRYSTAL_ENTRY} |cut -c2-
COMPILER ?= crystal
SHARDS ?= shards
CHECK ?= shards_check
CACHE_DIR != ${COMPILER} env CRYSTAL_CACHE_DIR
CACHE_DIR := $(CACHE_DIR)/$(subst /,-,${CRYSTAL_ENTRY})
FLAGS ?= --progress -Dstrict_multi_assign -Dno_number_autocast
RELEASE_FLAGS ?= --progress --production --release -Dstrict_multi_assign -Dno_number_autocast

# INSTALL:
DESTDIR ?= /usr/local
BINDIR ?= $(DESTDIR)/bin
INSTALL ?= /usr/bin/install

SOURCES := $(shell find src -name '*.cr')
O := bin/$(NAME)

.PHONE: test
test: $(O)
	scripts/test.sh

all: $(O)

$(O): $(SOURCES)
	mkdir -p bin
	$(SHARDS) build $(FLAGS)

.PHONY: $(CHECK)
	$(SHARDS) check || $(SHARDS) install

.PHONY: release
release: $(CHECK)
	mkdir -p bin
	$(SHARDS) build $(RELEASE_FLAGS)

.PHONY: spec
spec:
	mkdir -p bin
	$(COMPILER) spec $(FLAGS) --order=random --error-on-warnings

.PHONY: install
install: $(O) ## Install the compiler at DESTDIR
	$(INSTALL) -d -m 0755 "$(BINDIR)/"
	$(INSTALL) -m 0755 "$(O)" "$(BINDIR)/$(NAME)"
.PHONY: uninstall
uninstall: ## Uninstall the compiler from DESTDIR
	rm -f "$(BINDIR)/$(NAME)"

.PHONY: clean
clean:
	rm -f $(O)

.PHONY: cleanall
cleanall: clean
	rm -rf ${CACHE_DIR}
