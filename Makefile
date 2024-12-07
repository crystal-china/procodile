-include Makefile.local # for optional local options

NAME = helloworld

COMPILER ?= crystal
SHARDS ?= shards

SOURCES != find src -name '*.cr'
LIB_SOURCES != find lib -name '*.cr' 2>/dev/null
SPEC_SOURCES != find spec -name '*.cr' 2>/dev/null

CRYSTAL_ENTRY != cat shard.yml |grep main: |cut -d: -f2|cut -d" " -f2
OUTPUT_FILE != basename $(CRYSTAL_ENTRY) ".cr"
CRYSTAL_ENTRY_PATH := $(shell pwd)/$(shell cat shard.yml |grep main: |cut -d: -f2|cut -d" " -f2)

CACHE_DIR != $(COMPILER) env CRYSTAL_CACHE_DIR
CACHE_DIR := $(CACHE_DIR)/$(subst /,-,${shell echo $(CRYSTAL_ENTRY_PATH) |cut -c2-})

FLAGS ?= --progress -Dstrict_multi_assign -Dno_number_autocast -Dpreview_overload_order
RELEASE_FLAGS ?= --no-debug --link-flags=-s --release --progress -Dstrict_multi_assign -Dno_number_autocast -Dpreview_overload_order

# INSTALL:
DESTDIR ?= /usr/local
BINDIR ?= $(DESTDIR)/bin
INSTALL ?= /usr/bin/install

O := bin/$(OUTPUT_FILE)

.PHONY: all
all: build ## build [default]

.PHONY: build
build: $(O) ## Build the application binary

$(O): $(SOURCES) $(LIB_SOURCES) lib bin
	$(COMPILER) build $(FLAGS) $(CRYSTAL_ENTRY) -o $(O)

# 注意, 这些不带 .PHONY 通常都是真实文件名或目录名
lib: ## Run shards install to install dependencies
	$(SHARDS) install

.PHONY: spec
spec: $(SPEC_SOURCES) $(SOURCES) $(LIB_SOURCES) lib bin ## Run spec
	$(COMPILER) spec $(FLAGS) --order=random --error-on-warnings

.PHONY: format
format: ## Apply source code formatting
	$(COMPILER) tool format src spec

.PHONY: install
install: release ## Install the compiler at DESTDIR
	$(INSTALL) -d -m 0755 "$(BINDIR)/"
	$(INSTALL) -m 0755 "$(O)" "$(BINDIR)/$(NAME)"

.PHONY: uninstall
uninstall: ## Uninstall the compiler from DESTDIR
	rm -f "$(BINDIR)/$(NAME)"

.PHONY: check
check: ## Check dependencies, run shards install if necessary
	$(SHARDS) check || $(SHARDS) install

.PHONY: clean
clean: ## Delete built binary
	rm -f $(O)

.PHONY: cleanall
cleanall: clean # Delete built binary with cache
	rm -rf ${CACHE_DIR}

.PHONY: test
test: ## Run test script
	@scripts/test.sh

.PHONY: release
release: $(SOURCES) $(LIB_SOURCES) lib bin ## Build release binary
	$(COMPILER) build $(RELEASE_FLAGS) $(CRYSTAL_ENTRY) -o $(O)

bin:
	@mkdir -p bin

.PHONY: help
help: ## Show this help
	@echo
	@printf '\033[34mtargets:\033[0m\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) |\
		sort |\
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo
	@printf '\033[34moptional variables:\033[0m\n'
	@grep -hE '^[a-zA-Z_-]+ \?=.*?## .*$$' $(MAKEFILE_LIST) |\
		sort |\
		awk 'BEGIN {FS = " \\?=.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo
	@printf '\033[34mrecipes:\033[0m\n'
	@grep -hE '^##.*$$' $(MAKEFILE_LIST) |\
		awk 'BEGIN {FS = "## "}; /^## [a-zA-Z_-]/ {printf "  \033[36m%s\033[0m\n", $$2}; /^##  / {printf "  %s\n", $$2}'
