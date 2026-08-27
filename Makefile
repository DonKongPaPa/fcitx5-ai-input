# fcitx5-ai-input 构建测试管线
# 用法示例：
#   make images            # 构建全部镜像
#   make build             # 编译 addon/flutter/testapp → artifacts/dist/
#   make test ENV=niri     # 单环境测试（kde/gnome 同理）
#   make test-all          # 依次运行三个独立容器
#   make shell ENV=niri    # 交互式进入环境容器调试
#   make baseline ENV=niri # 将通过用例录屏存为本地基准
#   make compare           # 汇总历史报告生成方案对比页

ENV ?= niri
RUN_ID ?=

.PHONY: images image-base image-build image-niri image-kde image-gnome image-funasr \
        build test test-all shell envcheck baseline report compare \
        ui-test proto-test addon-test surface-test gate-merge gate-release

images:
	./scripts/build-images.sh all

image-base:
	./scripts/build-images.sh base
image-build:
	./scripts/build-images.sh build
image-niri:
	./scripts/build-images.sh niri
image-kde:
	./scripts/build-images.sh kde
image-gnome:
	./scripts/build-images.sh gnome
image-funasr:
	./scripts/build-images.sh funasr

build:
	./scripts/build.sh

# M2：单环境无头/录屏验证（不出正式报告）
envcheck:
	./scripts/run-env.sh $(ENV)

# M4+：正式测试管线
test:
	./scripts/run-test.sh $(ENV)

test-all:
	./scripts/run-test.sh niri
	./scripts/run-test.sh kde
	./scripts/run-test.sh gnome

shell:
	MODE=shell DURATION=0 ./scripts/run-env.sh $(ENV)

baseline:
	./scripts/baseline.sh $(ENV)

report:
	@latest=$$(ls -1 artifacts/reports 2>/dev/null | sort | tail -1); \
	echo "最新报告: artifacts/reports/$$latest/report.html"

compare:
	python3 scripts/compare.py

ui-test:            ## 快档：UI 层 flutter test+golden+回放（aiinput-build 容器）
	./scripts/run-ui-test.sh

proto-test:         ## 快档：协议 v1 对拍（schema+跨通道不变量，aiinput-base 容器）
	./scripts/run-proto-test.sh

addon-test:         ## 快档：无显示状态机（ic-sim 纯 D-Bus 造 IC，aiinput-base 容器）
	./scripts/run-addon-test.sh

surface-test:       ## 快档·根因分析：单场景定位测量（SC=S1..S6，差分 bbox+并排报告）
	./scripts/run-surface-test.sh ${SC}

gate-merge:         ## 广档·合并前门禁：niri 全套件双 scale（20×2）
	./scripts/run-test.sh niri

gate-release:       ## 广档·发版前门禁：三环境全套件（niri+kde+gnome）
	./scripts/run-test.sh niri
	./scripts/run-test.sh kde
	./scripts/run-test.sh gnome
