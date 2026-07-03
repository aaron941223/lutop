.PHONY: run snapshot build bundle install uninstall clean

run:
	swift run Lutop

snapshot:
	LUTOP_SNAPSHOT=1 swift run Lutop

build:
	swift build

bundle:
	./scripts/build_app.sh

install:
	./scripts/install_app.sh

uninstall:
	./scripts/uninstall_app.sh

clean:
	rm -rf .build dist
