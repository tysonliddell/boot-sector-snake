SOURCEDIR := ./src
BUILDDIR := ./build
SOURCES := $(wildcard $(SOURCEDIR)/*.asm)
TARGETS := $(patsubst $(SOURCEDIR)/%.asm,$(BUILDDIR)/%.img,$(SOURCES))
VPATH := "./src"

.PHONY: all
all: $(TARGETS)

$(BUILDDIR)/%.img: $(SOURCEDIR)/%.asm | $(BUILDDIR)
	nasm -f bin $< -o $@
	truncate -s 160K $@
	sync

$(BUILDDIR):
	-mkdir $(BUILDDIR)

.PHONY: clean
clean:
	rm -r $(BUILDDIR)
