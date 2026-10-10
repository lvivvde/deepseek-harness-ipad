.PHONY: help doctor check test-app test-runtime test-device-tools test-plan500-ipad test-candidate candidate-web candidate-app candidate-ipad

help:
	@echo "make doctor  检查本机 iPad 开发环境"
	@echo "make check   检查脚本语法和 Git 空白错误"
	@echo "make test-app 运行正式应用的 Swift 核心行为测试"
	@echo "make test-runtime 运行镜像构建输入与磁盘保留测试"
	@echo "make test-device-tools 验证真机工具的选择、隔离与输出保护（无需设备）"
	@echo "make test-plan500-ipad 验证研究 App 输入保护和 Swift RPC 闸门（无需设备）"
	@echo "make test-candidate 验证候选 App 的 Worker 桥接、官方锚点与构建闸门（无需设备）"
	@echo "make candidate-web 从固定官方包生成候选 App 网页根目录（输出在 build/candidate）"
	@echo "make candidate-app 生成独立工程并构建未签名的 macOS 候选 App（先运行 candidate-web）"
	@echo "make candidate-ipad 构建嵌入已核验 QEMU 执行器的未签名 iPad 候选 App（签名用私有 --signing-file）"

doctor:
	@bash scripts/doctor.sh

check:
	@bash -n scripts/doctor.sh
	@bash -n ios/HarnessApp/scripts/embed-runtime.sh
	@bash -n runtime/prototypes/plan500-ipad/embed.sh
	@python3 -c "import ast; from pathlib import Path; ast.parse(Path('ios/HarnessApp/scripts/validate-runtime.py').read_text())"
	@python3 -c "import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path('ios/HarnessApp/scripts').rglob('*.py')]"
	@python3 -c "import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path('runtime').glob('*.py')]"
	@python3 -c "import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path('runtime/prototypes/plan500-ipad').glob('*.py')]"
	@python3 -c "import ast; from pathlib import Path; [ast.parse(p.read_text()) for p in Path('runtime/candidate').glob('*.py')]"
	@node --check runtime/candidate/candidate-bridge.js
	@node --check runtime/candidate/connector.js
	@bash -n runtime/guest/init runtime/guest/harness-init runtime/guest/default.script
	@git diff --check
	@git diff --cached --check

test-app:
	@swift test --package-path ios/HarnessApp

test-runtime:
	@python3 -m unittest discover -s runtime/tests

test-device-tools:
	@python3 -m unittest discover -s ios/HarnessApp/scripts/tests

test-plan500-ipad:
	@python3 -m unittest discover -s runtime/prototypes/plan500-ipad -p test_build.py
	@node --test runtime/prototypes/plan500-ipad/test_model.mjs
	@node --test runtime/prototypes/plan500-ipad/test_native_git.mjs
	@swift test --package-path runtime/prototypes/plan500-darwin/gateway

test-candidate:
	@node --test runtime/candidate/test_bridge.mjs
	@python3 -m unittest discover -s runtime/candidate -p test_build.py

candidate-web:
	@node runtime/candidate/prepare.mjs

candidate-app:
	@python3 runtime/candidate/build.py

candidate-ipad:
	@python3 runtime/candidate/build.py --sdk iphoneos
