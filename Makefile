.PHONY: build install run clean log stop

build:
	./build.sh

install:
	./build.sh install

run: install

stop:
	-pkill -f "/Applications/LocalFlow.app/Contents/MacOS/LocalFlow"

log:
	tail -f /tmp/localflow.log

clean:
	swift package clean
	rm -rf .build/LocalFlow.app
