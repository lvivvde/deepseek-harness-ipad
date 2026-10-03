.PHONY: help doctor check test-app

help:
	@echo "make doctor  检查本机 iPad 开发环境"
	@echo "make check   检查脚本语法和 Git 空白错误"
	@echo "make test-app 运行正式应用的 Swift 核心行为测试"

doctor:
	@bash scripts/doctor.sh

check:
	@bash -n scripts/doctor.sh
	@bash -n ios/HarnessApp/scripts/embed-runtime.sh
	@python3 -c "import ast; from pathlib import Path; ast.parse(Path('ios/HarnessApp/scripts/validate-runtime.py').read_text())"
	@git diff --check
	@git diff --cached --check

test-app:
	@swift test --package-path ios/HarnessApp
