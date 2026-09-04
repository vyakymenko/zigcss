ZIGCSS ?= zigcss

INPUT := styles.scss
OUTPUT := styles.css
DEPFILE := $(OUTPUT).d

$(OUTPUT): $(INPUT)
	"$(ZIGCSS)" "$<" --syntax scss --minify -o "$@" --depfile "$(DEPFILE)"

-include $(DEPFILE)
