.PHONY: help doctor check

help:
	@echo "make doctor  检查本机 iPad 开发环境"
	@echo "make check   检查脚本语法和 Git 空白错误"

doctor:
	@bash scripts/doctor.sh

check:
	@bash -n scripts/doctor.sh
	@git diff --check
	@git diff --cached --check
