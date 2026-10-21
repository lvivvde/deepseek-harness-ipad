.PHONY: help doctor check test web app ipad

help:
	@echo "make doctor 检查本机 iPad 开发环境"
	@echo "make check  检查脚本语法和 Git 空白错误"
	@echo "make test   运行全部无需设备的测试（Swift、Worker 桥接、原生 Git、构建闸门、镜像构建）"
	@echo "make web    从固定官方包生成 App 网页根目录（输出在 build/candidate）"
	@echo "make app    生成独立工程并构建未签名的 macOS App（先运行 make web）"
	@echo "make ipad   构建嵌入已核验 QEMU 执行器的 iPad App（签名用私有 --signing-file）"

doctor:
	@bash scripts/doctor.sh

check:
	@bash -n scripts/doctor.sh
	@python3 -c "import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path('runtime').glob('*.py')]"
	@python3 -c "import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path('runtime/candidate').glob('*.py')]"
	@node --check runtime/candidate/candidate-bridge.js
	@node --check runtime/candidate/session-recovery.js
	@node --check runtime/candidate/connector.js
	@for f in runtime/native-git/*.js runtime/guest-agent/agent.cjs; do node --check $$f || exit 1; done
	@bash -n runtime/guest/init runtime/guest/harness-init runtime/guest/default.script runtime/guest-agent/init.sh
	@git diff --check
	@git diff --cached --check

test:
	@swift test --package-path ios/HarnessApp
	@swift build --package-path ios/HarnessApp --product home-recovery-probe
	@node --test runtime/candidate/test_recovery.mjs
	@node --test runtime/candidate/test_bridge.mjs
	@node --test runtime/candidate/test_pnpm.mjs
	@node --test runtime/native-git/test_native_git.mjs
	@python3 -m unittest discover -s runtime/candidate -p test_build.py
	@python3 -m unittest discover -s runtime/tests

web:
	@node runtime/candidate/prepare.mjs

app:
	@python3 runtime/candidate/build.py

ipad:
	@python3 runtime/candidate/build.py --sdk iphoneos
