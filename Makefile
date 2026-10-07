.PHONY: help doctor check test-app test-runtime test-device-tools test-plan500-ipad

help:
	@echo "make doctor  检查本机 iPad 开发环境"
	@echo "make check   检查脚本语法和 Git 空白错误"
	@echo "make test-app 运行正式应用的 Swift 核心行为测试"
	@echo "make test-runtime 运行镜像构建输入与磁盘保留测试"
	@echo "make test-device-tools 验证真机工具的选择、隔离与输出保护（无需设备）"
	@echo "make test-plan500-ipad 验证研究 App 输入保护和 Swift RPC 闸门（无需设备）"

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
