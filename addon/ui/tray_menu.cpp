#include "tray_menu.h"

#include "fcitx-utils/i18n.h"
#include "ui_addon.h"

#include <fcitx-utils/log.h>
#include <fcitx/addonmanager.h>
#include <fcitx/instance.h>
#include <dbus_public.h> // Arch Fcitx5ModuleDBus config 根=叶子目录

#include <algorithm>
#include <chrono>
#include <fstream>

namespace fcitx {

namespace {

constexpr char kWatcherName[] = "org.kde.StatusNotifierWatcher";
constexpr char kWatcherObj[] = "/StatusNotifierWatcher";
constexpr char kWatcherIface[] = "org.kde.StatusNotifierWatcher";
constexpr char kSniIface[] = "org.kde.StatusNotifierItem";
constexpr char kSniObj[] = "/org/fcitx/AiInput/Tray";
constexpr char kMenuIface[] = "com.canonical.dbusmenu";
constexpr char kMenuObj[] = "/org/fcitx/AiInput/MenuBar";

// 菜单项 id：1=bug 标记 2=卡切换 3=UI 切换
constexpr int32_t kItemIdBug = 1;
constexpr int32_t kItemIdCard = 2;
constexpr int32_t kItemIdUi = 3;

} // namespace

AiInputTray::AiInputTray(AiInputUi *ui) : ui_(ui) {
    const auto nowUs = [] { return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now().time_since_epoch())
            .count()); };
    try {
        auto *dbusMod = ui->instance()->addonManager().addon("dbus", true);
        if (!dbusMod) {
            FCITX_WARN() << "AiInputTray: dbus 模块缺席，托盘不可用";
            return;
        }
        auto *bus = dbusMod->call<IDBusModule::bus>();
        if (!bus) {
            return;
        }
        sni_ = std::make_unique<AiTraySNI>(ui);
        menu_ = std::make_unique<AiInputMenu>(ui);
        privateBus_ = std::make_unique<dbus::Bus>(bus->address());
        privateBus_->attachEventLoop(&ui->instance()->eventLoop());
        privateBus_->addObjectVTable(kSniObj, kSniIface, *sni_);
        privateBus_->addObjectVTable(kMenuObj, kMenuIface, *menu_);
        // watcher 服务的存在性不探活：直接注册，失败由重试定时器兜底
        // （定时器挂实例事件循环——私有 Bus 已 attach 同一循环）
        retryTimer_ = ui_->instance()->eventLoop().addTimeEvent(
            CLOCK_MONOTONIC, nowUs() + 2000000, 2000000,
            [this](EventSourceTime *, uint64_t) {
                if (!registered_) {
                    registerSNI();
                }
                return !registered_; // 注册成功后停
            });
        FCITX_INFO() << "AiInputTray: 已初始化（注册重试 2s 周期）";
    } catch (const std::exception &e) {
        FCITX_WARN() << "AiInputTray: 初始化失败 " << e.what();
    }
}

AiInputTray::~AiInputTray() = default;

void AiInputTray::registerSNI() {
    if (registered_ || !privateBus_ || !sni_ || !menu_) {
        return;
    }
    auto call = privateBus_->createMethodCall(
        kWatcherName, kWatcherObj, kWatcherIface,
        "RegisterStatusNotifierItem");
    call << privateBus_->uniqueName();
    pendingRegisterCall_ = call.callAsync(0, [this](dbus::Message &msg) {
        std::unique_ptr<dbus::Slot> call = std::move(pendingRegisterCall_);
        registered_ = !msg.isError();
        FCITX_INFO() << "AiInputTray: SNI 注册 "
                     << (registered_ ? "成功" : "失败（等待重试）");
        return true;
    });
    privateBus_->flush();
}

// —— AiInputMenu ———————————————————————————————————————————

void AiInputMenu::fillProperties(int32_t id, MenuProperties &properties) {
    if (id == 0) {
        properties.emplace_back("children-display",
                                dbus::Variant(std::string("submenu")));
        return;
    }
    properties.emplace_back("type", dbus::Variant(std::string("standard")));
    properties.emplace_back("enabled", dbus::Variant(true));
    switch (id) {
    case kItemIdBug:
        properties.emplace_back(
            "label", dbus::Variant(std::string("标记上次输入为 Bug")));
        break;
    case kItemIdCard:
        properties.emplace_back("label",
                                dbus::Variant(ui_->cardToggleLabel()));
        break;
    case kItemIdUi:
        properties.emplace_back("label",
                                dbus::Variant(ui_->uiToggleLabel()));
        break;
    default:
        break;
    }
}

dbus::Variant AiInputMenu::getProperty(int32_t id, const std::string &name) {
    MenuProperties properties;
    fillProperties(id, properties);
    for (auto &p : properties) {
        if (p.key() == name) {
            return p.value();
        }
    }
    return dbus::Variant();
}

void AiInputMenu::fillLayoutItem(
    int32_t id, int32_t depth, const std::unordered_set<std::string> &names,
    MenuLayout &layout) {
    std::get<0>(layout) = id;
    fillProperties(id, std::get<1>(layout));
    auto &sub = std::get<2>(layout);
    if (id < 0 || depth == 0) {
        return;
    }
    if (id == 0) {
        for (int32_t child : {kItemIdBug, kItemIdCard, kItemIdUi}) {
            MenuLayout subLayout;
            fillLayoutItem(child, depth - 1, names, subLayout);
            sub.emplace_back(std::move(subLayout));
        }
    }
}

std::tuple<uint32_t, MenuLayout>
AiInputMenu::getLayout(int32_t parentId, int32_t depth,
                       const std::vector<std::string> &propertyNames) {
    std::unordered_set<std::string> names(propertyNames.begin(),
                                          propertyNames.end());
    MenuLayout layout;
    fillLayoutItem(parentId, depth, names, layout);
    return {revision_, std::move(layout)};
}


void AiInputMenu::event(int32_t id, const std::string &type,
                        const dbus::Variant &, uint32_t) {
    if (type != "clicked") {
        return;
    }
    switch (id) {
    case kItemIdBug:
        ui_->markBug();
        break;
    case kItemIdCard:
        ui_->toggleCard();
        break;
    case kItemIdUi:
        ui_->toggleUi();
        break;
    default:
        break;
    }
}

// —— AiTraySNI ———————————————————————————————————————————————

void AiTraySNI::activate(int, int) {
    // 左键不做动作（对比切换在右键菜单，防误触）
}

// —— 出口（AiInputUi 侧实现，tray_menu 只管协议）——
// markBug/toggleCard/toggleUi/cardToggleLabel/uiToggleLabel 见 ui_addon.cpp

} // namespace fcitx
