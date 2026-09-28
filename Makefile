.PHONY: build test app run install zip clean

build:
	swift build

test:
	swift test

# 生成 dist/Stox.app
app:
	./scripts/build-app.sh

run: app
	-pkill -x Stox
	open dist/Stox.app

# 安装到“应用程序”文件夹并启动
install: app
	-pkill -x Stox
	rm -rf /Applications/Stox.app
	cp -R dist/Stox.app /Applications/
	open /Applications/Stox.app

zip: app
	cd dist && rm -f Stox.zip && ditto -c -k --keepParent Stox.app Stox.zip

clean:
	rm -rf .build dist
